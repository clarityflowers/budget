const std = @import("std");
const ncurses = @import("ncurses.zig");
const log = @import("../log.zig");
const Err = @import("Err.zig");
const CurrencyField = @import("CurrencyField.zig");
const Self = @This();

allocator: *std.mem.Allocator,
err: Err,
action: enum {
    attempting_interrupt,
    none,
} = .none,
current: usize = 0,
editor: CurrencyField = .{},

pub fn init(allocator: *std.mem.Allocator) Self {
    return Self{
        .allocator = allocator,
        .err = Err.init(allocator),
    };
}

pub fn deinit(self: *@This()) void {
    self.err.deinit();
}

/// Returns true when done
pub fn render(self: *@This(), box: *ncurses.Box, input: ?ncurses.Key) !bool {
    return self.renderInternal(box, input) catch |err| {
        switch (err) {
            error.NCursesWriteFailed,
            error.InvalidUtf8,
            => self.err.set("{}", .{@errorName(err)}) catch {},
        }
        if (std.builtin.mode == .Debug) {
            log.alert("{}: {}", .{ @errorName(err), @errorReturnTrace() });
        }
        return false;
    };
}

fn renderInternal(self: *@This(), box: *ncurses.Box, input: ?ncurses.Key) !bool {
    box.move(.{});
    try box.writer().writeAll("Hello world!");
    const divider_line = box.bounds.height - 3;

    var divider_box = box.box(.{ .line = divider_line, .height = 1 });
    divider_box.move(.{});
    try divider_box.fillLine('═');
    var command_box = box.box(.{ .line = divider_line + 1, .height = 3 });
    const command_writer = command_box.writer();
    command_box.move(.{});

    if (self.err.active()) {
        _ = try self.err.render(&command_box, input);
        return false;
    }

    switch (self.action) {
        .attempting_interrupt => {
            try command_writer.writeAll("Press ^C again to quit (your work has been saved).");
            if (input != null and input.? == .char and input.?.char == 0x03) return true;
            return false;
        },
        .none => {},
    }

    if (input) |key| switch (key) {
        .char => |char| switch (char) {
            0x03 => {
                self.action = .attempting_interrupt;
                return false;
            },
            else => {},
        },
        else => {},
    };
    return false;
}
