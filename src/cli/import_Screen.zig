const std = @import("std");
const AmountEditor = @import("import_AmountEditor.zig");
const DateEditor = @import("import_DateEditor.zig");
const PayeeEditor = @import("import_PayeeEditor.zig");
const CategoryEditor = @import("import_CategoryEditor.zig");
const MemoEditor = @import("import_MemoEditor.zig");
const sqlite = @import("../sqlite-zig/src/sqlite.zig");
const ncurses = @import("ncurses.zig");
const import = @import("../import.zig");
const log = @import("../log.zig");
const attr = @import("attributes.zig").attr;
const Database = @import("import_Database.zig");
const list = @import("import_list.zig");
const Err = @import("Err.zig");
const unicode = @import("unicode.zig");

db: Database,
allocator: *std.mem.Allocator,
data: *import.PreparedImport,
// payees: std.AutoHashMap(i64, import.Payee),
state: ScreenState = .{},
attempting_interrupt: bool = false,
initialized: bool = false,
err: Err,

// COMMANDS
// tab/shift+tab   go to next/previous field
// down/up         go to next/previous transaction
// enter           go to next empty field
// space           edit currently selected field
// ^c              quit
// `               show console output

seen_instructions: bool = false,

const Field = union(list.FieldTag) {
    date: ?DateEditor,
    amount: ?AmountEditor,
    payee: ?PayeeEditor,
    category: ?CategoryEditor,
    memo: ?MemoEditor,
};
const ScreenState = struct {
    field: Field,
    current: usize = 0,
};

pub const DB = struct {};

pub fn init(
    db: *const sqlite.Database,
    data: *import.PreparedImport,
    allocator: *std.mem.Allocator,
) !@This() {
    std.debug.assert(data.transactions.len > 0);
    var database = try Database.init(db);
    errdefer db.deinit();

    var result: @This() = .{
        .db = database,
        .data = data,
        .allocator = allocator,
        .state = .{
            .field = .{ .payee = null },
        },
        .err = Err.init(allocator),
    };
    return result;
}

pub fn deinit(self: *@This()) void {
    self.db.deinit();
    self.err.deinit();
}

pub fn isMissing(self: @This(), state: ScreenState) bool {
    const transaction = self.data.transactions[state.current];
    return switch (state.field) {
        .amount => transaction.amount == 0,
        .date => false,
        .payee => transaction.payee == .unknown,
        .category => transaction.payee == .payee and transaction.category == null,
        .memo => false,
    };
}

pub fn getNextMissing(self: @This()) ?ScreenState {
    const current = self.data.transactions[self.state.current];
    var result = self.next(self.state);
    while (!self.isMissing(result)) {
        result = self.next(result);
        if (result.current == self.state.current and @as(list.FieldTag, result.field) == self.state.field) return null;
    }
    return result;
}

pub fn moveUp(self: @This(), state: ScreenState) ScreenState {
    var result = state;
    if (result.current == 0) {
        result.current = self.data.transactions.len - 1;
    } else {
        result.current -= 1;
    }
    switch (result.field) {
        .date => result.field = .{ .date = null },
        .amount => result.field = .{ .amount = null },
        .payee => result.field = .{ .payee = null },
        .category => {
            if (self.data.transactions[result.current].payee == .payee) {
                result.field = .{ .category = null };
            } else {
                result.field = .{ .payee = null };
            }
        },
        .memo => result.field = .{ .memo = null },
    }
    return result;
}

pub fn moveDown(self: @This(), state: ScreenState) ScreenState {
    var result = state;
    result.current = (result.current + 1) % self.data.transactions.len;
    switch (result.field) {
        .date => result.field = .{ .date = null },
        .amount => result.field = .{ .amount = null },
        .payee => result.field = .{ .payee = null },
        .category => {
            if (self.data.transactions[result.current].payee == .payee) {
                result.field = .{ .category = null };
            } else {
                result.field = .{ .payee = null };
            }
        },
        .memo => result.field = .{ .memo = null },
    }
    return result;
}

pub fn next(self: @This(), state: ScreenState) ScreenState {
    var result = state;
    switch (result.field) {
        .date => {
            result.field = .{ .amount = null };
        },
        .amount => {
            result.field = .{ .payee = null };
        },
        .payee => {
            if (self.data.transactions[result.current].payee == .payee) {
                result.field = .{ .category = null };
            } else {
                result.field = .{ .memo = null };
            }
        },
        .category => {
            result.field = .{ .memo = null };
        },
        .memo => {
            result = self.moveDown(result);
            result.field = .{ .date = null };
        },
    }
    return result;
}
pub fn prev(self: @This(), state: ScreenState) ScreenState {
    var result = state;
    switch (result.field) {
        .date => {
            result = self.moveUp(result);
            result.field = .{ .memo = null };
        },
        .amount => {
            result.field = .{ .date = null };
        },
        .payee => {
            result.field = .{ .amount = null };
        },
        .category => {
            result.field = .{ .payee = null };
        },
        .memo => {
            if (self.data.transactions[result.current].payee == .payee) {
                result.field = .{ .category = null };
            } else {
                result.field = .{ .payee = null };
            }
        },
    }
    return result;
}

/// Returns true if the import is completed and falkse
pub fn render(
    self: *@This(),
    box: *ncurses.Box,
    input_key: ?ncurses.Key,
) !bool {
    return self.render_internal(box, input_key) catch |err| {
        switch (err) {
            error.CreatePayeeFailed,
            error.CreatePayeeMatchFailed,
            error.UpdateMatchFailed,
            error.RenamePayeeFailed,
            error.CreateCategoryGroupFailed,
            error.CreateCategoryMatchFailed,
            error.CreateCategoryFailed,
            error.AutofillPayeesFailed,
            error.AutofillCategoriesFailed,
            => self.err.set("Err: {}. {}", .{ @errorName(err), self.db.getError() }) catch {},
            error.OutOfMemory,
            error.InvalidUtf8,
            error.NCursesWriteFailed,
            => self.err.set("Err: {}", .{@errorName(err)}) catch {},
            error.Interrupted => |other_err| return other_err,
        }
        if (std.builtin.mode == .Debug) {
            log.err("Encountered error: {} {}", .{ err, @errorReturnTrace() });
        }
        return false;
    };
}

const Error = error{
    AutofillPayeesFailed,
    Interrupted,
    CreateCategoryGroupFailed,
    CreateCategoryFailed,
    CreateCategoryMatchFailed,
    AutofillCategoriesFailed,
    UpdateMatchFailed,
} || std.mem.Allocator.Error ||
    PayeeEditor.Error;

fn render_internal(
    self: *@This(),
    box: *ncurses.Box,
    input_key: ?ncurses.Key,
) Error!bool {
    if (self.initialized == false) {
        if (self.data.transactions[0].payee != .unknown) {
            self.state = self.getNextMissing() orelse self.state;
        }
        self.initialized = true;
    }
    var input = input_key;
    const transactions = self.data.transactions;

    const divider_line = box.bounds.height - 3;

    box.setCursor(.invisible);
    try list.render(
        &box.box(.{
            .height = divider_line,
        }),
        self.state.current,
        self.state.field,
        self.data.transactions,
    );

    box.move(.{ .line = divider_line });
    box.fillLine('═') catch {};

    if (input != null and input.? == .char and input.?.char == 0x04) { //^D
        std.process.exit(1);
    }

    const current_missing = self.isMissing(self.state);
    const after_submit = if (current_missing) ncurses.Key{ .char = '\r' } else ncurses.Key{ .char = '\t' };

    const char_input = if (input != null and input.? == .char) input.?.char else null;

    var lower_box = box.box(.{ .line = divider_line + 1, .height = 3 });
    lower_box.move(.{});

    if (self.err.active()) {
        if (try self.err.render(&lower_box, input)) {
            input = null;
        } else return false;
    }

    const select = char_input != null and char_input.? == ' ';

    if (self.attempting_interrupt) {
        lower_box.move(.{});
        lower_box.writer().print("Press ^C again to quit.", .{}) catch {};
    } else {
        const writer = lower_box.writer();
        if (!self.seen_instructions) {
            if (input != null) {
                self.seen_instructions = true;
            } else {
                try writer.writeAll("( )edit (tab/s-tab)next/prev value (↓/↑)next/prev item (ret)next unfilled");
            }
        }
        const transaction = &self.data.transactions[self.state.current];

        switch (self.state.field) {
            .date => |*maybe_editor| {
                if (maybe_editor.*) |*date_editor| {
                    if (try date_editor.render(&lower_box, input)) |result| switch (result) {
                        .cancel => {
                            date_editor.deinit();
                            maybe_editor.* = null;
                            input = null;
                        },
                        .submit => |date| {
                            transaction.date = date;
                            input = after_submit;
                        },
                    } else input = null;
                } else if (select) {
                    var editor = DateEditor.init(transaction.date);
                    maybe_editor.* = editor;
                }
            },
            .amount => |*maybe_editor| {
                if (maybe_editor.*) |*amount_editor| {
                    if (try amount_editor.render(&lower_box, input)) |result| switch (result) {
                        .cancel => {
                            amount_editor.deinit();
                            maybe_editor.* = null;
                            input = null;
                        },
                        .submit => |amount| {
                            transaction.amount = amount;
                            input = after_submit;
                        },
                    } else input = null;
                } else if (select) {
                    var editor = AmountEditor.init(transaction.amount);
                    maybe_editor.* = editor;
                }
            },
            .payee => |*maybe_editor| {
                if (maybe_editor.*) |*payee_editor| {
                    const result = try payee_editor.render(input, &lower_box, &self.db);
                    if (result) |res| switch (res) {
                        .cancel => {
                            payee_editor.deinit();
                            maybe_editor.* = null;
                            input = null;
                        },
                        .submit => |submission| {
                            defer submission.payee.deinit(self.allocator);
                            const current_payee = self.data.transactions[self.state.current].payee;
                            const id = try self.setPayee(submission.payee);
                            switch (current_payee) {
                                .unknown => |unknown| {
                                    if (submission.match) |match| {
                                        _ = try self.createMatch(id, match.match, match.pattern);
                                        try import.autofillPayees(
                                            self.db.handle,
                                            "",
                                            self.data.transactions,
                                            &self.data.payees,
                                            &self.data.accounts,
                                        );
                                    }
                                },
                                else => {},
                            }
                            // After filling out a payee, autofill that transaction's categories
                            try import.autofillCategories(
                                self.db.handle,
                                self.data.transactions[self.state.current .. self.state.current + 1],
                                &self.data.categories,
                            );
                            input = after_submit;
                        },
                    } else input = null;
                } else if (select) {
                    var editor = PayeeEditor.init(transaction.payee, self.allocator);
                    maybe_editor.* = editor;
                }
            },
            .category => |*maybe_editor| {
                if (maybe_editor.*) |*category| {
                    if (try category.render(&lower_box, input)) |result| switch (result) {
                        .cancel => {
                            category.deinit();
                            maybe_editor.* = null;
                            input = null;
                        },
                        .submit => |submission| {
                            const id = switch (submission.selection) {
                                .existing => |id| blk: {
                                    switch (id) {
                                        .income => {
                                            transaction.category = .income;
                                        },
                                        .budget => |category_id| {
                                            transaction.category = .{
                                                .budget = &(self.data.categories.getEntry(category_id) orelse unreachable).value,
                                            };
                                        },
                                    }
                                    break :blk id;
                                },
                                .new => |new| new_blk: {
                                    const group = switch (new.group) {
                                        .existing => |id| &(self.data.category_groups.getEntry(id) orelse {
                                            try self.err.set("Entry not found: {}", .{id});
                                            return false;
                                        }).value,
                                        .new => |name| blk: {
                                            const name_utf8 = try unicode.encodeUtf8Alloc(name, self.allocator);
                                            errdefer self.allocator.free(name_utf8);
                                            const id = try self.db.createCategoryGroup(name_utf8);
                                            const res = try self.data.category_groups.getOrPut(id);
                                            std.debug.assert(!res.found_existing);
                                            res.entry.value = .{ .id = id, .name = name_utf8 };
                                            break :blk &res.entry.value;
                                        },
                                    };
                                    const name_utf8 = try unicode.encodeUtf8Alloc(new.name, self.allocator);
                                    errdefer self.allocator.free(name_utf8);
                                    const id = try self.db.createCategory(group.id, name_utf8);
                                    const res = try self.data.categories.getOrPut(id);
                                    std.debug.assert(!res.found_existing);
                                    res.entry.value = .{
                                        .id = id,
                                        .group = group,
                                        .name = name_utf8,
                                    };
                                    transaction.category = .{
                                        .budget = &res.entry.value,
                                    };
                                    break :new_blk Database.CategoryId{ .budget = id };
                                },
                            };
                            if (submission.pattern) {
                                const category_id = switch (id) {
                                    .income => @as(?i64, null),
                                    .budget => |budget_id| @as(?i64, budget_id),
                                };
                                self.db.handle.execBind("INSERT OR REPLACE INTO category_matches(category_id, payee_id) VALUES (?, ?)", .{
                                    category_id,
                                    transaction.payee.payee.id,
                                }) catch return Error.CreateCategoryMatchFailed;

                                try import.autofillCategories(
                                    self.db.handle,
                                    self.data.transactions,
                                    &self.data.categories,
                                );
                            }
                            input = after_submit;
                        },
                    } else return false;
                } else if (select) {
                    const existing_match_id = if (try self.db.category_autofill.get(
                        transaction.payee.payee.id,
                        transaction.memo,
                        transaction.amount,
                        &self.data.categories,
                    )) |match| match.autofill_id else null;
                    var editor = CategoryEditor.init(
                        self.allocator,
                        &self.db,
                        &transaction.category,
                        existing_match_id,
                    );
                    maybe_editor.* = editor;
                }
            },
            .memo => |*maybe_editor| {
                if (maybe_editor.*) |*memo| {
                    if (try memo.render(&lower_box, input)) |result| switch (result) {
                        .cancel => {
                            memo.deinit();
                            maybe_editor.* = null;
                            input = null;
                        },
                        .submit => |new_memo| {
                            transaction.memo = new_memo;
                            input = after_submit;
                        },
                    } else return false;
                } else if (select) {
                    maybe_editor.* = try MemoEditor.init(
                        self.allocator,
                        transaction.memo,
                    );
                    return false;
                }
            },
        }
    }

    var attempting_interrupt = false;
    var new_state: ?ScreenState = null;
    if (input) |key| {
        switch (key) {
            .control => |ctl| switch (ctl) {
                ncurses.key.up => {
                    new_state = self.moveUp(self.state);
                },
                ncurses.key.down => {
                    new_state = self.moveDown(self.state);
                },
                ncurses.key.btab => {
                    new_state = self.prev(self.state);
                },
                else => {},
            },
            .char => |chr| switch (chr) {
                0x03 => { // ^C
                    if (self.attempting_interrupt) {
                        return error.Interrupted;
                    } else {
                        attempting_interrupt = true;
                    }
                },
                '`' => {
                    ncurses.end();
                    defer ncurses.refresh() catch {};

                    log.printLogfile();

                    const stdout = std.io.getStdOut().writer();
                    stdout.writeAll("\n[Press return to resume]") catch {};
                    // TODO - this isn't portable. dunno if I care.
                    // 1T - scroll up 1 line
                    // K - delete to end of line
                    defer stdout.writeAll("\x1B[2T" ++ "\x1B[K") catch {};

                    var buffer: [1]u8 = undefined;
                    _ = std.io.getStdIn().reader().read(&buffer) catch {};
                },
                '\r' => {
                    new_state = self.getNextMissing();
                },
                '\t' => {
                    new_state = self.next(self.state);
                },
                else => {},
            },
            else => {},
        }
        if (attempting_interrupt) {
            self.attempting_interrupt = true;
            return false;
        } else {
            if (self.attempting_interrupt) {
                self.attempting_interrupt = false;
            }
        }
    }
    if (new_state) |ns| {
        switch (self.state.field) {
            .date => |*date| if (date.*) |*d| d.deinit(),
            .amount => |*amount| if (amount.*) |*a| a.deinit(),
            .payee => |*payee| if (payee.*) |*p| p.deinit(),
            .category => |*category| if (category.*) |*c| c.deinit(),
            .memo => |*memo| if (memo.*) |*m| m.deinit(),
        }
        self.state = ns;
    }
    return false;
}

fn payeeEditor(self: *@This(), current: usize) PayeeEditor {
    return PayeeEditor.init(self.db, self.data.transactions[current], self.allocator);
}

fn setPayee(self: *@This(), edit_payee: PayeeEditor.EditPayee) !Database.PayeeId {
    const payee = &self.data.transactions[self.state.current].payee;
    switch (edit_payee) {
        .existing => |id| {
            payee.* = switch (id) {
                .payee => |payee_id| .{
                    .payee = &(self.data.payees.getEntry(payee_id) orelse unreachable).value,
                },
                .transfer => |transfer_id| .{
                    .transfer = &(self.data.accounts.getEntry(transfer_id) orelse unreachable).value,
                },
            };
            return id;
        },
        .new => |name| {
            var name_buffer = std.ArrayList(u8).init(self.allocator);
            var name_writer = name_buffer.writer();
            // defer name_buffer.deinit();
            for (name) |codepoint| {
                var buffer: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(codepoint, &buffer) catch return error.InvalidUtf8;
                try name_writer.writeAll(buffer[0..len]);
            }
            const id = try self.db.createPayee(name_buffer.items);
            var payee_to_insert: import.Payee = .{ .id = id, .name = name_buffer.toOwnedSlice() };
            try self.data.payees.put(id, payee_to_insert);

            payee.* = .{ .payee = &(self.data.payees.getEntry(id) orelse unreachable).value };
            return Database.PayeeId{ .payee = id };
        },
    }
}

/// Returns true if successesful
fn createMatch(
    self: *@This(),
    id: Database.PayeeId,
    match: Database.Match,
    pattern: []const u8,
) !bool {
    if (self.db.createPayeeMatch(id, match, pattern)) {
        return true;
    } else |err| {
        try self.err.set(
            "Error creating payee match: {}",
            .{self.db.getError()},
        );
        return false;
    }
}
