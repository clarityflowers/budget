const std = @import("std");
const TextField = @import("TextField.zig");
const ncurses = @import("ncurses.zig");

text: TextField,

pub fn init(allocator: *std.mem.Allocator, value: []const u8) !@This() {
    var text = TextField.init(allocator);
    try text.set(value);
    text.cursor.start = text.value().len;
    return @This(){
        .text = text,
    };
}

pub fn deinit(self: *@This()) void {
    self.text.deinit();
}

pub const Result = union(enum) {
    cancel,
    submit: []const u8,
};

/// Submission returned is owned by caller
pub fn render(self: *@This(), box: *ncurses.Box, input: ?ncurses.Key) !?Result {
    box.move(.{});
    const writer = box.writer();
    if (input) |key| switch (key) {
        .char => |char| switch (char) {
            0x03 => {
                return Result.cancel;
            },
            '\r' => {
                return Result{
                    .submit = try self.text.copyValue(),
                };
            },
            else => {},
        },
        else => {},
    };
    _ = try self.text.render(input, box, "(Enter a memo)");
    return null;
}
