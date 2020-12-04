const std = @import("std");
const TextField = @import("TextField.zig");
const ncurses = @import("ncurses.zig");
const import = @import("../import.zig");
const sqlite = @import("../sqlite-zig/src/sqlite.zig");
const attr = @import("attributes.zig").attr;
const Cursor = @import("Cursor.zig");
const Database = @import("import_Database.zig");
const PatternEditor = @import("import_PatternEditor.zig");
const Err = @import("Err.zig");

state: ?union(enum) {
    edit: Edit,
    rename: Rename,
    pattern: Pattern,
} = null,
payee: import.ImportPayee,
allocator: *std.mem.Allocator,
err: Err,

pub const EditPayee = union(enum) {
    existing: Database.PayeeId,
    new: []const u8,

    pub fn deinit(self: @This(), allocator: *std.mem.Allocator) void {
        switch (self) {
            .new => |str| allocator.free(str),
            else => {},
        }
    }
};

const PayeeAutocomplete = struct {
    name: []const u8,
    sort_rank: c_int,
    id: Database.PayeeId,
};

pub fn init(
    payee: import.ImportPayee,
    allocator: *std.mem.Allocator,
) @This() {
    return @This(){
        .payee = payee,
        .allocator = allocator,
        .err = Err.init(allocator),
    };
}

pub fn deinit(self: *@This()) void {
    if (self.state) |*state| switch (state.*) {
        .edit => |*editor| editor.deinit(),
        .rename => |*rename| rename.deinit(),
        .pattern => |*editor| editor.deinit(),
    };
    self.err.deinit();
    self.state = null;
}

pub const Result = union(enum) {
    /// The payee is owned by the caller
    submit: struct {
        payee: EditPayee,
        match: ?struct {
            match: Database.Match,
            pattern: []const u8,
        } = null,
    },
    /// The input should not be bubbled up
    input_consumed,
};

pub const Error = Edit.EditError ||
    Pattern.PatternError || Rename.RenameError;

/// Can potentially return memory owned by the caller
pub fn render(
    self: *@This(),
    input_key: ?ncurses.Key,
    window: *ncurses.Box,
    db: *Database,
) Error!?Result {
    var input = input_key;
    window.move(.{});
    const writer = window.writer();

    if (try self.err.render(window)) {
        if (input != null) {
            input = null;
            self.err.reset();
        }
    }

    if (self.state) |*state| switch (state.*) {
        .edit => |*edit| {
            if (try edit.render(window, input, db)) |edit_res| {
                switch (edit_res) {
                    .cancel => {
                        edit.deinit();
                        self.state = null;
                    },
                    .submit => |submission| {
                        if (submission.match) |match| {
                            if (self.payee == .unknown) {
                                if (match == .exact) {
                                    self.state = null;
                                    edit.deinit();
                                    return Result{
                                        .submit = .{
                                            .payee = submission.payee,
                                            .match = .{
                                                .match = .exact,
                                                .pattern = self.payee.unknown,
                                            },
                                        },
                                    };
                                } else {
                                    self.state = .{
                                        .pattern = Pattern.init(
                                            submission.payee,
                                            switch (submission.match.?) {
                                                .prefix => .prefix,
                                                .suffix => .suffix,
                                                else => unreachable,
                                            },
                                            self.payee.unknown,
                                        ),
                                    };
                                    return Result.input_consumed;
                                }
                            }
                        }
                        return Result{ .submit = .{ .payee = submission.payee } };
                    },
                }
                return Result.input_consumed;
            }
        },
        .pattern => |*pattern| {
            if (try pattern.render(window, input)) |result| switch (result) {
                .cancel => {
                    pattern.deinit();
                    self.state = null;
                },
                .submit => |submit| {
                    defer pattern.deinit();
                    defer self.state = null;
                    return Result{
                        .submit = .{
                            .payee = submit.payee,
                            .match = .{
                                .match = submit.match,
                                .pattern = submit.pattern,
                            },
                        },
                    };
                },
            };
            return Result.input_consumed;
        },
    } else {
        const char_input = if (input != null and input.? == .char) input.?.char else null;
        switch (self.payee) {
            .unknown => |unknown| {
                writer.print("set (o)nce, or create an (e)xact, (p)refix, or (s)uffix pattern.", .{}) catch {};
                const pattern: ?Database.Match = if (char_input) |char| switch (char) {
                    'o' => null,
                    'e' => Database.Match.exact,
                    'p' => Database.Match.prefix,
                    's' => Database.Match.suffix,
                    else => return null,
                } else return null;
                self.state = .{
                    .edit = Edit.init(self.allocator, pattern),
                };
                return Result.input_consumed;
            },
            .transfer => {
                writer.print("choose a (d)ifferent payee", .{}) catch {};
                var consumed = char_input != null;
                if (char_input) |char| switch (char) {
                    'd' => self.state = .{ .edit = Edit.init(self.allocator, null) },
                    else => consumed = false,
                };
                return if (consumed) Result.input_consumed else null;
            },
            .payee => {
                var consumed = char_input != null;
                writer.print("choose a (d)ifferent payee or (r)ename this one", .{}) catch {};
                if (char_input) |char| switch (char) {
                    'd' => self.state = .{ .edit = Edit.init(self.allocator, null) },
                    'r' => self.state = .{ .rename = Rename.init(self.allocator) },
                    else => consumed = false,
                };
                return if (consumed) Result.input_consumed else null;
            },
        }
    }

    return null;
}

fn storeString(strings: *std.ArrayList(u8), str: []const u8) ![]u8 {
    const start = strings.items.len;
    try strings.appendSlice(str);
    return strings.items[start..];
}

fn writeCodepoint(writer: anytype, codepoint: u21) !void {
    var buffer: [4]u8 = undefined;
    const len = try std.unicode.utf8Encode(codepoint, &buffer);
    try writer.writeAll(buffer[0..len]);
}

const log = @import("../log.zig");

const Edit = struct {
    strings: std.ArrayList(u8),
    err: Err,
    text_field: TextField,
    payee_autocompletes: std.ArrayList(PayeeAutocomplete),
    match: ?Database.Match,

    pub const EditError = Database.Error ||
        std.mem.Allocator.Error ||
        error{InvalidUtf8};

    const Match = enum {
        exact, prefix, suffix
    };

    const EditResult = union(enum) {
        submit: struct {
            payee: EditPayee, match: ?Database.Match
        },
        cancel,
    };

    pub fn init(allocator: *std.mem.Allocator, match: ?Database.Match) @This() {
        return .{
            .strings = std.ArrayList(u8).init(allocator),
            .err = Err.init(allocator),
            .text_field = TextField.init(allocator),
            .match = match,
            .payee_autocompletes = std.ArrayList(PayeeAutocomplete).init(allocator),
        };
    }

    pub fn deinit(self: *@This()) void {
        self.strings.deinit();
        self.err.deinit();
        self.text_field.deinit();
    }

    /// Returns true on submit or cancel
    pub fn render(
        self: *@This(),
        window: *ncurses.Box,
        key: ?ncurses.Key,
        db: *Database,
    ) EditError!?EditResult {
        var input = key;
        const writer = window.writer();
        if (try self.err.render(window)) {
            if (input != null) {
                self.err.reset();
                input = null;
            }
        }
        const autocompletes = self.getAutocompletes(db) catch |err| switch (err) {
            error.PayeeAutocompleteFailed => &[_]PayeeAutocomplete{},
            else => |other_err| return other_err,
        };
        const perfect_match = autocompletes.len > 0 and autocompletes[0].sort_rank == 0;
        if (input) |in| switch (in) {
            .char => |char| switch (char) {
                0x03 => { // ^C
                    return EditResult.cancel;
                },
                0x06 => { // ^F
                    input = null;
                    if (autocompletes.len > 0) {
                        try self.text_field.set(autocompletes[0].name);
                        self.text_field.cursor.start = self.text_field.value().len;
                    }
                },
                '\r' => {
                    input = null;
                    if (self.text_field.value().len > 0) {
                        const edit_payee: EditPayee = if (perfect_match)
                            .{ .existing = autocompletes[0].id }
                        else
                            .{ .new = try self.text_field.copyValue() };
                        return EditResult{
                            .submit = .{
                                .payee = edit_payee,
                                .match = self.match,
                            },
                        };
                    }
                },
                else => {},
            },
            else => {},
        };

        const maybe_completion = blk: {
            if (perfect_match) {
                if (autocompletes.len > 1) break :blk autocompletes[1];
                break :blk null;
            }
            if (autocompletes.len > 0) break :blk autocompletes[0];
            break :blk null;
        };

        if (maybe_completion) |completion| {
            window.attrSet(attr(.dim)) catch {};
            writer.writeAll(completion.name) catch {};
            if (completion.sort_rank == 2) {
                window.move(.{
                    .column = "Transfer to ".len,
                });
            } else {
                window.move(.{});
            }
        }
        window.attrSet(0) catch {};
        if (perfect_match) {
            window.attrSet(attr(.attention)) catch {};
        }
        _ = try self.text_field.render(input, window, "(enter a payee)");
        const position = window.getPosition();
        if (!perfect_match and self.text_field.value().len > 0 and self.text_field.err.items.len == 0) {
            const action = "(create new payee)";

            window.move(.{ .line = 1 });
            window.attrSet(attr(.attention)) catch {};
            writer.writeAll(action) catch {};
        }
        if (position) |p| {
            window.move(p);
        }

        return null;
    }

    fn getAutocompletes(
        self: *@This(),
        db: *Database,
    ) ![]const PayeeAutocomplete {
        self.strings.shrinkRetainingCapacity(0);
        const statement = db.payee_autocomplete;
        self.payee_autocompletes.shrinkRetainingCapacity(0);
        const empty_result: [0]PayeeAutocomplete = undefined;
        statement.reset() catch return error.PayeeAutocompleteFailed;
        const value_utf32 = self.text_field.value();

        var start: usize = 0;
        const stringsWriter = self.strings.writer();
        try self.text_field.printValue(stringsWriter);

        statement.bindText(1, self.strings.items) catch return error.PayeeAutocompleteFailed;

        while (statement.step() catch return error.PayeeAutocompleteFailed) {
            const name = try storeString(&self.strings, statement.columnText(0));
            const sort_rank = statement.columnInt(3);
            switch (statement.columnType(1)) {
                .Null => {
                    const payee_id = statement.columnInt64(2);
                    try self.payee_autocompletes.append(.{
                        .name = name,
                        .id = .{ .payee = payee_id },
                        .sort_rank = sort_rank,
                    });
                },
                else => {
                    const transfer_id = statement.columnInt64(1);
                    try self.payee_autocompletes.append(.{
                        .name = name,
                        .id = .{ .transfer = transfer_id },
                        .sort_rank = sort_rank,
                    });
                },
            }
        }
        return self.payee_autocompletes.items;
    }
};

const Pattern = struct {
    pattern_editor: PatternEditor,
    payee: EditPayee,

    pub const PatternError = error{};

    const PatternResult = union(enum) {
        cancel, submit: struct {
            payee: EditPayee,
            match: Database.Match,
            pattern: []const u8,
        }
    };

    pub fn init(
        payee: EditPayee,
        match: @TagType(PatternEditor.Pattern),
        str: []const u8,
    ) @This() {
        return .{
            .pattern_editor = switch (match) {
                .prefix => PatternEditor.init(.prefix, str),
                .suffix => PatternEditor.init(.suffix, str),
            },
            .payee = payee,
        };
    }

    pub fn deinit(self: *@This()) void {}

    pub fn render(self: *@This(), window: *ncurses.Box, input: ?ncurses.Key) PatternError!?PatternResult {
        if (input) |in| switch (in) {
            .char => |char| switch (char) {
                '\r' => {
                    return PatternResult{
                        .submit = .{
                            .payee = self.payee,
                            .match = self.pattern_editor.getMatch(),
                            .pattern = self.pattern_editor.getValue(),
                        },
                    };
                },
                0x03 => {
                    return PatternResult.cancel;
                },
                else => {},
            },
            else => {},
        };
        _ = try self.pattern_editor.render(window, input);
        return null;
    }
};
