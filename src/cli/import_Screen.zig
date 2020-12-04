const std = @import("std");
const PayeeEditor = @import("import_PayeeEditor.zig");
const CategoryEditor = @import("import_CategoryEditor.zig");
const sqlite = @import("../sqlite-zig/src/sqlite.zig");
const ncurses = @import("ncurses.zig");
const import = @import("../import.zig");
const log = @import("../log.zig");
const attr = @import("attributes.zig").attr;
const Database = @import("import_Database.zig");
const list = @import("import_list.zig");
const Err = @import("Err.zig");

db: Database,
allocator: *std.mem.Allocator,
data: *import.PreparedImport,
// payees: std.AutoHashMap(i64, import.Payee),
state: ScreenState = .{},
attempting_interrupt: bool = false,
initialized: bool = false,
err: Err,

const Field = union(list.FieldTag) {
    payee: PayeeEditor,
    category: CategoryEditor,
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
            .field = .{ .payee = undefined },
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
        .payee => transaction.payee == .unknown,
        .category => transaction.payee == .payee and transaction.category == null,
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
        .payee => result.field = .{ .payee = undefined },
        .category => {
            if (self.data.transactions[result.current].payee == .payee) {
                result.field = .{ .category = undefined };
            } else {
                result.field = .{ .payee = undefined };
            }
        },
    }
    return result;
}

pub fn moveDown(self: @This(), state: ScreenState) ScreenState {
    var result = state;
    result.current = (result.current + 1) % self.data.transactions.len;
    switch (result.field) {
        .payee => result.field = .{ .payee = undefined },
        .category => {
            if (self.data.transactions[result.current].payee == .payee) {
                result.field = .{ .category = undefined };
            } else {
                result.field = .{ .payee = undefined };
            }
        },
    }
    return result;
}

pub fn next(self: @This(), state: ScreenState) ScreenState {
    var result = state;
    switch (result.field) {
        .payee => {
            if (self.data.transactions[result.current].payee == .payee) {
                result.field = .{ .category = undefined };
            } else {
                result = self.moveDown(result);
            }
        },
        .category => {
            result = self.moveDown(result);
            result.field = .{ .payee = undefined };
        },
    }
    return result;
}
pub fn prev(self: @This(), state: ScreenState) ScreenState {
    var result = state;
    switch (result.field) {
        .payee => {
            result = self.moveUp(result);
            if (self.data.transactions[result.current].payee == .payee) {
                result.field = .{ .category = undefined };
            }
            // self.field = .amount;
        },
        .category => {
            result.field = .{ .payee = undefined };
        },
        // .memo => {
        //     self.field = .{ .category = undefined };
        // },
        // .date => {
        //     self.field = .memo;
        // },
        // .amount => {
        //     self.field = .date;
        // },
    }
    return result;
}

/// Returns true when done
pub fn render(
    self: *@This(),
    box: *ncurses.Box,
    input_key: ?ncurses.Key,
) !bool {
    return self.render_internal(box, input_key) catch |err| {
        switch (err) {
            error.OutOfMemory => self.err.set(
                "Your computer is running low on memory."[0..],
                .{},
            ) catch {},
            error.CreatePayeeFailed => self.err.set(
                "Failed creating payee: {}",
                .{self.db.getError()},
            ) catch {},
            error.CreatePayeeMatchFailed, error.CreateCategoryMatchFailed => self.err.set(
                "Failed creating match: {}",
                .{self.db.getError()},
            ) catch {},
            error.RenamePayeeFailed => self.err.set(
                "Failed renaming payee: {}",
                .{self.db.getError()},
            ) catch {},
            error.CreateCategoryGroupFailed => self.err.set(
                "Failed creating category group: {}",
                .{self.db.getError()},
            ) catch {},
            error.CreateCategoryFailed => self.err.set(
                "Failed creating category: {}",
                .{self.db.getError()},
            ) catch {},
            error.AutofillPayeesFailed,
            error.AutofillCategoriesFailed,
            => self.err.set(
                "Failed autofilling: {}",
                .{self.db.getError()},
            ) catch {},
            error.InvalidUtf8 => self.err.set(
                "Encountered utf8 string",
                .{},
            ) catch {},
            error.NCursesWriteFailed => self.err.set(
                "Failed to write to the terminal.",
                .{},
            ) catch {},
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
} || std.mem.Allocator.Error ||
    PayeeEditor.Error ||
    CategoryEditor.Error;

fn render_internal(
    self: *@This(),
    box: *ncurses.Box,
    input_key: ?ncurses.Key,
) Error!bool {
    if (self.initialized == false) {
        if (self.data.transactions[0].payee != .unknown) {
            self.state = self.getNextMissing() orelse self.state;
        }
        self.initState();
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

    var lower_box = box.box(.{ .line = divider_line + 1, .height = 3 });
    if (try self.err.render(&lower_box)) {
        if (input != null) {
            input = null;
            self.err.reset();
        }
    } else if (self.attempting_interrupt) {
        lower_box.move(.{});
        lower_box.writer().print("Press ^C again to quit.", .{}) catch {};
    } else {
        switch (self.state.field) {
            .payee => |*payee_editor| {
                const result = try payee_editor.render(input, &lower_box, &self.db);
                if (result) |res| switch (res) {
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
                    .input_consumed => input = null,
                };
            },
            .category => |*category| {
                if (try category.render(&lower_box, input)) |result| switch (result) {
                    .input => input = null,
                    .submit => |submission| {
                        const transaction = &self.data.transactions[self.state.current];
                        defer submission.selection.deinit(self.allocator);
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
                                        const id = try self.db.createCategoryGroup(name);
                                        const res = try self.data.category_groups.getOrPut(id);
                                        std.debug.assert(!res.found_existing);
                                        res.entry.value = .{ .id = id, .name = try self.allocator.dupe(u8, name) };
                                        break :blk &res.entry.value;
                                    },
                                };
                                const id = try self.db.createCategory(group.id, new.name);
                                const res = try self.data.categories.getOrPut(id);
                                std.debug.assert(!res.found_existing);
                                res.entry.value = .{
                                    .id = id,
                                    .group = group,
                                    .name = try self.allocator.dupe(u8, new.name),
                                };
                                transaction.category = .{
                                    .budget = &res.entry.value,
                                };
                                break :new_blk Database.CategoryId{ .budget = id };
                            },
                        };
                        if (submission.pattern) |pattern| {
                            try self.db.createCategoryMatch(
                                transaction.payee.payee.id,
                                id,
                                if (pattern.use_amount) transaction.amount else null,
                                pattern.match_note,
                            );
                            try import.autofillCategories(
                                self.db.handle,
                                self.data.transactions,
                                &self.data.categories,
                            );
                        }
                        input = after_submit;
                    },
                };
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
                '\r' => {
                    new_state = self.getNextMissing();
                },
                '\t' => {
                    new_state = self.next(self.state);
                },
                else => {},
            },
        }
        if (attempting_interrupt) {
            self.attempting_interrupt = true;
        } else {
            if (self.attempting_interrupt) {
                self.attempting_interrupt = false;
            }
        }
    }
    if (new_state) |ns| {
        switch (self.state.field) {
            .payee => |*payee| {
                payee.deinit();
            },
            .category => |*category| {
                category.deinit();
            },
        }
        self.state = ns;
        self.initState();
    }
    return false;
}

fn payeeEditor(self: *@This(), current: usize) PayeeEditor {
    return PayeeEditor.init(self.db, self.data.transactions[current], self.allocator);
}

fn initState(self: *@This()) void {
    const transaction = &self.data.transactions[self.state.current];
    switch (self.state.field) {
        .payee => |*payee| {
            payee.* = PayeeEditor.init(
                transaction.payee,
                self.allocator,
            );
        },
        .category => |*category| {
            category.* = CategoryEditor.init(
                self.allocator,
                &self.db,
                &transaction.category,
                transaction.memo,
            );
        },
    }
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
