const Cursor = @import("Cursor.zig");
const ncurses = @import("ncurses.zig");
const Database = @import("import_Database.zig");
const attr = @import("curse.zig").attr;

pattern: Pattern,
str: []const u8,

pub const Pattern = union(enum) {
    prefix: Cursor, suffix: Cursor
};

pub fn init(comptime pattern: @TagType(Pattern), str: []const u8) @This() {
    return .{
        .pattern = @unionInit(Pattern, @tagName(pattern), .{}),
        .str = str,
    };
}

/// Returns true if the input was consumed and should not be bubbled up
pub fn render(self: *@This(), box: *ncurses.Box, input: ?ncurses.Key) !bool {
    var consumed = false;
    const writer = box.writer();
    switch (self.pattern) {
        .suffix => |*cursor| {
            if (input) |in| {
                if (cursor.getResultOfInput(
                    in,
                    self.str[0 .. self.str.len - 1],
                )) |new_cursor| {
                    cursor.* = new_cursor;
                    consumed = true;
                }
            }
            box.setCursor(.normal);
            writer.writeAll(self.str[0..cursor.start]) catch {};
            box.attrSet(attr(.highlight)) catch {};
            writer.writeAll(self.str[cursor.start..]) catch {};
            box.attrSet(0) catch {};
            box.move(.{
                .column = cursor.start,
            });
        },
        .prefix => |*cursor| {
            if (input) |in| {
                if (cursor.getResultOfInput(in, self.str[1..])) |new_cursor| {
                    cursor.* = new_cursor;
                    consumed = true;
                }
            }
            box.setCursor(.normal);
            box.attrSet(attr(.highlight)) catch {};
            writer.writeAll(self.str[0 .. cursor.start + 1]) catch {};
            box.attrSet(0) catch {};
            writer.writeAll(self.str[cursor.start + 1 ..]) catch {};
            box.move(.{
                .column = cursor.start,
            });
        },
    }
    return consumed;
}

pub fn getValue(self: @This()) []const u8 {
    return switch (self.pattern) {
        .prefix => |cursor| self.str[0 .. cursor.start + 1],
        .suffix => |cursor| self.str[cursor.start..],
    };
}

pub fn getMatch(self: @This()) Database.Match {
    return switch (self.pattern) {
        .prefix => .prefix,
        .suffix => .suffix,
    };
}
