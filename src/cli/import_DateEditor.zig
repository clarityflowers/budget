const std = @import("std");
const TextField = @import("TextField.zig");

text: ?TextField,
allocator: *std.mem.Allocator,

pub fn init(allocator: *std.mem.Allocator) @This() {
    return .{
        .allocator = allocator,
    };
}

pub fn deinit(self: *@This()) void {
    if (self.text) |*text| {
        text.deinit();
    }
}
