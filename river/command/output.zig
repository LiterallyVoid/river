// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2021 The River Developers
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 3.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;

const wlr = @import("wlroots");

const server = &@import("../main.zig").server;
const util = @import("../util.zig");

const Direction = @import("../command.zig").Direction;
const PhysicalDirectionDirection = @import("../command.zig").PhysicalDirection;
const Error = @import("../command.zig").Error;
const Output = @import("../Output.zig");
const Seat = @import("../Seat.zig");

pub fn focusOutput(
    seat: *Seat,
    args: []const [:0]const u8,
    _: *?[]const u8,
) Error!void {
    if (args.len < 2) return Error.NotEnoughArguments;
    if (args.len > 2) return Error.TooManyArguments;

    // If the noop output is focused, there are no other outputs to switch to
    if (seat.focused_output == &server.root.noop_output) {
        assert(server.root.outputs.len == 0);
        return;
    }

    seat.focusOutput((try getOutput(seat, args[1])) orelse return);
    seat.focus(null);
    server.root.startTransaction();
}

pub fn sendToOutput(
    seat: *Seat,
    args: []const [:0]const u8,
    _: *?[]const u8,
) Error!void {
    if (args.len < 2) return Error.NotEnoughArguments;
    if (args.len > 2) return Error.TooManyArguments;

    // If the noop output is focused, there is nowhere to send the view
    if (seat.focused_output == &server.root.noop_output) {
        assert(server.root.outputs.len == 0);
        return;
    }

    if (seat.focused == .view) {
        const destination_output = (try getOutput(seat, args[1])) orelse return;
        // If the view is already on destination_output, do nothing
        if (seat.focused.view.output == destination_output) return;
        seat.focused.view.sendToOutput(destination_output);

        // Handle the change and focus whatever's next in the focus stack
        seat.focus(null);
        seat.focused_output.arrangeViews();
        destination_output.arrangeViews();
        server.root.startTransaction();
    }
}

/// Find an output adjacent to the currently focused based on either logical or
/// spacial direction
fn getOutput(seat: *Seat, str: []const u8) !?*Output {
    if (std.meta.stringToEnum(Direction, str)) |direction| { // Logical direction
        // Return the next/prev output in the list if there is one, else wrap
        const focused_node = @fieldParentPtr(std.TailQueue(Output).Node, "data", seat.focused_output);
        return switch (direction) {
            .next => if (focused_node.next) |node| &node.data else &server.root.outputs.first.?.data,
            .previous => if (focused_node.prev) |node| &node.data else &server.root.outputs.last.?.data,
        };
    } else if (std.meta.stringToEnum(wlr.OutputLayout.Direction, str)) |direction| { // Spacial direction
        var focus_box: wlr.Box = undefined;
        server.root.output_layout.getBox(seat.focused_output.wlr_output, &focus_box);
        if (focus_box.empty()) return null;

        const wlr_output = server.root.output_layout.adjacentOutput(
            direction,
            seat.focused_output.wlr_output,
            @intToFloat(f64, focus_box.x + @divTrunc(focus_box.width, 2)),
            @intToFloat(f64, focus_box.y + @divTrunc(focus_box.height, 2)),
        ) orelse return null;
        return @intToPtr(*Output, wlr_output.data);
    } else {
        // Check if an output matches by name
        var it = server.root.outputs.first;
        while (it) |node| : (it = node.next) {
            if (mem.eql(u8, mem.span(node.data.wlr_output.name), str)) {
                return &node.data;
            }
        }
        return Error.InvalidOutputIndicator;
    }
}

pub fn listModes(
    seat: *Seat,
    _: []const [:0]const u8,
    out: *?[]const u8,
) Error!void {
    var mode_list = std.ArrayList(u8).init(util.gpa);
    errdefer mode_list.deinit();

    var it = seat.focused_output.wlr_output.modes.iterator(.forward);

    var i: i32 = 0;

    while (it.next()) |mode| {
        try mode_list.writer().print("\tmode {}: {}x{} @ {}hz{s}{s}\n", .{ i, mode.width, mode.height, mode.refresh, if (mode == seat.focused_output.wlr_output.current_mode) " (current)" else "", if (mode.preferred) " (*)" else "" });

        i += 1;
    }

    out.* = mode_list.toOwnedSlice();
}

pub fn setMode(
    seat: *Seat,
    args: []const [:0]const u8,
    _: *?[]const u8,
) Error!void {
    if (args.len < 2) return Error.NotEnoughArguments;
    if (args.len > 2) return Error.TooManyArguments;

    var sel = try std.fmt.parseInt(i32, args[1], 10);

    var it = seat.focused_output.wlr_output.modes.iterator(.forward);

    var i: i32 = 0;

    while (it.next()) |mode| {
        if (i == sel) {
            const old_mode = (seat.focused_output.wlr_output.current_mode orelse return Error.InvalidValue);

            seat.focused_output.wlr_output.setMode(mode);
            seat.focused_output.wlr_output.commit() catch {
                seat.focused_output.wlr_output.setMode(old_mode);
                seat.focused_output.wlr_output.commit() catch unreachable;
            };
        }

        i += 1;
    }
}

pub fn setModeCustom(
    seat: *Seat,
    args: []const [:0]const u8,
    _: *?[]const u8,
) Error!void {
    if (args.len < 4) return Error.NotEnoughArguments;
    if (args.len > 4) return Error.TooManyArguments;

    var w = try std.fmt.parseInt(i32, args[1], 10);
    var h = try std.fmt.parseInt(i32, args[2], 10);
    var r = try std.fmt.parseInt(i32, args[3], 10);

    const old_mode = (seat.focused_output.wlr_output.current_mode orelse return Error.InvalidValue);

    seat.focused_output.wlr_output.setCustomMode(w, h, r);
    seat.focused_output.wlr_output.commit() catch {
        seat.focused_output.wlr_output.setMode(old_mode);
        seat.focused_output.wlr_output.commit() catch unreachable;
    };
}
