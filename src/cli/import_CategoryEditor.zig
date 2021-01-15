const std = @import("std");
const ncurses = @import("ncurses.zig");
const Database = @import("import_Database.zig");
const import = @import("../import.zig");
const TextField = @import("TextField.zig");
const attr = @import("attributes.zig").attr;
const PatternEditor = @import("import_PatternEditor.zig");

allocator: *std.mem.Allocator,
db: *const Database,
arena: std.heap.ArenaAllocator,
category: *const ?import.Category,
existing_match_id: ?i64,

text: TextField,
strings: std.ArrayList(u8),

selection: ?Selection = null,

pub fn init(
    allocator: *std.mem.Allocator,
    db: *const Database,
    category: *const ?import.Category,
    existing_match_id: ?i64,
) @This() {
    return .{
        .allocator = allocator,
        .arena = std.heap.ArenaAllocator.init(allocator),
        .db = db,
        .category = category,
        .existing_match_id = existing_match_id,
        .text = TextField.init(allocator),
        .strings = std.ArrayList(u8).init(allocator),
    };
}

pub fn deinit(self: *@This()) void {
    self.arena.deinit();
    self.strings.deinit();
    self.text.deinit();
}

pub const Submission = struct {
    selection: Selection,
    pattern: bool = false,
};
pub const Result = union(enum) {
    submit: Submission,
    cancel,
};

/// If the result contains a submission, the selection field contains memory owned by the caller
pub fn render(self: *@This(), box: *ncurses.Box, input: ?ncurses.Key) !?Result {
    box.move(.{});
    if (self.selection == null) {
        var input_mut = input;
        const writer = box.writer();

        const maybe_match = self.getMatch() catch null;

        const value = self.text.value();

        const group_separator = &[_]u21{ ':', ' ' };
        const maybe_selection = if (maybe_match) |match| switch (match.id) {
            .perfect => |id| Selection{ .existing = id },
            .category_perfect => |id| Selection{ .existing = .{ .budget = id } },
            .group_perfect_category_partial, .group_perfect => |id| blk: {
                if (std.mem.indexOf(u21, value, group_separator)) |index| {
                    if (index < self.text.value().len - 2 and std.mem.indexOf(u21, value[index + 2 ..], group_separator) == null)
                        break :blk Selection{ .new = .{ .group = .{ .existing = id }, .name = value[index + 2 ..] } };
                }
                break :blk null;
            },
            else => null,
        } else blk: {
            if (std.mem.indexOf(u21, value, group_separator)) |index| {
                if (index > 0 and index < value.len - 2 and std.mem.indexOf(u21, value[index + 2 ..], group_separator) == null) {
                    break :blk Selection{
                        .new = .{
                            .group = .{ .new = value[0..index] },
                            .name = value[index + 2 ..],
                        },
                    };
                }
            }
            break :blk null;
        };

        if (input) |key| switch (key) {
            .char => |char| switch (char) {
                0x03 => return Result.cancel,
                0x06 => {
                    input_mut = null;
                    if (maybe_match) |match| {
                        try self.text.set(match.completion);
                        self.text.cursor.start = self.text.value().len;
                    }
                },
                '\r' => {
                    if (maybe_selection) |selection| {
                        self.selection = selection;
                        return null;
                    }
                    return null;
                },
                else => {},
            },
            else => {},
        };
        if (maybe_match) |match| {
            // Draw completion
            box.attrSet(attr(.dim)) catch {};
            try writer.writeAll(match.completion);
            // Set text color
            box.attrSet(switch (match.id) {
                .perfect, .category_perfect => attr(.attention),
                else => 0,
            }) catch {};
            // Set text position
            box.move(.{
                .column = switch (match.id) {
                    .category_partial, .category_perfect => match.match.len,
                    else => 0,
                },
            });
            _ = try self.text.render(input_mut, box, "Enter a category");
            // Write-over
            switch (match.id) {
                .group_perfect_category_partial, .group_perfect => {
                    const position = box.getPosition();
                    box.move(.{});
                    box.attrSet(attr(.attention)) catch {};
                    try writer.writeAll(match.match);
                    if (position) |pos| box.move(pos) else box.out_of_bounds = true;
                },
                else => {},
            }
        } else {
            box.attrSet(0) catch {};
            box.move(.{});
            _ = try self.text.render(input_mut, box, "Group: Category");
        }
        if (maybe_selection) |selection| {
            const position = box.getPosition();
            box.attrSet(attr(.attention)) catch {};
            box.move(.{ .line = 1 });
            if (selection == .new) switch (selection.new.group) {
                .new => try writer.writeAll("(create new category)"),
                .existing => try writer.writeAll("(create new category and group)"),
            };
            if (position) |pos| box.move(pos) else box.out_of_bounds = true;
        }
        return null;
    } else {
        const selection = self.selection.?;

        if (input != null and input.? == .char) switch (input.?.char) {
            0x03 => {
                self.selection = null;
                return null;
            },
            '\r', 'p' => return Result{
                .submit = .{
                    .selection = selection,
                    .pattern = input.?.char == 'p',
                },
            },
            else => {},
        };
        if (self.existing_match_id) |id| {
            try box.writer().writeAll("(⏎)complete, or update existing (p)attern.");
        } else {
            try box.writer().writeAll("(⏎)complete, or create new (p)attern.");
        }

        return null;
    }
}

const Selection = union(enum) {
    new: struct {
        group: union(enum) {
            new: []const u21,
            existing: i64,
        },
        name: []const u21,
    },
    existing: Database.CategoryId,
};

pub fn inputIsChar(input: ?ncurses.Key, char: u21) bool {
    return input != null and input.? == char and input.?.char == char;
}

pub fn getMatch(
    self: *@This(),
) !?Database.CategoryMatch {
    if (self.text.value().len == 0) return null;
    const text = try self.text.copyValue();
    defer self.allocator.free(text);
    var iterator = try self.db.iterateCategoryMatches(text);
    self.strings.shrinkRetainingCapacity(0);
    var count: usize = 0;
    while (try iterator.next()) |match| {
        var result = match;
        var index = self.strings.items.len;
        try self.strings.appendSlice(match.completion);
        result.completion = self.strings.items[index..];

        index = self.strings.items.len;
        try self.strings.appendSlice(match.match);
        result.match = self.strings.items[index..];

        return result;
    }
    return null;
}
