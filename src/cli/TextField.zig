const std = @import("std");
const ncurses = @import("ncurses.zig");
const attr = @import("attributes.zig").attr;
const Cursor = @import("Cursor.zig");

str: std.ArrayList(u21),
err: std.ArrayList(u8),
cursor: Cursor = .{},

pub fn init(allocator: *std.mem.Allocator) @This() {
    return @This(){
        .str = std.ArrayList(u21).init(allocator),
        .err = std.ArrayList(u8).init(allocator),
    };
}

pub fn reset(self: *@This()) void {
    self.str.shrinkRetainingCapacity(0);
}

pub fn deinit(self: *@This()) void {
    defer self.str.deinit();
    defer self.err.deinit();
}

pub fn value(self: @This()) []const u21 {
    return self.str.items;
}

/// Caller owns the allocator slice
pub fn copyValue(self: @This()) ![]const u8 {
    var list = std.ArrayList(u8).init(self.str.allocator);
    try self.printValue(list.writer());
    return list.toOwnedSlice();
}

pub fn printValue(self: @This(), writer: anytype) !void {
    var buffer: [4]u8 = undefined;
    for (self.str.items) |codepoint| {
        const len = std.unicode.utf8Encode(codepoint, buffer[0..]) catch return error.InvalidUtf8;
        try writer.writeAll(buffer[0..len]);
    }
}

pub fn set(self: *@This(), new_str: []const u8) !void {
    var utf8 = (try std.unicode.Utf8View.init(new_str)).iterator();
    self.str.shrinkRetainingCapacity(0);
    while (utf8.nextCodepoint()) |codepoint| {
        try self.str.append(codepoint);
    }
}

pub const Error = std.mem.Allocator.Error;

/// Returns true if the input was consumed and should not be bubbled up
pub fn render(
    self: *@This(),
    input_key: ?ncurses.Key,
    window: *ncurses.Box,
    placeholder: []const u8,
) Error!bool {
    const x = window.getx() orelse return false;
    var input = input_key;
    const writer = window.writer();
    if (self.err.items.len > 0 and input != null) {
        self.err.shrinkRetainingCapacity(0);
        input = null;
    }
    if (input) |in| {
        if (self.cursor.getResultOfInput(in, self.str.items)) |new_cursor| {
            input = null;
            self.cursor = new_cursor;
        }
    }

    window.move(.{
        .column = x,
    });
    window.setCursor(.normal);
    if (self.str.items.len == 0) {
        window.attrSet(attr(.dim)) catch {};
        writer.writeAll(placeholder) catch {};
        window.attrSet(0) catch {};
        self.cursor.start = 0;
        window.move(.{
            .column = x,
        });
    }

    if (self.cursor.start > self.str.items.len) {
        self.cursor.start = self.str.items.len;
    }
    if (input) |in| switch (in) {
        .control => |control| switch (control) {
            ncurses.key.dc => {
                if (self.cursor.start < self.str.items.len) {
                    _ = self.str.orderedRemove(self.cursor.start);
                }
            },
            else => {
                inline for (@typeInfo(ncurses.key).Struct.decls) |decl| {
                    if (@field(ncurses.key, decl.name) == control) {
                        self.err.writer().print("Ctrl character '{}' has no effect here", .{decl.name}) catch {};
                        break;
                    }
                } else {
                    self.err.writer().print("Unknown ctrl code {d}", .{control}) catch {};
                }
            },
        },
        .escape => |escape| switch (escape) {
            'd' => {
                var start = self.cursor.start;
                const str = &self.str;
                var found_space = false;
                while (str.items.len > 0 and start < str.items.len) {
                    if (start == str.items.len - 1) {
                        _ = str.orderedRemove(start);
                    } else {
                        if (str.items[start + 1] != ' ' and found_space) break;
                        const c = str.orderedRemove(start);
                        if (c == ' ') found_space = true;
                    }
                }
                self.cursor.start = start;
            },
            else => {
                if (escape < 256) {
                    self.err.writer().print("Unknown escape '{c}'", .{@truncate(u8, escape)}) catch {};
                } else {
                    self.err.writer().print("Unknown escape {x}", .{escape}) catch {};
                }
            },
        },
        .char => |char| switch (char) {
            0x08, 0x7F => {
                if (self.cursor.start > 0) {
                    _ = self.str.orderedRemove(self.cursor.start - 1);
                    self.cursor.start -= 1;
                }
            },
            0x15 => { //^U
                while (self.cursor.start > 0) {
                    _ = self.str.orderedRemove(self.cursor.start - 1);
                    self.cursor.start -= 1;
                }
            },
            0x17 => { //^W
                var start = self.cursor.start;
                const str = &self.str;
                var found_space = false;
                while (str.items.len > 0 and start > 0) : (start -= 1) {
                    if (str.items[start - 1] != ' ' and found_space) break;
                    const c = str.orderedRemove(start - 1);
                    if (c == ' ') found_space = true;
                }
                self.cursor.start = start;
            },
            else => {
                if (char >= ' ') {
                    try (self.str.insert(self.cursor.start, @intCast(u21, char)));
                    self.cursor.start += 1;
                } else {
                    self.err.writer().print("Unknown char '{c}'", .{@truncate(u8, char)}) catch {};
                }
            },
        },
    };

    if (self.err.items.len > 0) {
        window.move(.{
            .column = x,
        });
        window.attrSet(attr(.err)) catch {};
        writer.writeAll(self.err.items) catch {};
        window.move(.{
            .column = x,
        });
    } else if (self.str.items.len > 0) {
        window.move(.{
            .column = x,
        });
        window.writeCodepoints(self.str.items) catch {};
        window.move(.{
            .column = x + self.cursor.start,
        });
    }
    return true;
}
