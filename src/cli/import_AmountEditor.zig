const std = @import("std");
const ncurses = @import("ncurses.zig");
const Currency = @import("../Currency.zig");
const Cursor = @import("Cursor.zig");

value: u32,
negative: bool,

const Result = union(enum) {
    submit: i32,
    cancel,
};

pub fn init(value: i32) @This() {
    return @This(){
        .value = std.math.absCast(value),
        .negative = value < 0,
    };
}

pub fn deinit(self: *@This()) void {}

pub fn render(self: *@This(), box: *ncurses.Box, input: ?ncurses.Key) !?Result {
    const amount = @intCast(i32, self.value) * if (self.negative) @as(i32, -1) else 1;
    if (input) |key| switch (key) {
        .char => |char| switch (char) {
            0x03 => {
                return Result.cancel;
            },
            '\r' => {
                return Result{
                    .submit = amount,
                };
            },
            0x08, 0x7F => {
                if (self.value > 0) {
                    self.value = @divTrunc(self.value, 10);
                }
            },
            0x15 => {
                self.value = 0;
            },
            '-' => {
                self.negative = !self.negative;
            },
            '0', '1', '2', '3', '4', '5', '6', '7', '8', '9' => {
                self.value = (self.value * 10) + char - '0';
            },
            else => {},
        },
        else => {},
    };
    const currency = Currency{
        .amount = amount,
        .negative_zero = self.negative,
    };

    try box.writer().print("{: >11}", .{currency});
    box.setCursor(.normal);
    return null;
}
