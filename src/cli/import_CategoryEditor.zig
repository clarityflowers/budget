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
state: ?State = null,
category: *const ?import.Category,
note: []const u8,

const State = union(enum) {
    select: Select,
    pattern: Pattern,
};

pub fn init(
    allocator: *std.mem.Allocator,
    db: *const Database,
    category: *const ?import.Category,
    note: []const u8,
) @This() {
    return .{
        .allocator = allocator,
        .arena = std.heap.ArenaAllocator.init(allocator),
        .db = db,
        .category = category,
        .note = note,
    };
}

pub fn deinit(self: *@This()) void {
    self.arena.deinit();
}

pub const Submission = struct {
    selection: Selection,
    pattern: ?NewPattern = null,
};
pub const Result = union(enum) {
    input,
    submit: Submission,
};
pub const Error = Select.SelectError;

/// If the result contains a submission, the selection field contains memory owned by the caller
pub fn render(self: *@This(), box: *ncurses.Box, input: ?ncurses.Key) !?Result {
    box.move(.{});
    if (self.state) |*state| {
        switch (state.*) {
            .select => |*select| {
                if (try select.render(box, input)) |result| switch (result) {
                    .cancel => {
                        select.deinit();
                        self.state = null;
                        return Result.input;
                    },
                    .submit => |submission| {
                        if (submission.create_pattern) {
                            self.state = .{
                                .pattern = Pattern.init(
                                    submission.selection,
                                    self.allocator,
                                    self.note,
                                ),
                            };
                            return Result.input;
                        }
                        defer self.state = null;
                        return Result{
                            .submit = .{
                                .selection = submission.selection,
                            },
                        };
                    },
                };
                return Result.input;
            },
            .pattern => |*pattern| {
                if (try pattern.render(box, input)) |result| switch (result) {
                    .cancel => {
                        pattern.deinit();
                        self.state = .{ .select = Select.init(true, self.allocator, self.db) };
                    },
                    .submit => |submission| {
                        return Result{
                            .submit = submission,
                        };
                    },
                };
                return Result.input;
            },
        }
    } else {
        const writer = box.writer();
        if (self.category.*) |category| {
            try writer.writeAll("(s)elect a different category.");
            const new_state = if (input) |key| switch (key) {
                .control => return null,
                .char => |char| switch (char) {
                    's' => State{ .select = Select.init(false, &self.arena.allocator, self.db) },
                    else => return null,
                },
            } else return null;
            self.state = new_state;
            return Result.input;
        } else {
            try writer.writeAll("set (o)nce, or create an (a)utofill pattern.");
            const match = if (input) |key| switch (key) {
                .control => return null,
                .char => |char| switch (char) {
                    'o' => false,
                    'a' => true,
                    else => return null,
                },
            } else return null;
            self.state = .{
                .select = Select.init(match, &self.arena.allocator, self.db),
            };
            return Result.input;
        }
        return null;
    }
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

const Select = struct {
    create_pattern: bool,
    text: TextField,
    db: *const Database,
    allocator: *std.mem.Allocator,
    strings: std.ArrayList(u8),

    pub const SelectResult = union(enum) {
        submit: struct {
            selection: Selection,
            create_pattern: bool,
        },
        cancel,
    };
    pub const SelectError = error{InvalidUtf8} ||
        ncurses.Box.WriteError || std.mem.Allocator.Error;

    pub fn init(create_pattern: bool, allocator: *std.mem.Allocator, db: *const Database) @This() {
        return .{
            .create_pattern = create_pattern,
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
        const maybe_match = self.getMatch() catch null;
        const writer = box.writer();
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
            .control => {},
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
                                    .create_pattern = self.create_pattern,
                                    .selection = .{
                                        .existing = id,
                                    },
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
                                    .create_pattern = self.create_pattern,
                                    .selection = .{
                                        .new = .{
                                            .group = .{ .existing = new.group },
                                            .name = name_list.toOwnedSlice(),
                                        },
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
                                    .create_pattern = self.create_pattern,
                                    .selection = .{
                                        .new = .{
                                            .group = .{ .new = group_list.toOwnedSlice() },
                                            .name = name_list.toOwnedSlice(),
                                        },
                                    },
                                },
                            };
                        },
                    };
                    input_mut = null;
                },
                else => {},
            },
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
                                    .use_amount = use_amount,
                                    .match_note = .{
                                        .match = editor.getMatch(),
                                        .value = editor.getValue(),
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
                            .use_amount = use_amount,
                            .match_note = .{
                                .match = .exact,
                                .value = self.note,
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
                            .use_amount = use_amount,
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
