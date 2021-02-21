const std = @import("std");
const sqlite = @import("sqlite-zig/src/sqlite.zig");
const log = @import("log.zig");
const dsv = @import("dsv.zig");
const accounts_model = @import("account.zig");
const zig_date = @import("zig-date/src/main.zig");
const parse = @import("parse.zig");
const Currency = @import("Currency.zig");

const KILOBYTE = 1024;
const MEGABYTE = KILOBYTE * 1024;

const budget_balances_query = @embedFile("budget_balances.sql");

pub fn import(
    db: *const sqlite.Database,
    allocator: *std.mem.Allocator,
    ynab_dir_path: []const u8,
) !void {
    @setEvalBranchQuota(10000);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ynab_dir = try std.fs.cwd().openDir(ynab_dir_path, .{});
    defer ynab_dir.close();
    var text = std.ArrayList(u8).init(&arena.allocator);
    defer text.deinit();

    try db.exec("BEGIN TRANSACTION;");
    errdefer db.exec("ROLLBACK TRANSACTION;") catch {};

    const parse_options: std.json.ParseOptions = .{
        .allocator = &arena.allocator,
    };
    var data_dir = blk: {
        var ymeta_file = try ynab_dir.openFile("Budget.ymeta", .{});
        defer ymeta_file.close();
        const YMeta = struct {
            relativeDataFolderName: []const u8,
            formatVersion: []const u8,
            TED: i64,
        };
        try ymeta_file.reader().readAllArrayList(&text, MEGABYTE);
        defer text.shrinkRetainingCapacity(0);
        var token_stream = std.json.TokenStream.init(text.items);
        const meta_info = try std.json.parse(YMeta, &token_stream, parse_options);
        defer std.json.parseFree(YMeta, meta_info, parse_options);
        break :blk try ynab_dir.openDir(meta_info.relativeDataFolderName, .{});
    };
    defer data_dir.close();
    var device_dir = blk: {
        var devices_dir = try data_dir.openDir("devices", .{ .iterate = true });
        defer devices_dir.close();
        var devices_dir_it = devices_dir.iterate();
        while (try devices_dir_it.next()) |entry| switch (entry.kind) {
            .File => {
                var device_info_file = try devices_dir.openFile(entry.name, .{});
                try device_info_file.reader().readAllArrayList(&text, MEGABYTE);
                var token_stream = std.json.TokenStream.init(text.items);
                defer text.shrinkRetainingCapacity(0);
                const DeviceInfo = struct {
                    shortDeviceId: []const u8,
                    formatVersion: []const u8,
                    YNABVersion: []const u8,
                    lastDataVersionFullyKnown: []const u8,
                    deviceType: []const u8,
                    knowledge: []const u8,
                    highestDataVersionImported: ?[]const u8,
                    friendlyName: []const u8,
                    knowledgeInFullBudgetFile: []const u8,
                    hasFullKnowledge: bool,
                    deviceGUID: []const u8,
                };
                const device_info = try std.json.parse(
                    DeviceInfo,
                    &token_stream,
                    parse_options,
                );
                defer std.json.parseFree(DeviceInfo, device_info, parse_options);
                if (!device_info.hasFullKnowledge) continue;
                break :blk try data_dir.openDir(device_info.deviceGUID, .{});
            },
            else => {},
        } else {
            log.alert("Couldn't find any devices with full knowledge.", .{});
            return error.YNAB_ImportFailed;
        }
    };
    defer device_dir.close();
    var yfull_file = try device_dir.openFile("Budget.yfull", .{});
    defer yfull_file.close();
    try yfull_file.reader().readAllArrayList(&text, 100 * MEGABYTE);

    // ---- PARSING AND CREATING BUDGET DATA ----

    var token_stream = std.json.TokenStream.init(text.items);
    var parser = std.json.Parser.init(&arena.allocator, false);
    defer parser.deinit();
    var budget = try parser.parse(text.items);
    defer budget.deinit();
    const budget_obj = budget.root.Object;

    // ---- CREATE ACCOUNTS ----
    const Account = union(enum) {
        on_budget: i64,
        off_budget: struct {
            id: i64,
            payee_id: i64,
        },
    };
    var ynab_accounts = std.StringHashMap(Account).init(&arena.allocator);
    defer ynab_accounts.deinit();

    var ynab_payees = std.StringHashMap(i64).init(&arena.allocator);
    defer ynab_payees.deinit();
    {
        const create_account = try db.prepare("INSERT INTO accounts(name, account_type) VALUES(?, ?);");
        defer create_account.finalize() catch {};
        const create_payee = try db.prepare("INSERT INTO payees(name) VALUES(?);");
        defer create_payee.finalize() catch {};
        const create_off_budget_account = try db.prepare(
            \\INSERT INTO off_budget_accounts(payee_id) VALUES(?)
        );
        defer create_off_budget_account.finalize() catch {};
        var account_count: usize = 0;
        for (budget_obj.get("accounts").?.Array.items) |*account| {
            if (account.Object.get("isTombstone") != null) continue;
            account_count += 1;
            defer create_account.reset() catch {};
            const account_name = account.Object.get("accountName").?.String;
            const account_type = blk: {
                const account_type = account.Object.get("accountType").?.String;
                if (std.mem.eql(u8, account_type, "Checking")) {
                    break :blk accounts_model.AccountType.checking;
                } else if (std.mem.eql(u8, account_type, "Savings")) {
                    break :blk accounts_model.AccountType.savings;
                } else if (std.mem.eql(u8, account_type, "Cash")) {
                    break :blk accounts_model.AccountType.cash;
                } else if (std.mem.eql(u8, account_type, "CreditCard")) {
                    break :blk accounts_model.AccountType.credit;
                } else if (std.mem.eql(u8, account_type, "InvestmentAccount")) {
                    break :blk accounts_model.AccountType.investment;
                } else {
                    break :blk accounts_model.AccountType.other;
                }
            };
            if (account.Object.get("onBudget").?.Bool) {
                try create_account.bind(.{
                    account_name,
                    @tagName(account_type),
                });
                create_account.finish() catch |err| switch (err) {
                    error.Constraint => {
                        log.alert("An account already exists with the name {s}", .{account_name});
                        return error.Conflict;
                    },
                    else => |other_err| return other_err,
                };
                try ynab_accounts.put(account.Object.get("entityId").?.String, .{
                    .on_budget = db.lastInsertRowId(),
                });
            } else {
                try create_payee.reset();
                try create_payee.bind(.{account_name});
                try create_payee.finish();
                try create_off_budget_account.reset();
                const off_budget_payee = db.lastInsertRowId();
                try create_off_budget_account.bind(.{
                    off_budget_payee,
                });
                try create_off_budget_account.finish();
                try ynab_accounts.put(account.Object.get("entityId").?.String, .{
                    .off_budget = .{
                        .id = db.lastInsertRowId(),
                        .payee_id = off_budget_payee,
                    },
                });
            }
        }
        log.debug("Created {} accounts", .{account_count});
    }

    // ---- categories --

    var ynab_categories = std.StringHashMap(i64).init(&arena.allocator);
    defer ynab_categories.deinit();
    const off_budget_id = blk: {
        try db.exec(
            \\INSERT OR REPLACE INTO categories(name) VALUES('Off-Budget');
        );
        break :blk db.lastInsertRowId();
    };
    {
        const create_group = try db.prepare(
            \\INSERT OR REPLACE INTO category_groups(name) VALUES(?)
        );
        const create_category = try db.prepare(
            \\INSERT OR REPLACE INTO categories(name, category_group_id) VALUES(?, ?)
        );
        defer create_group.finalize() catch {};
        defer create_category.finalize() catch {};
        var group_count: usize = 0;
        var category_count: usize = 0;
        for (budget_obj.get("masterCategories").?.Array.items) |group| {
            if (group.Object.get("isTombstone") != null) continue;
            switch (group.Object.get("subCategories").?) {
                .Array => |arr| {
                    if (arr.items.len == 0) continue;
                    group_count += 1;
                    const group_id = blk: {
                        if (std.mem.eql(u8, group.Object.get("entityId").?.String, "MasterCategory/__Hidden__")) {
                            break :blk @as(?i64, null);
                        } else {
                            try create_group.reset();
                            const name = group.Object.get("name").?.String;
                            try create_group.bind(.{name});
                            try create_group.finish();
                            break :blk db.lastInsertRowId();
                        }
                    };
                    for (arr.items) |category| {
                        if (category.Object.get("isTombstone") != null) continue;

                        try create_category.reset();
                        category_count += 1;
                        const name = category.Object.get("name").?.String;
                        const actual_name = if (std.mem.indexOf(u8, name, " ` ")) |index| blk: {
                            const end_index = if (std.mem.indexOfPos(u8, name, index + 3, " ` ")) |end|
                                end
                            else
                                name.len;
                            break :blk name[index + 3 .. end_index];
                        } else name;
                        try create_category.bind(.{ actual_name, group_id });
                        try create_category.finish();
                        const id = db.lastInsertRowId();
                        try ynab_categories.put(category.Object.get("entityId").?.String, id);
                    }
                },
                else => {},
            }
        }
        log.info("Created {} categories in {} groups", .{ category_count, group_count });
    }

    // ---- create payees ----

    const nobody_id = blk: {
        try db.exec(
            \\INSERT OR REPLACE INTO payees(name) VALUES('Nobody');
        );
        break :blk db.lastInsertRowId();
    };
    {
        const create_payee = try db.prepare(
            \\INSERT OR REPLACE INTO payees(name) VALUES(?)
        );
        defer create_payee.finalize() catch {};
        const create_payee_match = try db.prepare(
            \\INSERT OR REPLACE INTO payee_matches(payee_id, transfer_id, match) VALUES(?, ?, ?)
        );
        defer create_payee_match.finalize() catch {};
        const create_category_match = try db.prepare(
            \\INSERT OR REPLACE INTO category_matches(payee_id, category_id) VALUES(?, ?)
        );
        defer create_category_match.finalize() catch {};
        var payee_count: usize = 0;
        var payee_match_count: usize = 0;
        var category_match_count: usize = 0;

        for (budget_obj.get("payees").?.Array.items) |payee| {
            if (payee.Object.get("isTombstone") != null) continue;
            const id = if (payee.Object.get("targetAccountId")) |account_id| blk: {
                const account = ynab_accounts.get(account_id.String) orelse {
                    log.alert("Encountered invalid account id {s}", .{account_id.String});
                    return error.Invalid;
                };
                break :blk switch (account) {
                    .on_budget => |id| PayeeId{ .transfer = id },
                    .off_budget => |off| PayeeId{ .payee = off.payee_id },
                };
            } else blk: {
                try create_payee.reset();
                try create_payee.bind(.{payee.Object.get("name").?.String});
                try create_payee.finish();
                const id = db.lastInsertRowId();
                try ynab_payees.put(payee.Object.get("entityId").?.String, id);
                break :blk PayeeId{ .payee = id };
            };
            payee_count += 1;
            if (id == .payee) {
                switch (payee.Object.get("autoFillCategoryId").?) {
                    .String => |category_id| {
                        try create_category_match.reset();
                        if (std.mem.eql(u8, category_id, "Category/__DeferredIncome__") or
                            std.mem.eql(u8, category_id, "Category/__ImmediateIncome__"))
                        {
                            try create_category_match.bind(.{ id.payee, null });
                        } else {
                            try create_category_match.bind(.{
                                id.payee,
                                ynab_categories.get(category_id) orelse {
                                    log.alert("Unknown YNB category id {}", .{category_id});
                                    return error.UnknownCategoryId;
                                },
                            });
                        }
                        try create_category_match.finish();
                        category_match_count += 1;
                    },
                    else => {},
                }
            }
            switch (payee.Object.get("renameConditions").?) {
                .Array => |arr| for (arr.items) |cond| {
                    try create_payee_match.reset();
                    const match = cond.Object.get("operand").?.String;
                    payee_match_count += 1;
                    switch (id) {
                        .payee => |payee_id| {
                            try create_payee_match.bind(.{ payee_id, null, match });
                        },
                        .transfer => |transfer_id| {
                            try create_payee_match.bind(.{ null, transfer_id, match });
                        },
                    }
                    try create_payee_match.finish();
                },
                else => {},
            }
        }
        log.info("Created {} payees, {} payee autofills, and {} category autofills", .{
            payee_count,
            payee_match_count,
            category_match_count,
        });
    }
    var seen_transfer_ids = std.StringHashMap(void).init(&arena.allocator);
    defer seen_transfer_ids.deinit();
    {
        const create_transaction = try db.prepare(
            \\INSERT INTO transactions(
            \\  account_id,
            \\  date,
            \\  amount,
            \\  payee_id,
            \\  category_id,
            \\  note,
            \\  bank_id
            \\) VALUES (?, ?, ?, ?, ?, ?, ?)
        );
        defer create_transaction.finalize() catch {};
        const create_transfer = try db.prepare(
            \\INSERT INTO transfers(
            \\  from_account_id,
            \\  to_account_id,
            \\  date,
            \\  amount,
            \\  note,
            \\  bank_id
            \\) VALUES (?, ?, ?, ?, ?, ?)
        );
        defer create_transfer.finalize() catch {};
        const create_off_budget_transaction = try db.prepare(
            \\INSERT INTO off_budget_transactions(
            \\  account_id,
            \\  date,
            \\  amount,
            \\  payee_id,
            \\  note,
            \\  bank_id
            \\) VALUES (?, ?, ?, ?, ?, ?)
        );
        defer create_off_budget_transaction.finalize() catch {};
        var transaction_count: usize = 0;
        var transfer_count: usize = 0;
        var found_uncleared = false;
        for (budget_obj.get("transactions").?.Array.items) |transaction| {
            if (!transaction.Object.get("accepted").?.Bool) {
                found_uncleared = true;
                continue;
            }
            if (std.mem.eql(u8, transaction.Object.get("cleared").?.String, "Uncleared")) {
                found_uncleared = true;
                continue;
            }
            if (transaction.Object.get("isTombstone") != null) continue;
            try create_transaction.reset();
            const date = transaction.Object.get("date").?.String;
            const account = ynab_accounts.get(transaction.Object.get("accountId").?.String) orelse {
                log.alert("Encountered invalid account {s}", .{transaction.Object.get("accountId").?.String});
                return error.Invalid;
            };
            const amount = try getAmount(transaction.Object.get("amount").?);
            const note = if (transaction.Object.get("Memo")) |memo|
                memo.String
            else
                "";

            const ynab_category_id = transaction.Object.get("categoryId").?;
            const bank_id = @truncate(
                u32,
                std.hash_map.hashString(if (transaction.Object.get("FITID")) |fitid|
                    fitid.String
                else
                    transaction.Object.get("entityId").?.String),
            );

            const payee_id = if (transaction.Object.get("targetAccountId")) |transfer_id| blk: {
                const to_account = ynab_accounts.get(transfer_id.String) orelse {
                    log.alert("Invalid account {s}", .{transfer_id.String});
                    return error.Invalid;
                };
                if (to_account == .off_budget) {
                    break :blk to_account.off_budget.payee_id;
                }
                // Transfers to off-budget accounts will be handled when we see them from
                // the on-budget account's perspective.
                if (account == .off_budget) continue;

                try create_transfer.reset();
                if (seen_transfer_ids.contains(transaction.Object.get("transferTransactionId").?.String)) continue;
                try seen_transfer_ids.put(transaction.Object.get("entityId").?.String, {});
                try create_transfer.bind(.{
                    account.on_budget,
                    to_account.on_budget,
                    date,
                    amount,
                    note,
                });
                try create_transfer.finish();
                transfer_count += 1;
                continue;
            } else if (transaction.Object.get("payee")) |payee|
                ynab_payees.get(payee.String) orelse {
                    log.alert("Invalid payee {s}", .{payee.String});
                    return error.Invalid;
                }
            else
                nobody_id;

            const maybe_subtransactions = transaction.Object.get("subTransactions");
            if (maybe_subtransactions != null and maybe_subtransactions.?.Array.items.len > 0) {
                for (maybe_subtransactions.?.Array.items) |sub_transaction| {
                    const sub_note = if (sub_transaction.Object.get("memo")) |memo| memo.String else note;
                    const sub_amount = try getAmount(sub_transaction.Object.get("amount").?);
                    const sub_payee = if (sub_transaction.Object.get("targetAccountId")) |transfer_id| blk: {
                        const to_account = ynab_accounts.get(transfer_id.String) orelse {
                            log.alert("Invalid account {s}", .{transfer_id.String});
                            return error.Invalid;
                        };
                        if (to_account == .off_budget) {
                            break :blk to_account.off_budget.payee_id;
                        }
                        if (account == .off_budget) continue;
                        try create_transfer.reset();
                        if (seen_transfer_ids.contains(sub_transaction.Object.get("transferTransactionId").?.String)) continue;
                        try seen_transfer_ids.put(sub_transaction.Object.get("entityId").?.String, {});
                        try create_transfer.bind(.{
                            account.on_budget,
                            to_account.on_budget,
                            date,
                            sub_amount,
                            sub_note,
                        });
                        try create_transfer.finish();
                        transfer_count += 1;
                        continue;
                    } else payee_id;
                    switch (account) {
                        .on_budget => |account_id| {
                            const ynab_sub_category = sub_transaction.Object.get("categoryId").?;
                            const category_id = if (std.mem.eql(u8, ynab_sub_category.String, "Category/__ImmediateIncome__") or
                                std.mem.eql(u8, ynab_sub_category.String, "Category/__DeferredIncome__"))
                                null
                            else
                                ynab_categories.get(ynab_sub_category.String) orelse {
                                    log.alert("Encountered invalid category {s}", .{ynab_sub_category.String});
                                    return error.Invalid;
                                };
                            try create_transaction.reset();
                            try create_transaction.bind(.{
                                account_id,
                                date,
                                sub_amount,
                                sub_payee,
                                category_id,
                                note,
                            });
                            try create_transaction.finish();
                        },
                        .off_budget => |off| {
                            try create_off_budget_transaction.reset();
                            try create_off_budget_transaction.bind(.{
                                off.id,
                                date,
                                sub_amount,
                                sub_payee,
                                note,
                            });
                            try create_off_budget_transaction.finish();
                        },
                    }
                    transaction_count += 1;
                }
            } else switch (account) {
                .on_budget => |account_id| {
                    const category_id = if (ynab_category_id == .String and
                        (std.mem.eql(u8, ynab_category_id.String, "Category/__ImmediateIncome__") or
                        std.mem.eql(u8, ynab_category_id.String, "Category/__DeferredIncome__")))
                        null
                    else switch (ynab_category_id) {
                        .String => |id| ynab_categories.get(id) orelse {
                            log.alert("Encountered invalid category {s}", .{ynab_category_id.String});
                            return error.Invalid;
                        },
                        else => off_budget_id,
                    };
                    try create_transaction.reset();
                    try create_transaction.bind(.{
                        account_id,
                        date,
                        amount,
                        payee_id,
                        category_id,
                        note,
                    });
                    try create_transaction.finish();
                    transaction_count += 1;
                },
                .off_budget => |off| {
                    try create_off_budget_transaction.reset();
                    try create_off_budget_transaction.bind(.{
                        off.id,
                        date,
                        amount,
                        payee_id,
                        note,
                    });
                    try create_off_budget_transaction.finish();
                    transaction_count += 1;
                },
            }
        }
        if (found_uncleared) {
            log.warn("Found some transactions which were not yet reconciled. Unreconciled transactions will not be imported", .{});
        }
        log.info("Created {} transactions and {} transfers", .{ transaction_count, transfer_count });
    }

    // ---- monthly budgets ----
    {
        var overspend_to_budget = std.AutoHashMap(i64, bool).init(&arena.allocator);
        defer overspend_to_budget.deinit();
        const create_budget = try db.prepare(
            \\INSERT OR REPLACE INTO monthly_budgets(month, amount, category_id)
            \\VALUES(?, ?, ?)
        );
        defer create_budget.finalize() catch {};
        const get_category_total = try db.prepare(
            \\SELECT SUM(balances.net) FROM (
            ++ budget_balances_query ++
            \\) AS balances
            \\WHERE category_id = ? AND month <= ?
        );
        defer get_category_total.finalize() catch {};
        var num_months: usize = 0;
        for (budget_obj.get("monthlyBudgets").?.Array.items) |monthly_budget| {
            const month = monthly_budget.Object.get("month").?.String[0..7];
            var any_budgeted = false;
            for (monthly_budget.Object.get("monthlySubCategoryBudgets").?.Array.items) |category_budget| {
                if (category_budget.Object.get("isTombstone") != null) continue;
                any_budgeted = true;
                const category_id = try getCategory(
                    category_budget.Object.get("categoryId").?.String,
                    ynab_categories,
                );
                var amount = try getAmount(category_budget.Object.get("budgeted").?);

                const affects_buffer_entry = try overspend_to_budget.getOrPut(category_id);
                if (!affects_buffer_entry.found_existing) {
                    affects_buffer_entry.entry.value = true;
                    // This is the first month that anything has been budgeted to this
                    // category, but it's possible that there have already been
                    // transactions before this month that got subtracted from the
                    // total budget. We can simulate this by creating a budget entry
                    // evening out the overspent amount for the month before this one.
                    try get_category_total.reset();
                    const previous_month = (try zig_date.Month.parse(month)).minusMonths(1).toString()[0..];
                    try get_category_total.bind(.{
                        category_id,
                        previous_month,
                    });
                    std.debug.assert(try get_category_total.step()); // sql query should return result
                    const category_total = get_category_total.columnInt(0);
                    if (category_total < 0) {
                        try create_budget.reset();
                        try create_budget.bind(.{ previous_month, -category_total, category_id });
                        try create_budget.finish();
                    }
                }

                switch (category_budget.Object.get("overspendingHandling").?) {
                    .String => |handling| {
                        affects_buffer_entry.entry.value = std.mem.eql(
                            u8,
                            handling,
                            "AffectsBuffer",
                        );
                    },
                    else => {},
                }
                if (affects_buffer_entry.entry.value) {
                    // "AffectsBuffer" months mean that any negative balance
                    // on that category should come out of the next month's
                    // budget. We can simulate this by increasing the amount
                    // budgeted to make the category zero.
                    try get_category_total.reset();
                    try get_category_total.bind(.{
                        category_id,
                        month,
                    });
                    std.debug.assert(try get_category_total.step()); // sql query should return result
                    const category_total = get_category_total.columnInt(0);

                    if (amount + category_total < 0) {
                        amount = -category_total;
                    }
                }
                try create_budget.reset();
                try create_budget.bind(.{ month, amount, category_id });
                try create_budget.finish();
            }
            if (any_budgeted) num_months += 1;
        }
        log.info("Populated budgets across {} year(s) and {} month(s).", .{
            num_months / 12,
            num_months % 12,
        });
    }

    {
        const get_account_balances = try db.prepare(
            \\SELECT accounts.name, transactions.sum - transfers_to.sum + transfers_from.sum
            \\FROM accounts
            \\LEFT JOIN (
            \\  SELECT accounts.name as name, SUM(COALESCE(transactions.amount, 0)) AS sum
            \\  FROM accounts
            \\  LEFT JOIN transactions on transactions.account_id = accounts.id
            \\  GROUP BY accounts.name
            \\) AS transactions ON transactions.name = accounts.name
            \\LEFT JOIN (
            \\  SELECT accounts.name as name, SUM(COALESCE(transfers.amount, 0)) AS sum
            \\  FROM accounts
            \\  LEFT JOIN transfers ON transfers.to_account_id = accounts.id
            \\  GROUP BY accounts.name
            \\) AS transfers_to ON transfers_to.name = accounts.name
            \\LEFT JOIN (
            \\  SELECT accounts.name as name, SUM(COALESCE(transfers.amount, 0)) AS sum
            \\  FROM accounts
            \\  LEFT JOIN transfers ON transfers.from_account_id = accounts.id
            \\  GROUP BY accounts.name
            \\) AS transfers_from ON transfers_from.name = accounts.name
            \\GROUP BY accounts.name
            \\ORDER BY accounts.name;
        );
        defer get_account_balances.finalize() catch {};
        log.info("Final account balances:", .{});
        while (try get_account_balances.step()) {
            const account_name = get_account_balances.columnText(0);
            const balance_cents = get_account_balances.columnInt64(1);
            const balance = Currency{ .amount = balance_cents };
            log.info("  {s}: {}", .{ account_name, balance });
        }
    }
    {
        const get_category_balances = try db.prepare(
            \\SELECT COALESCE(category_groups.name, '[HIDDEN]'), categories.name, SUM(balances.net)
            \\FROM (
            ++ budget_balances_query ++
            \\) as balances
            \\JOIN categories on categories.id = balances.category_id
            \\LEFT JOIN category_groups on category_groups.id = categories.category_group_id
            \\GROUP BY category_groups.name, categories.name
            \\ORDER BY category_groups.name, categories.name
        );
        defer get_category_balances.finalize() catch {};
        log.info("Final category balances:", .{});
        while (try get_category_balances.step()) {
            const group = get_category_balances.columnText(0);
            const category = get_category_balances.columnText(1);
            const balance = Currency{ .amount = get_category_balances.columnInt64(2) };
            log.info("  {: >9} {s}: {s}", .{ balance, group, category });
        }
    }
    try db.exec("COMMIT TRANSACTION");

    log.info("All done!", .{});
}

pub fn getAmount(value: std.json.Value) !i64 {
    return switch (value) {
        .Float => |flt| @floatToInt(i64, std.math.round(flt * 100)),
        .Integer => |int| int * 100,
        else => {
            log.alert("Encountered invalid amount of type {s}", .{@tagName(value.Object.get("amount").?)});
            return error.Invalid;
        },
    };
}

fn getCategory(entityId: []const u8, ynab_categories: std.StringHashMap(i64)) !i64 {
    return ynab_categories.get(entityId) orelse {
        log.alert("Encountered invalid category {s}", .{entityId});
        return error.Invalid;
    };
}

const PayeeId = union(enum) {
    transfer: i64,
    payee: i64,
};

pub fn importFromExport(
    db: *const sqlite.Database,
    allocator: *std.mem.Allocator,
    ynab_budget_export_path: []const u8,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var budget_file = std.fs.cwd().openFile(ynab_budget_export_path, .{});
    defer budget_file.deinit();
    var line_reader = dsv.lineReader(budget_file.reader(), MEGABYTE);
    var values_list = std.ArrayList([]const u8).init(&arena.allocator);
    defer values_list.deinit();

    const accounts_statement = db.prepare(
        \\INSERT INTO accounts()
    );
    while (try line_reader.nextLine()) |line| : (values_list.shrinkRetainingCapacity(0)) {
        var valueReader: dsv.DelimitedValueReader = .{ .line = line };
        try valueReader.collectIntoArrayList(&values_list);
    }
}
