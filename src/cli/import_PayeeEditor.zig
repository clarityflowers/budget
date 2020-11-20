const std = @import("std");
const TextField = @import("TextField.zig");
const ncurses = @import("ncurses.zig");
const import = @import("../import.zig");
const sqlite = @import("../sqlite-zig/src/sqlite.zig");
const attr = @import("attributes.zig").attr;
const Cursor = @import("Cursor.zig");
const Database = @import("import_Database.zig");
const PatternEditor = @import("import_PatternEditor.zig");

text_field: TextField,
mode: ?union(enum) {
    edit: struct {
        payee: ?EditPayee = null,
        pattern: ?Pattern = null,
    },
    rename: ?[]const u8,
} = null,
payee: *import.ImportPayee,
payees: *import.Payees,
accounts: *const import.Accounts,
submitted: bool = false,
db: Database,
strings: std.ArrayList(u8),
allocator: *std.mem.Allocator,
payee_autocompletes: std.ArrayList(PayeeAutocomplete),
err: std.ArrayList(u8),

const Pattern = union(enum) {
    exact,
    partial: PatternEditor,
};

const EditPayee = union(enum) {
    existing: Database.PayeeId,
    new,
};

const PayeeAutocomplete = struct {
    name: []const u8,
    sort_rank: c_int,
    id: Database.PayeeId,
};

pub fn init(
    db: Database,
    payee: *import.ImportPayee,
    payees: *import.Payees,
    accounts: *const import.Accounts,
    allocator: *std.mem.Allocator,
) @This() {
    return @This(){
        .text_field = TextField.init(allocator),
        .payee = payee,
        .allocator = allocator,
        .payees = payees,
        .accounts = accounts,
        .payee_autocompletes = std.ArrayList(PayeeAutocomplete).init(allocator),
        .strings = std.ArrayList(u8).init(allocator),
        .db = db,
        .err = std.ArrayList(u8).init(allocator),
    };
}

pub fn deinit(self: *@This()) void {
    self.text_field.deinit();
    self.payee_autocompletes.deinit();
    self.strings.deinit();
    self.err.deinit();
}

/// Returns true if the input was consumed and should not be bubbled up
pub fn render(
    self: *@This(),
    input_key: ?ncurses.Key,
    window: *ncurses.Box,
) !bool {
    var input = input_key;
    window.move(.{});
    const writer = window.writer();

    if (self.err.items.len > 0) {
        if (input == null) {
            window.attrSet(attr(.err)) catch {};
            writer.writeAll(self.err.items) catch {};
            return false;
        }
        self.err.shrinkRetainingCapacity(0);
    }

    const char_input = if (input != null and input.? == .char) input.?.char else null;
    const control_input = if (input != null and input.? == .control) input.?.control else null;
    const submit = char_input != null and char_input.? == '\r';
    const cancel = char_input != null and char_input.? == 0x03;
    if (self.mode) |*mode| switch (mode.*) {
        .edit => |*edit| {
            if (edit.payee) |payee|
                if (edit.pattern) |*pattern| switch (pattern.*) {
                    .partial => |*editor| {
                        if (submit) {
                            if (self.setPayee(payee)) |id| {
                                if (self.db.createPayeeMatch(id, editor.getMatch(), editor.getValue())) {
                                    return false;
                                } else |err| {
                                    self.err.shrinkRetainingCapacity(0);
                                    self.err.writer().print(
                                        "Error creating payee match: {}",
                                        .{self.db.getError()},
                                    ) catch {};
                                    return true;
                                }
                            } else |err| switch (err) {
                                error.Skip => {},
                                else => return err,
                            }
                        }
                        if (cancel) {
                            edit.payee = null;
                            return true;
                        }
                        return try editor.render(window, input);
                    },
                    .exact => {
                        const str = self.payee.unknown;
                        if (self.setPayee(payee)) |id| {
                            if (try self.db.createPayeeMatch(id, .exact, str)) {
                                return false;
                            } else |err| {
                                self.err.shrinkRetainingCapacity(0);
                                self.err.writer().writeAll("Error creating payee match.", .{});
                            }
                        } else |err| switch (err) {
                            error.Skip => {
                                return true;
                            },
                            else => return err,
                        }
                    },
                } else {
                    if (self.setPayee(payee)) |id| {
                        return false;
                    } else |err| switch (err) {
                        error.Skip => {
                            return true;
                        },
                        else => return err,
                    }
                }
            else {
                const autocompletes = try self.getAutocompletes();
                const perfect_match = autocompletes.len > 0 and autocompletes[0].sort_rank == 0;

                if (char_input) |char| {
                    switch (char) {
                        0x03 => { // ^C
                            self.mode = null;
                            self.text_field.reset();
                            input = null;
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
                                    .new;

                                @import("../log.zig").debug("Test {}\n{}\n", .{ self.payee, edit.pattern });
                                edit.payee = edit_payee;
                            }
                        },
                        else => {},
                    }
                }
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
                _ = try self.text_field.render(
                    input,
                    window,
                    0,
                    "(enter a payee)",
                );
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

                return true;
            }
        },
        .rename => |rename| {
            if (rename == null) {
                if (char_input) |char| switch (char) {
                    0x03 => { // ^C
                        self.mode = null;
                        self.text_field.reset();
                        input = null;
                    },
                    '\r' => {
                        // TODO
                        input = null;
                    },
                    else => {},
                };
                _ = try self.text_field.render(
                    input,
                    window,
                    0,
                    "(enter a new name)",
                );
                return true;
            }
        },
    } else {
        self.text_field.reset();
        switch (self.payee.*) {
            .unknown => |unknown| {
                writer.print("set (o)nce, or create an (e)xact, (p)refix, or (s)uffix pattern.", .{}) catch {};
                const pattern: ?Pattern = if (char_input) |char| switch (char) {
                    'o' => null,
                    'e' => Pattern{ .exact = {} },
                    'p' => Pattern{ .partial = PatternEditor.init(.prefix, unknown) },
                    's' => Pattern{ .partial = PatternEditor.init(.suffix, unknown) },
                    else => return false,
                } else return false;
                self.mode = .{
                    .edit = .{ .pattern = pattern },
                };
                return true;
            },
            .transfer => {
                writer.print("choose a (d)ifferent payee", .{}) catch {};
                var consumed = char_input != null;
                if (char_input) |char| switch (char) {
                    'd' => self.mode = .{ .edit = .{} },
                    else => consumed = false,
                };
                return consumed;
            },
            .payee => {
                var consumed = char_input != null;
                writer.print("choose a (d)ifferent payee or (r)ename this one", .{}) catch {};
                if (char_input) |char| switch (char) {
                    'd' => self.mode = .{ .edit = .{} },
                    'r' => self.mode = .{ .rename = null },
                    else => consumed = false,
                };
                return consumed;
            },
        }
    }

    return false;
}

fn getAutocompletes(self: *@This()) ![]const PayeeAutocomplete {
    self.strings.shrinkRetainingCapacity(0);
    const statement = self.db.payee_autocomplete;
    self.payee_autocompletes.shrinkRetainingCapacity(0);
    const empty_result: [0]PayeeAutocomplete = undefined;
    statement.reset() catch {
        self.err.shrinkRetainingCapacity(0);
        try self.err.writer().print("Error resetting query: {}", .{statement.dbHandle().errmsg()});
        return empty_result[0..];
    };
    const value_utf32 = self.text_field.value();

    var start: usize = 0;
    const stringsWriter = self.strings.writer();
    try self.text_field.printValue(stringsWriter);

    try statement.bindText(1, self.strings.items);

    while (statement.step() catch {
        self.err.shrinkRetainingCapacity(0);
        try self.err.writer().print("Autocomplete error: {}", .{
            statement.dbHandle().errmsg(),
        });

        return empty_result[0..];
    }) {
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
        // self.err.shrinkRetainingCapacity(0);
        // try self.err.writer().print("Found payee: {}", .{
        //     name,
        // });
    }
    return self.payee_autocompletes.items;
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

fn setPayee(self: *@This(), edit_payee: EditPayee) !Database.PayeeId {
    switch (edit_payee) {
        .existing => |id| {
            self.payee.* = switch (id) {
                .payee => |payee_id| .{
                    .payee = &(self.payees.getEntry(payee_id) orelse unreachable).value,
                },
                .transfer => |transfer_id| .{
                    .transfer = &(self.accounts.getEntry(transfer_id) orelse unreachable).value,
                },
            };
            return id;
        },
        .new => {
            var name_buffer = std.ArrayList(u8).init(self.allocator);
            defer name_buffer.deinit();
            try self.text_field.printValue(name_buffer.writer());
            const id = self.db.createPayee(name_buffer.items) catch |err| {
                self.err.shrinkRetainingCapacity(0);
                try self.err.writer().print("Error creating payee: {} ({})", .{ @errorName(err), self.db.getError() });
                return error.Skip;
            };
            try self.payees.put(id, .{ .id = id, .name = name_buffer.toOwnedSlice() });

            self.payee.* = .{ .payee = &(self.payees.getEntry(id) orelse unreachable).value };
            return Database.PayeeId{ .payee = id };
        },
    }
}
