const std = @import("std");

pub fn encodeUtf8Alloc(str: []const u21, allocator: *std.mem.Allocator) ![]u8 {
    var result = std.ArrayList(u8).init(allocator);
    for (str) |codepoint| {
        var buffer: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(codepoint, &buffer) catch return error.InvalidUtf8;
        try result.appendSlice(buffer[0..len]);
    }
    return result.toOwnedSlice();
}
