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

const fmt = std.fmt;
const math = std.math;

const dates = @import("dates.zig");
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

const TentativeTransaction = struct {
    imported: ImportedTransaction,
    category: ?[]const u8,
};

const ImportedTransaction = struct {
    date: Date, amount: i32, payee: []const u8, memo: []const u8, id: []const u8
};

const BudgetLine = struct {
    date: Date, amounts_by_category: StringHashMap(i32)
};

fn sortTransaction(context: void, lh: *Transaction, rh: *Transaction) bool {
    return lh.earlierThan(rh);
}

pub const transaction_log_header =
    \\date	amount	payee	category	note	bank note	reconciled
;

const TransactionLog = struct {
    const TransactionList = SegmentedList(Transaction, 1024);

    transactions: TransactionList,
    payees: StringLibrary,
    categories: StringLibrary,
    bank_notes: StringLibrary,
    sorted: ArrayList(*Transaction),

    pub fn load(stream: anytype, allocator: *Allocator) !@This() {
        var result = @This(){
            .payees = StringLibrary.init(allocator),
            .categories = StringLibrary.init(allocator),
            .transactions = TransactionList.init(allocator),
            .bank_notes = StringLibrary.init(allocator),
            .sorted = ArrayList(*Transaction).init(allocator),
        };
        const payees = &result.payees;
        const categories = &result.categories;
        const transactions = &result.transactions;
        const bank_notes = &result.bank_notes;
        const reader = &DelimitedRecordReader(@TypeOf(stream), '\t', 1024).init(stream, allocator);
        {
            const headers = (try reader.nextLine()) orelse return error.FileIsEmpty;
            if (!mem.eql(u8, transaction_log_header, headers.line)) {
                return error.InvalidHeader;
            }
        }
        while (try reader.nextLine()) |*line| {
            const transaction = try transactions.addOne();
            transaction.* = .{
                .date = try line.nextValueAsDate(),
                .amount = try line.nextValueAsCents(i32),
                .payee = try payees.save(try line.nextValue()),
                .category = try categories.save(try line.nextValue()),
                .note = try allocator.dupe(u8, try line.nextValue()),
                .bank_note = try bank_notes.save(try line.nextValue()),
                .reconciled = mem.eql(u8, try line.nextValue(), "y"),
            };
            try result.sorted.append(transaction);
        }
        sort(*Transaction, result.sorted.items, {}, sortTransaction);
        return result;
    }
};

test "load existing transactions" {
    var arena = ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = &arena.allocator;

    const tsv_transactions =
        \\date	amount	payee	category	note	bank note	reconciled
        \\2020-05-11	-14.23	Safeway	Supplies	groceries	SAFEWAY 234234234	n
        \\2020-04-30	+100.12	Olé Olé	eating out		OLEOLE 23423	y
    ;

    const stream = &fixedBufferStream(tsv_transactions).inStream();
    const transactions = (try TransactionLog.load(stream, allocator)).transactions;
    expectEqual(@as(usize, 2), transactions.count());
    expectEqual(Date.init(2020, 5, 11), transactions.at(0).date);
    expectEqual(@as(i32, -1423), transactions.at(0).amount);
    expectEqualSlices(u8, "Safeway", transactions.at(0).payee);
    expectEqualSlices(u8, "Supplies", transactions.at(0).category);
    expectEqualSlices(u8, "groceries", transactions.at(0).note);
    expectEqualSlices(u8, "SAFEWAY 234234234", transactions.at(0).bank_note);
    expectEqual(false, transactions.at(0).reconciled);

    expectEqual(Date.init(2020, 4, 30), transactions.at(1).date);
    expectEqual(@as(i32, 10012), transactions.at(1).amount);
    expectEqualSlices(u8, "Olé Olé", transactions.at(1).payee);
    expectEqualSlices(u8, "eating out", transactions.at(1).category);
    expectEqualSlices(u8, "", transactions.at(1).note);
    expectEqualSlices(u8, "OLEOLE 23423", transactions.at(1).bank_note);
    expectEqual(false, transactions.at(0).reconciled);
}

pub const DsvStringRule = union(enum) {
    Single: u16,
    Pick: []const u16,
    Combine: []const u16,
    None,

    pub fn take(self: @This(), values: []const []const u8, allocator: *Allocator) ![]const u8 {
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
                break :blk "";
            },
            .None => "",
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
        return try Date.parseCustom(self.format, values[self.column]);
    }
};
pub const ImportDsvRules = struct {
    has_header: bool,
    date: DsvDateRule,
    amount: DsvCurrencyRule,
    payee: DsvStringRule,
    memo: DsvStringRule,
    id: DsvStringRule,
};

pub fn convert(
    rules: ImportDsvRules,
    source_reader: anytype,
    dest_writer: anytype,
    existing_file: std.fs.File,
    allocator: *Allocator,
) !void {
    var arena = ArenaAllocator.init(allocator);
    defer arena.deinit();
}

test "import cccu transactions" {
    const csv =
        \\"Transaction ID","Posting Date","Effective Date","Transaction Type","Amount","Check Number","Reference Number","Description","Transaction Category","Type","Balance","Memo","Extended Description"
        \\"20200508 78118 50,000 29,067","5/8/2020","5/8/2020","Debit","-500.00000","","16773445","To Share 15","","","17164.25000","","To Share 15"
        \\"20200505 78118 5,565 35,120","5/5/2020","5/5/2020","Debit","-55.65000","","16773444","Portland General CO: Portland General","","","17664.25000","","Portland General CO: Portland General"
        \\"20200501 78118 306,698 61,629","5/1/2020","5/1/2020","Credit","3066.98000","","16584030","GUSTO CO: GUSTO","","","17719.90000","","GUSTO CO: GUSTO"
    ;
    const rules = ImportDsvRules{
        .has_header = true,
        .date = .{ .column = 1, .format = "M/D/Y" },
        .amount = .{ .income = 4, .expenses = 4 },
        .payee = .{ .Single = 7 },
        .memo = .{ .Combine = ([_]u16{ 11, 12 })[0..] },
        .id = .{ .Single = 0 },
    };
    var arena = ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = &arena.allocator;
    const stream = &fixedBufferStream(csv).inStream();
    const transactions = &SegmentedList(ImportedTransaction, 4).init(allocator);
    const reader = &LineReader(@TypeOf(stream), 1024).init(stream, allocator);
    const values_list = &ArrayList([]const u8).init(allocator);
    if (rules.has_header) _ = try reader.nextLine();
    while (try reader.nextLine()) |line| : (try values_list.resize(0)) {
        const values_reader = &DelimitedValueReader(','){ .line = line };
        while (values_reader.nextValue() catch null) |value| {
            try values_list.append(value);
        }
        const values = values_list.items;
        try transactions.push(.{
            .date = try rules.date.take(values),
            .amount = try rules.amount.take(values),
            .payee = try rules.payee.take(values, allocator),
            .memo = try rules.memo.take(values, allocator),
            .id = try rules.id.take(values, allocator),
        });
    }
    expectEqual(@as(usize, 3), transactions.count());
    expectEqual(Date.init(2020, 5, 8), transactions.at(0).date);
    expectEqual(@as(i32, -50000), transactions.at(0).amount);
    expectEqualSlices(u8, "To Share 15", transactions.at(0).payee);
    expectEqualSlices(u8, "To Share 15", transactions.at(0).memo);
    expectEqualSlices(u8, "20200508 78118 50,000 29,067", transactions.at(0).id);
    expectEqual(Date.init(2020, 5, 5), transactions.at(1).date);
    expectEqual(@as(i32, -5565), transactions.at(1).amount);
    expectEqualSlices(u8, "Portland General CO: Portland General", transactions.at(1).payee);
    expectEqualSlices(u8, "Portland General CO: Portland General", transactions.at(1).memo);
    expectEqualSlices(u8, "20200505 78118 5,565 35,120", transactions.at(1).id);
    expectEqual(Date.init(2020, 5, 1), transactions.at(2).date);
    expectEqual(@as(i32, 306698), transactions.at(2).amount);
    expectEqualSlices(u8, "GUSTO CO: GUSTO", transactions.at(2).payee);
    expectEqualSlices(u8, "GUSTO CO: GUSTO", transactions.at(2).memo);
    expectEqualSlices(u8, "20200501 78118 306,698 61,629", transactions.at(2).id);
}
