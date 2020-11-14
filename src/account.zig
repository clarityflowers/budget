const std = @import("std");
const sqlite = @import("sqlite-zig/src/sqlite.zig");
const import = @import("import.zig");
const DsvStringRule = import.DsvStringRule;
const ImportDsvRules = import.ImportDsvRules;
const log = @import("log.zig");
const DelimitedValueReader = @import("dsv.zig").DelimitedValueReader;
const parseEnum = @import("parse.zig").parseEnum;

pub const AccountType = enum {
    checking, savings, credit
};
pub const FileType = enum {
    csv, tsv
};

pub const ImportRule = struct {
    account_name: []const u8,
    file_type: FileType = .csv,
    date_column: []const u8,
    date_format: []const u8,
    income_column: []const u8,
    expenses_column: []const u8,
    payee_columns: ?[]const u8,
    memo_columns: ?[]const u8,
    id_columns: ?[]const u8,
};

pub fn configureImport(budget_file: [:0]const u8, rules: ImportRule) !void {
    const db = try sqlite.Database.openWithOptions(budget_file, .{ .mode = .readwrite });
    defer db.close() catch unreachable;

    errdefer log.alert("Could not configure import rules: {}", .{db.errmsg()});

    var result = try db.execBind(
        \\INSERT OR REPLACE INTO import_rules(
        \\  account_id, 
        \\  file_type, 
        \\  date_column, 
        \\  date_format, 
        \\  income_column,
        \\  expenses_column,
        \\  payee_columns,
        \\  memo_columns,
        \\  id_columns
        \\) 
        \\SELECT accounts.id, ?, ?, ?, ?, ?, ?, ?, ?
        \\FROM accounts WHERE accounts.name LIKE ?;
    , .{
        @tagName(rules.file_type),
        rules.date_column,
        rules.date_format,
        rules.income_column,
        rules.expenses_column,
        rules.payee_columns,
        rules.memo_columns,
        rules.id_columns,
        rules.account_name,
    });
    if (db.changes() < 1) {
        log.alert("Could not find an account with the name {}", .{rules.account_name});
        return;
    }
    log.info("Import rules for {} configured", .{rules.account_name});
}

fn getColumnIndex(columns: [][]const u8, name: []const u8) !u16 {
    for (columns) |column, index| {
        if (std.mem.eql(u8, column, name)) {
            return @intCast(u16, index);
        }
    }
    log.alert("Could not find a column named \"{}\".", .{name});
    return error.ColumnNotFound;
}

fn getColumnIndexes(
    headers: [][]const u8,
    columns: []const u8,
    allocator: *std.mem.Allocator,
) ![]u16 {
    var list = try std.ArrayList(u16).initCapacity(allocator, 2);
    errdefer list.deinit();
    var reader = DelimitedValueReader{ .line = columns };
    while (reader.nextValue()) |column| {
        try list.append(try getColumnIndex(headers, column));
    }
    return list.items;
}

/// Caller owns all allocated memory
fn parseStringRule(
    columns: [][]const u8,
    rule: []const u8,
    allocator: *std.mem.Allocator,
) !DsvStringRule {
    var mode: @TagType(DsvStringRule) = .Single;
    var start: usize = 0;
    if (std.mem.startsWith(u8, rule, "!pick:")) {
        mode = .Pick;
        start = "!pick:".len;
    } else if (std.mem.startsWith(u8, rule, "!combine:")) {
        mode = .Combine;
        start = "!combine:".len;
    } else if (rule.len == 0) {
        mode = .None;
    }
    return switch (mode) {
        .None => DsvStringRule{ .None = {} },
        .Single => DsvStringRule{ .Single = try getColumnIndex(columns, rule) },
        .Pick => DsvStringRule{ .Pick = try getColumnIndexes(columns, rule[start..], allocator) },
        .Combine => DsvStringRule{ .Combine = try getColumnIndexes(columns, rule[start..], allocator) },
    };
}

/// Allocated memory is owned by the caller
pub fn getImportRules(
    db: *const sqlite.Database,
    account_name: []const u8,
    header_row: []const u8,
    allocator: *std.mem.Allocator,
) !ImportDsvRules {
    var statement = (try db.prepare(
        \\SELECT
        \\  file_type,
        \\  date_column,
        \\  date_format,
        \\  income_column,
        \\  expenses_column,
        \\  payee_columns,
        \\  memo_columns,
        \\  id_columns
        \\FROM import_rules
        \\JOIN accounts on accounts.id = import_rules.account_id
        \\WHERE accounts.name LIKE ?;
    ));
    defer statement.finalize() catch {};
    try statement.bind(.{account_name});
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    if (!try statement.step()) return error.ImportRuleNotFound;
    const result = blk: {
        const delimiter = @as(u8, switch (try parseEnum(FileType, statement.columnText(0))) {
            .csv => ',',
            .tsv => '\t',
        });
        const columns = try (DelimitedValueReader{ .delimiter = delimiter, .line = header_row }).collect(&arena.allocator);
        const date_column = try getColumnIndex(columns, statement.columnText(1));
        const date_format = try allocator.dupe(u8, statement.columnText(2));
        const income = @intCast(u16, try getColumnIndex(columns, statement.columnText(3)));
        const expenses = @intCast(u16, try getColumnIndex(columns, statement.columnText(4)));
        const payee = try parseStringRule(columns, statement.columnText(5), &arena.allocator);
        const memo = try parseStringRule(columns, statement.columnText(6), &arena.allocator);
        const id = try parseStringRule(columns, statement.columnText(7), &arena.allocator);
        break :blk ImportDsvRules{
            .has_header = true,
            .delimiter = delimiter,
            .date = .{
                .column = date_column,
                .format = date_format,
            },
            .amount = .{
                .income = income,
                .expenses = expenses,
            },
            .payee = payee,
            .memo = memo,
            .id = id,
        };
    };
    if (try statement.step()) {
        log.alert("Bad data: more than one import rule for {}", .{account_name});
        return error.BadData;
    }
    return result;
}

pub fn create(
    budget_file: [:0]const u8,
    name: []const u8,
    account_type: AccountType,
    is_budget: bool,
) !void {
    const db = try sqlite.Database.openWithOptions(budget_file, .{ .mode = .readwrite });

    errdefer log.alert("Could not create account: {}", .{db.errmsg()});

    const result = try db.execBind(
        \\INSERT INTO accounts(name, is_budget, account_type) VALUES(?, ?, ?);
    , .{ name, @as(u2, if (is_budget) 1 else 0), @tagName(account_type) });
    log.info("Created account \"{}\"", .{name});
}

pub const Account = struct {
    id: i64,
    name: []const u8,
};
pub const Accounts = std.AutoHashMap(i64, Account);
pub fn getAccounts(db: *const sqlite.Database, allocator: *std.mem.Allocator) !Accounts {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const statement = try db.prepare(
        \\SELECT id, name FROM accounts;
    );
    defer statement.finalize() catch {};
    var accounts = Accounts.init(&arena.allocator);
    while (try statement.step()) {
        const id = statement.columnInt64(0);
        try accounts.put(id, .{
            .id = id,
            .name = try arena.allocator.dupe(u8, statement.columnText(1)),
        });
    }
    return accounts;
}
