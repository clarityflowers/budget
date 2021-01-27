const std = @import("std");
const TextField = @import("TextField.zig");
const Date = @import("../zig-date/src/date.zig").Date;
const ncurses = @import("ncurses.zig");
const attr = @import("curse.zig").attr;

date: Date,

pub fn init(date: Date) @This() {
    return .{
        .date = date,
    };
}

pub fn deinit(self: *@This()) void {}

pub const Result = union(enum) {
    submit: Date,
    cancel,
};

pub fn render(self: *@This(), box: *ncurses.Box, input: ?ncurses.Key) !?Result {
    if (input) |key| switch (key) {
        .control => |control| switch (control) {
            ncurses.key.left => {
                self.date = self.date.minusDays(1);
            },
            ncurses.key.right => {
                self.date = self.date.plusDays(1);
            },
            ncurses.key.up => {
                self.date = self.date.minusDays(7);
            },
            ncurses.key.down => {
                self.date = self.date.plusDays(7);
            },
            else => {},
        },
        .char => |char| switch (char) {
            0x03 => {
                return Result.cancel;
            },
            '\r' => {
                return Result{ .submit = self.date };
            },
            else => {},
        },
        else => {},
    };
    const writer = box.writer();
    try writer.print("{Day, Mon DD, YYYY}", .{self.date});
    box.attrSet(attr(.dim)) catch {};
    box.move(.{ .line = 1 });
    try writer.writeAll("(← select day →) (↑ select week ↓)");
    return null;
}
