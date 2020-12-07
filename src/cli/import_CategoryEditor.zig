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
state: State,
category: *const ?import.Category,
note: []const u8,
existing_match_id: ?i64,

const State = union(enum) {
    select: Select,
    ask_pattern: Selection,
    pattern: Pattern,
};

pub fn init(
    allocator: *std.mem.Allocator,
    db: *const Database,
    category: *const ?import.Category,
    note: []const u8,
    existing_match_id: ?i64,
) @This() {
    return .{
        .allocator = allocator,
        .arena = std.heap.ArenaAllocator.init(allocator),
        .db = db,
        .category = category,
        .note = note,
        .state = .{ .select = Select.init(allocator, db) },
        .existing_match_id = existing_match_id,
    };
}

pub fn deinit(self: *@This()) void {
    self.arena.deinit();
    switch (self.state) {
        .select => |*select| select.deinit(),
        .ask_pattern => |*selection| selection.deinit(self.allocator),
        .pattern => |*pattern| pattern.deinit(),
    }
}

pub const Submission = struct {
    selection: Selection,
    pattern: ?union(enum) {
        new: NewPattern, update: i64
    } = null,
};
pub const Result = union(enum) {
    submit: Submission,
    cancel,
};
pub const Error = Select.SelectError;

/// If the result contains a submission, the selection field contains memory owned by the caller
pub fn render(self: *@This(), box: *ncurses.Box, input: ?ncurses.Key) !?Result {
    box.move(.{});
    switch (self.state) {
        .select => |*select| {
            if (try select.render(box, input)) |result| switch (result) {
                .cancel => {
                    return Result.cancel;
                },
                .submit => |submission| {
                    self.state = .{
                        .ask_pattern = submission,
                    };
                    return null;
                },
            };
        },
        .ask_pattern => |selection| {
            if (input != null and input.? == .char) switch (input.?.char) {
                0x03 => {
                    selection.deinit(self.allocator);
                    self.state = .{ .select = Select.init(self.allocator, self.db) };
                    return null;
                },
                '\r' => {
                    return Result{
                        .submit = .{
                            .selection = selection,
                        },
                    };
                },
                else => {},
            };
            if (self.category.* != null) {
                if (self.existing_match_id) |id| {
                    try box.writer().writeAll("");
                    if (input != null and input.? == .char and input.?.char == 'p') {
                        return Result{
                            .submit = .{
                                .selection = selection,
                                .pattern = .{ .update = id },
                            },
                        };
                    }
                    try box.writer().writeAll("(⏎)complete, or update existing (p)attern.");
                } else {
                    return Result{
                        .submit = .{ .selection = selection },
                    };
                }
            } else {
                if (input != null and input.? == .char and input.?.char == 'p') {
                    self.state = .{ .pattern = Pattern.init(selection, self.allocator, self.note) };
                    return null;
                }
                try box.writer().writeAll("(⏎)complete, or create new (p)attern.");
            }
            return null;
        },
        .pattern => |*pattern| {
            if (try pattern.render(box, input)) |result| switch (result) {
                .cancel => {
                    pattern.deinit();
                    self.state = .{ .select = Select.init(self.allocator, self.db) };
                },
                .submit => |submission| {
                    return Result{
                        .submit = submission,
                    };
                },
            };
        },
    }
    return null;
}

const Selection = union(enum) {
    new: struct {
        group: union(enum) {
            new: []const u8,
            existing: i64,
        },
        name: []const u8,
    },
    existing: Database.CategoryId,

    pub fn deinit(self: @This(), allocator: *std.mem.Allocator) void {
        switch (self) {
            .existing => {},
            .new => |new| {
                allocator.free(new.name);
                switch (new.group) {
                    .existing => {},
                    .new => |new_group| {
                        allocator.free(new_group);
                    },
                }
            },
        }
    }
};

pub fn inputIsChar(input: ?ncurses.Key, char: u21) bool {
    return input != null and input.? == char and input.?.char == char;
}

const Select = struct {
    text: TextField,
    db: *const Database,
    allocator: *std.mem.Allocator,
    strings: std.ArrayList(u8),

    pub const SelectResult = union(enum) {
        submit: Selection,
        cancel,
    };
    pub const SelectError = error{InvalidUtf8} ||
        ncurses.Box.WriteError || std.mem.Allocator.Error;

    pub fn init(allocator: *std.mem.Allocator, db: *const Database) @This() {
        return .{
            .text = TextField.init(allocator),
            .db = db,
            .allocator = allocator,
            .strings = std.ArrayList(u8).init(allocator),
        };
    }
    pub fn deinit(self: *@This()) void {
        self.text.deinit();
        self.strings.deinit();
    }
    pub fn render(self: *@This(), box: *ncurses.Box, input: ?ncurses.Key) SelectError!?SelectResult {
        var input_mut = input;
        const writer = box.writer();

        const maybe_match = self.getMatch() catch null;
        const Action = union(enum) {
            new_category: struct {
                group: i64,
                category: []const u21,
            },
            new_group: struct {
                group: []const u21,
                category: []const u21,
            },
            set_existing: Database.CategoryId,
        };

        const value = self.text.value();

        const group_separator = &[_]u21{ ':', ' ' };
        const maybe_action = if (maybe_match) |match| switch (match.id) {
            .perfect => |id| Action{ .set_existing = id },
            .category_perfect => |id| Action{ .set_existing = .{ .budget = id } },
            .group_perfect_category_partial, .group_perfect => |id| blk: {
                if (std.mem.indexOf(u21, value, group_separator)) |index| {
                    if (index < self.text.value().len - 2 and std.mem.indexOf(u21, value[index + 2 ..], group_separator) == null)
                        break :blk Action{ .new_category = .{ .group = id, .category = value[index + 2 ..] } };
                }
                break :blk null;
            },
            else => null,
        } else blk: {
            if (std.mem.indexOf(u21, value, group_separator)) |index| {
                if (index > 0 and index < value.len - 2 and std.mem.indexOf(u21, value[index + 2 ..], group_separator) == null) {
                    break :blk Action{
                        .new_group = .{
                            .group = value[0..index],
                            .category = value[index + 2 ..],
                        },
                    };
                }
            }
            break :blk null;
        };

        if (input) |key| switch (key) {
            .char => |char| switch (char) {
                0x03 => return SelectResult.cancel,
                0x06 => {
                    input_mut = null;
                    if (maybe_match) |match| {
                        try self.text.set(match.completion);
                        self.text.cursor.start = self.text.value().len;
                    }
                },
                '\r' => {
                    if (maybe_action) |action| switch (action) {
                        .set_existing => |id| {
                            return SelectResult{
                                .submit = .{
                                    .existing = id,
                                },
                            };
                        },
                        .new_category => |new| {
                            var name_list = std.ArrayList(u8).init(self.allocator);
                            errdefer name_list.deinit();
                            for (new.category) |codepoint| {
                                var buffer: [4]u8 = undefined;
                                const len = std.unicode.utf8Encode(codepoint, &buffer) catch return error.InvalidUtf8;
                                try name_list.appendSlice(buffer[0..len]);
                            }
                            return SelectResult{
                                .submit = .{
                                    .new = .{
                                        .group = .{ .existing = new.group },
                                        .name = name_list.toOwnedSlice(),
                                    },
                                },
                            };
                        },
                        .new_group => |new| {
                            var group_list = std.ArrayList(u8).init(self.allocator);
                            errdefer group_list.deinit();
                            var name_list = std.ArrayList(u8).init(self.allocator);
                            errdefer name_list.deinit();
                            for (new.group) |codepoint| {
                                var buffer: [4]u8 = undefined;
                                const len = std.unicode.utf8Encode(codepoint, &buffer) catch return error.InvalidUtf8;
                                try group_list.appendSlice(buffer[0..len]);
                            }
                            for (new.category) |codepoint| {
                                var buffer: [4]u8 = undefined;
                                const len = std.unicode.utf8Encode(codepoint, &buffer) catch return error.InvalidUtf8;
                                try name_list.appendSlice(buffer[0..len]);
                            }
                            return SelectResult{
                                .submit = .{
                                    .new = .{
                                        .group = .{ .new = group_list.toOwnedSlice() },
                                        .name = name_list.toOwnedSlice(),
                                    },
                                },
                            };
                        },
                    };
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
            _ = try self.text.render(input_mut, box, "Enter a category");
        }
        if (maybe_action) |action| {
            const position = box.getPosition();
            box.attrSet(attr(.attention)) catch {};
            box.move(.{ .line = 1 });
            switch (action) {
                .new_category => try writer.writeAll("(create new category)"),
                .new_group => try writer.writeAll("(create new category and group)"),
                .set_existing => {},
            }
            if (position) |pos| box.move(pos) else box.out_of_bounds = true;
        }
        return null;
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
};

const NewPattern = struct {
    use_amount: bool,
    match_note: ?Database.CategoryMatchNote = null,
};
const Pattern = struct {
    selection: Selection,
    allocator: *std.mem.Allocator,
    use_amount: ?bool = null,
    match_note: ?PatternEditor = null,
    note: []const u8,

    pub const PatternResult = union(enum) {
        cancel,
        submit: Submission,
    };
    pub const PatternError = ncurses.Box.WriteError;

    pub fn init(selection: Selection, allocator: *std.mem.Allocator, note: []const u8) @This() {
        return .{
            .selection = selection,
            .allocator = allocator,
            .note = note,
        };
    }
    pub fn deinit(self: *@This()) void {
        self.selection.deinit(self.allocator);
    }
    pub fn render(self: *@This(), box: *ncurses.Box, input: ?ncurses.Key) PatternError!?PatternResult {
        const writer = box.writer();
        box.wrap = true;
        const input_char = if (input != null and input.? == .char) input.?.char else null;

        if (self.use_amount) |use_amount| {
            if (self.match_note) |*editor| {
                if (input_char) |char| switch (char) {
                    0x03 => {
                        self.match_note = null;
                        return null;
                    },
                    '\r' => {
                        return PatternResult{
                            .submit = .{
                                .selection = self.selection,
                                .pattern = .{
                                    .new = .{
                                        .use_amount = use_amount,
                                        .match_note = .{
                                            .match = editor.getMatch(),
                                            .value = editor.getValue(),
                                        },
                                    },
                                },
                            },
                        };
                    },
                    else => {},
                };
                _ = try editor.render(box, input);
                return null;
            }
            try writer.writeAll("Add a match on the note with an (e)xact, (p)refix, or (s)uffix pattern, or (⏎)continue.");
            if (input_char) |char| switch (char) {
                0x03 => self.use_amount = null,
                'e' => return PatternResult{
                    .submit = .{
                        .selection = self.selection,
                        .pattern = .{
                            .new = .{
                                .use_amount = use_amount,
                                .match_note = .{
                                    .match = .exact,
                                    .value = self.note,
                                },
                            },
                        },
                    },
                },
                'p' => self.match_note = PatternEditor.init(.prefix, self.note),
                's' => self.match_note = PatternEditor.init(.suffix, self.note),
                '\r' => return PatternResult{
                    .submit = .{
                        .selection = self.selection,
                        .pattern = .{
                            .new = .{
                                .use_amount = use_amount,
                            },
                        },
                    },
                },
                else => {},
            };
            return null;
        } else {
            try writer.writeAll("Autofill by amount? (y)es (⏎)no");
            if (input_char) |char| switch (char) {
                0x03 => return PatternResult.cancel,
                'y' => self.use_amount = true,
                '\r' => self.use_amount = false,
                else => {},
            };
            return null;
        }
    }
};
