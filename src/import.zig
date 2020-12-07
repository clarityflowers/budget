const std = @import("std");
const ArenaAllocator = std.heap.ArenaAllocator;
const ArrayList = std.ArrayList;
const SegmentedList = std.SegmentedList;
const BufSet = std.BufSet;
const StringHashMap = std.StringHashMap;
const fixedBufferStream = std.io.fixedBufferStream;
const sort = std.sort.sort;

const mem = std.mem;
const Allocator = mem.Allocator;

const math = std.math;

const dates = @import("zig-date/src/main.zig");
const Date = dates.Date;

const dsv = @import("dsv.zig");
const DelimitedValueReader = dsv.DelimitedValueReader;
const DelimitedRecordReader = dsv.DelimitedRecordReader;
const LineReader = dsv.LineReader;

const parse = @import("parse.zig");

const StringLibrary = @import("string_library.zig").StringLibrary;

const testing = std.testing;
const expectEqualSlices = testing.expectEqualSlices;
const expectEqual = testing.expectEqual;
const account_actions = @import("account.zig");

comptime {
    if (std.builtin.is_test) {
        _ = @import("dates.zig");
    }
}

// workflows
// [ ] import account transactions
//   [-] backup transactions
//   [x] load existing data
//   [x] reshape external csv/tsv files
//   [x] load external data
//   [x] match with existing data to throw out records
//   [ ] reconcile each record
//     [x] auto-match payees
//     [ ] auto-match categories
//     [ ] split transaction
//   [ ] save new transactions as unreconciled
//
// [ ] reconcile
//   [ ] backup budget
//   [ ] check final balance up to given date
//     [ ] manually match each transaction if necessary
//   [ ] transfer category totals into new budget line (income goes into unbudgeted column)
//   [ ] mark transactions as reconciled
//
// [ ] budget
//   [ ] backup budget file
//   [ ] load budget file
//   [ ] move values between categories
//   [ ] save

const Transaction = struct {
    amount: i32,
    date: Date,
    payee: []const u8,
    category: []const u8,
    note: []const u8,
    bank_note: []const u8,
    reconciled: bool,

    pub fn earlierThan(lh: *@This(), rh: *@This()) bool {
        return lh.date.isBefore(rh.date);
    }
};
const Account = account_actions.Account;

pub const Category = union(enum) {
    budget: *const BudgetCategory,
    income,

    pub fn format(
        self: @This(),
        fmt_str: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        switch (self) {
            .budget => |budget| {
                try writer.print("{}: {}", .{ budget.group.name, budget.name });
                if (options.width) |width| {
                    const written = budget.group.name.len + budget.name.len + 2;
                    if (written < width) {
                        try writer.writeByteNTimes(options.fill, width - written);
                    }
                }
            },
            .income => {
                const written = try writer.write("Income");
                if (options.width) |width| {
                    if (written < width) {
                        try writer.writeByteNTimes(options.fill, width - written);
                    }
                }
            },
        }
    }
};

pub const ImportedTransaction = struct {
    date: Date,
    amount: i32,
    payee: ImportPayee,
    memo: []const u8,
    id: u32,
    category: ?Category = null,

    pub fn earlierThan(lh: @This(), rh: @This()) bool {
        return lh.date.isBefore(rh.date);
    }

    pub fn sortFn(context: void, lh: @This(), rh: @This()) bool {
        return lh.earlierThan(rh);
    }
};

const BudgetLine = struct {
    date: Date, amounts_by_category: StringHashMap(i32)
};

pub const DsvStringRule = union(enum) {
    Single: u16,
    Pick: []const u16,
    Combine: []const u16,
    None,

    pub fn take(self: @This(), values: []const []const u8, allocator: *Allocator) !?[]const u8 {
        return switch (self) {
            .Single => |column| try allocator.dupe(u8, values[column]),
            .Combine => |columns| blk: {
                const result = &ArrayList(u8).init(allocator);
                for (columns) |column, i| {
                    if (result.items.len > 0 and result.items[result.items.len - 1] != ' ') {
                        try result.append(' ');
                    }
                    try result.appendSlice(values[column]);
                }
                break :blk result.items;
            },
            .Pick => |columns| blk: {
                for (columns) |column| {
                    if (values[column].len > 0) break :blk try allocator.dupe(u8, values[column]);
                }
                break :blk null;
            },
            .None => null,
        };
    }
};
pub const DsvCurrencyRule = struct {
    income: u16,
    expenses: u16,
    pub fn take(self: @This(), values: []const []const u8) !i32 {
        if (self.income == self.expenses) {
            return try parse.parseCents(i32, values[self.income]);
        } else {
            const income = try math.absInt(try parse.parseCents(i32, values[self.income]));
            const expenses = try math.absInt(try parse.parseCents(i32, values[self.expenses]));
            return income - expenses;
        }
    }
};
pub const DsvDateRule = struct {
    column: u16,
    format: []const u8,
    pub fn take(self: @This(), values: []const []const u8) !Date {
        return try Date.parseStringFmt(self.format, values[self.column]);
    }
};
pub const ImportDsvRules = struct {
    has_header: bool,
    delimiter: u8,
    date: DsvDateRule,
    amount: DsvCurrencyRule,
    payee: DsvStringRule,
    memo: DsvStringRule,
    id: DsvStringRule,
};

const sqlite = @import("sqlite-zig/src/sqlite.zig");
const account = @import("account.zig");
const log = @import("log.zig");

const ExistingTransaction = struct {
    date: Date,
    id: u64,

    pub const HashSet = std.AutoHashMap(@This(), void);
};
const ImportedPayee = struct {
    id: ?i64 = null,
    name: []const u8,
};

pub fn convert(db: *const sqlite.Database, account_name: []const u8, import_reader: anytype, allocator: *std.mem.Allocator) ![]ImportedTransaction {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    var temporary_arena = std.heap.ArenaAllocator.init(allocator);
    defer temporary_arena.deinit();

    var line_reader = LineReader(@TypeOf(import_reader), 1024 * 1024).init(import_reader, &arena.allocator);
    const header = (try line_reader.nextLine()) orelse return error.NoHeader;
    const rules = try account.getImportRules(db, account_name, header, &temporary_arena.allocator);
    var transactions_list = ArrayList(ImportedTransaction).init(&arena.allocator);
    var transactions = blk: {
        var values_list = ArrayList([]const u8).init(&temporary_arena.allocator);
        while (try line_reader.nextLine()) |line| {
            if (line.len == 0) break;
            values_list.shrinkRetainingCapacity(0);
            const values = try (DelimitedValueReader{ .delimiter = rules.delimiter, .line = line }).collectIntoArrayList(&values_list);
            try transactions_list.append(.{
                .date = try rules.date.take(values),
                .amount = try rules.amount.take(values),
                .payee = .{ .unknown = (try rules.payee.take(values, &arena.allocator)) orelse "" },
                .memo = (try rules.memo.take(values, &arena.allocator)) orelse "",
                .id = id_blk: {
                    const id_from_budget = try rules.id.take(values, &arena.allocator);
                    const id_to_hash = if (id_from_budget != null and id_from_budget.?.len > 0)
                        id_from_budget.?
                    else
                        line;
                    break :id_blk @truncate(u32, std.hash_map.hashString(line));
                },
            });
        }
        break :blk transactions_list.items;
    };
    sort(ImportedTransaction, transactions, {}, ImportedTransaction.sortFn);
    if (transactions.len == 0) {
        log.notice("No transactions to import.", .{});
    }
    const existing_transactions = blk: {
        var hash_set = ExistingTransaction.HashSet.init(&temporary_arena.allocator);
        const statement = (try db.prepare(
            \\SELECT date, bank_id FROM transactions
            \\JOIN accounts ON accounts.id = transactions.account_id
            \\WHERE 
            \\  accounts.name LIKE ? AND
            \\  transactions.date >= ?
            \\ORDER BY transactions.date
        ));
        defer statement.finalize() catch {};
        var date_buffer: [10]u8 = undefined;
        try std.io.fixedBufferStream(date_buffer[0..]).writer().print("{}", .{transactions[0].date});
        try statement.bind(.{ account_name, date_buffer[0..] });
        while (try statement.step()) {
            const existing_transaction: ExistingTransaction = .{
                .date = try Date.parse(statement.columnText(0)),
                .id = @intCast(u32, statement.columnInt64(1)),
            };
            try hash_set.put(existing_transaction, {});
        }
        break :blk hash_set;
    };

    var count: usize = 0;
    for (transactions) |transaction, i| {
        if (existing_transactions.contains(.{
            .date = transaction.date,
            .id = transaction.id,
        })) {
            continue;
        } else {
            if (i != count) {
                transactions[count] = transactions[i];
            }
            count += 1;
        }
    }
    if (count != transactions.len) {
        log.info("Matched {} already-imported transactions", .{transactions.len - count});
        transactions.len = count;
    }

    return transactions;
}

pub fn getPayees(db: *const sqlite.Database, allocator: *std.mem.Allocator) !Payees {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const statement = try db.prepare(
        \\SELECT id, name FROM payees;
    );
    defer statement.finalize() catch {};
    var map = Payees.init(&arena.allocator);
    while (try statement.step()) {
        const id = statement.columnInt64(0);
        try map.put(id, .{
            .name = try arena.allocator.dupe(u8, statement.columnText(1)),
            .id = statement.columnInt64(0),
        });
    }
    // TODO - idk if this is actually guaranteed safe?
    map.allocator = arena.child_allocator;
    return map;
}

pub const ImportPayee = union(enum) {
    payee: *Payee,
    transfer: *const Account,
    unknown: []const u8,

    pub fn format(
        self: @This(),
        fmt_str: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        const written = switch (self) {
            .payee => |payee| try writer.write(payee.name),
            .transfer => |payee| (try writer.write("Transfer to ")) +
                try writer.write(payee.name),
            .unknown => |str| try writer.write(str),
        };

        if (options.width) |width| {
            if (written < width) {
                try writer.writeByteNTimes(options.fill, width - written);
            }
        }
    }
};
pub const Payee = struct {
    id: i64,
    name: []const u8,
};

pub const Payees = std.AutoHashMap(i64, Payee);
pub const Accounts = std.AutoHashMap(i64, Account);

pub fn autofillPayees(
    db: *const sqlite.Database,
    account_name: []const u8,
    transactions: []ImportedTransaction,
    payees: *const Payees,
    accounts: *const Accounts,
) !void {
    const statement = db.prepare(@embedFile("payee_autofill.sql")) catch return error.AutofillPayeesFailed;

    defer statement.finalize() catch {};
    for (transactions) |*transaction| {
        switch (transaction.payee) {
            .unknown => |payee_name| {
                statement.reset() catch return error.AutofillPayeesFailed;
                statement.bind(.{ payee_name, account_name }) catch return error.AutofillPayeesFailed;

                if (statement.step() catch return error.AutofillPayeesFailed) {
                    if (statement.columnType(0) == .Null) {
                        transaction.payee = .{
                            .transfer = &(accounts.getEntry(statement.columnInt64(1)) orelse continue).value,
                        };
                    } else {
                        transaction.payee = .{
                            .payee = &(payees.getEntry(statement.columnInt64(0)) orelse continue).value,
                        };
                    }
                }
            },
            else => continue,
        }
    }
}

pub const CategoryGroup = struct {
    id: i64,
    name: []const u8,
};
pub fn getCategoryGroups(db: *const sqlite.Database, allocator: *std.mem.Allocator) !CategoryGroups {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const statement = try db.prepare(
        \\SELECT id, name FROM category_groups;
    );
    defer statement.finalize() catch {};
    var groups = CategoryGroups.init(&arena.allocator);
    while (try statement.step()) {
        const id = statement.columnInt64(0);
        try groups.put(id, .{
            .id = id,
            .name = try arena.allocator.dupe(u8, statement.columnText(1)),
        });
    }
    return groups;
}

pub const BudgetCategory = struct {
    id: i64, group: *const CategoryGroup, name: []const u8
};
pub const Categories = std.AutoHashMap(i64, BudgetCategory);
pub const CategoryGroups = std.AutoHashMap(i64, CategoryGroup);

pub fn getCategories(
    db: *const sqlite.Database,
    groups: *const CategoryGroups,
    allocator: *std.mem.Allocator,
) !Categories {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const statement = db.prepare(
        \\SELECT id, category_group_id, name FROM categories;
    ) catch {
        log.alert("SQL error when creating categories: {}", .{db.errmsg()});
        return error.BadSQL;
    };
    defer statement.finalize() catch {};
    var categories = Categories.init(&arena.allocator);
    while (try statement.step()) {
        const group_id = statement.columnInt64(1);
        const id = statement.columnInt64(0);
        const groupEntry = groups.getEntry(group_id) orelse {
            log.alert("Category {} ({}) has invalid group id {}", .{ statement.columnText(2), id, group_id });
            return error.BadData;
        };
        try categories.put(id, .{
            .id = id,
            .group = &groupEntry.value,
            .name = try arena.allocator.dupe(u8, statement.columnText(2)),
        });
    }
    // TODO - idk if this is actually guaranteed safe?
    categories.allocator = arena.child_allocator;
    return categories;
}

pub const AutofillCategoryQuery = struct {
    statement: sqlite.Statement,

    const Error = error{AutofillCategoriesFailed};
    const Result = struct {
        category: Category,
        autofill_id: i64,
    };

    pub fn init(db: *const sqlite.Database) !@This() {
        return @This(){
            .statement = db.prepare(@embedFile("category_autofill.sql")) catch
                return Error.AutofillCategoriesFailed,
        };
    }

    pub fn deinit(self: @This()) void {
        self.statement.finalize() catch {};
    }

    pub fn get(
        self: @This(),
        payee_id: i64,
        memo: []const u8,
        amount: i32,
        categories: *const Categories,
    ) !?Result {
        self.statement.reset() catch {};
        self.statement.bind(.{
            memo,
            payee_id,
            amount,
        }) catch return Error.AutofillCategoriesFailed;
        const id = self.statement.columnInt64(2);
        if (self.statement.step() catch return Error.AutofillCategoriesFailed) {
            if (self.statement.columnType(0) == .Null) {
                return Result{
                    .category = .{ .income = {} },
                    .autofill_id = id,
                };
            } else {
                return Result{
                    .category = .{
                        .budget = &(categories.getEntry(self.statement.columnInt64(0)) orelse unreachable).value,
                    },
                    .autofill_id = id,
                };
            }
        }
        return null;
    }
};

pub fn autofillCategories(
    db: *const sqlite.Database,
    transactions: []ImportedTransaction,
    categories: *const Categories,
) !void {
    var query = try AutofillCategoryQuery.init(db);
    defer query.deinit();
    for (transactions) |*transaction| {
        if (transaction.category == null) {
            switch (transaction.payee) {
                .payee => |payee| {
                    if (try query.get(
                        payee.id,
                        transaction.memo,
                        transaction.amount,
                        categories,
                    )) |result| {
                        transaction.category = result.category;
                    }
                },
                else => {},
            }
        }
    }
}

pub const PreparedImport = struct {
    accounts: Accounts,
    payees: Payees,
    category_groups: CategoryGroups,
    categories: Categories,
    transactions: []ImportedTransaction,
};
pub fn prepareImport(
    db: *const sqlite.Database,
    account_name: []const u8,
    reader: anytype,
    allocator: *std.mem.Allocator,
) !PreparedImport {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const imported_transactions = try convert(
        db,
        account_name,
        reader,
        &arena.allocator,
    );
    log.info("Importing {} transactions", .{imported_transactions.len});

    var accounts = try account_actions.getAccounts(db, &arena.allocator);
    accounts.allocator = allocator;
    var payees = try getPayees(db, &arena.allocator);
    payees.allocator = allocator;
    try autofillPayees(db, account_name, imported_transactions, &payees, &accounts);

    var category_groups = try getCategoryGroups(db, &arena.allocator);

    category_groups.allocator = allocator;
    var categories = try getCategories(db, &category_groups, &arena.allocator);
    categories.allocator = allocator;

    try autofillCategories(db, imported_transactions, &categories);
    return PreparedImport{
        .accounts = accounts,
        .payees = payees,
        .category_groups = category_groups,
        .categories = categories,
        .transactions = imported_transactions,
    };
}

const example_csv =
    \\"Transaction ID","Posting Date","Effective Date","Transaction Type","Amount","Check Number","Reference Number","Description","Transaction Category","Type","Balance","Memo","Extended Description"
    \\"20200508 78118 50,000 29,067","5/8/2020","5/8/2020","Debit","-500.00000","","16773445","To Share 15","","","17164.25000","","To Share 15"
    \\"20200505 78118 5,565 35,120","5/5/2020","5/5/2020","Debit","-55.65000","","16773444","Portland General CO: Portland General","","","17664.25000","","Portland General CO: Portland General"
    \\"20200501 78118 306,698 61,629","5/1/2020","5/1/2020","Credit","3066.98000","","16584030","GUSTO CO: GUSTO","","","17719.90000","","GUSTO CO: GUSTO"
;

const ncurses = @import("ncurses.zig");

const second = millisecond * 1000;
const millisecond = microsecond * 1000;
const microsecond = 1000;

const VarStr = std.ArrayList(u8);
