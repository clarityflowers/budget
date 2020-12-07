const std = @import("std");
const ncurses = @import("ncurses.zig");
const attr = @import("attributes.zig").attr;

str: std.ArrayList(u8),

pub fn init(allocator: *std.mem.Allocator) @This() {
    return .{
        .str = std.ArrayList(u8).init(allocator),
    };
}

pub fn deinit(self: *@This()) void {
    self.str.deinit();
}

pub fn set(self: *@This(), comptime fmt: []const u8, args: anytype) !void {
    self.reset();
    try self.str.writer().print(fmt, args);
}

pub fn active(self: @This()) bool {
    return self.str.items.len > 0;
}

pub fn render(self: *@This(), window: *ncurses.Box, input: ?ncurses.Key) !bool {
    if (input == null) {
        window.move(.{});
        window.setCursor(.invisible);
        window.attrSet(attr(.err)) catch {};
        try window.writer().writeAll(self.str.items);
        return false;
    } else {
        self.reset();
        return false;
    }
}

pub fn reset(self: *@This()) void {
    self.str.shrinkRetainingCapacity(0);
}
