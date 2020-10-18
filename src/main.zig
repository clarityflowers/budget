const std = @import("std");
const io = std.io;
const process = std.process;
const heap = std.heap;
const mem = std.mem;
const fs = std.fs;

const ArgIterator = process.ArgIterator;
const Allocator = mem.Allocator;
const ArenaAllocator = heap.ArenaAllocator;

const zig_args = @import("args.zig");
const import = @import("import.zig");

comptime {
    _ = @import("args.zig");
    _ = @import("import.zig");
}

const ArgsSpec = union(enum) {
    import: ImportOptions
};

const Context = struct {
    allocator: *Allocator,
    err_writer: var,
    writer: var,
    reader: var,
};

pub fn main() !void {
    var arena = ArenaAllocator.init(heap.page_allocator);
    defer arena.deinit();
    const allocator = &arena.allocator;

    const arg_iterator = &(try ArgIterator.initWithAllocator(allocator));

    try zig_args.parseAndRun(ArgsSpec, arg_iterator, allocator, &io.getStdErr().writer(), {});
}
// > budget import --account bank ./.test_files/example_bank_transactions.csv
// Importing ./.test_files/example_bank_transactions into bank...
// No import plan detected for this account. Creating one now.
// File has header: true
// Date <- Posting Date, M/D/YYYY (maybe D/M/YYYY?)
// Amount <- Amount
// Payee <- ?
// Memo <- Memo
// Id <- Transaction ID
//
// Commands: (v)iew plan, view (c)olumns, has (h)eader, set (d)ate, set (a)mount, set (p)ayee, set (m)emo, set (i)d, (h)elp, (d)one. (view plan)
// plan> c
// (1) Transaction ID: 20200508....
// (2) Posting Date: 5/8/2020, ....
// (3) ...
// plan> d
// Enter column, or view (c)olumns
// plan date column> 2
// Date format (ex: YYYY-MM-DD, M/D/YYYY)
// plan date format> M/D/YYYY
// Date <- Posting Date, M/D/YYYY
// plan> a
// Enter column for income, or view (c)olumns
// plan amount income> 5
// Enter column for expenses (might be same as income), or view (c)olumns
// plan amount expenses> 5
// Amount <- Amount
// plan> p
// Enter column for payee, or (m)erge multiple columns, or use (f)irst of multiple, or view (c)olumns
// plan payee> 8
// Payee <- Description
// plan> m
// Enter column for memo, or (m)erge multiple columns, or use (f)irst of multiple, or view (c)olumns
// plan memo> m
// Enter columns separated by commas
// plan memo merge> 11,12
// Memo <- merge Memo and Extended Description
// plan> d
// Loading transactions...
//
// Commands: go to (n)ext, go (b)ack, set (d)ate, set (p)ayee, set (m)emo, set ban(k) memo, set bank (i)d, set (a)mount, (d)one. (go to next)
//
// #    | Date          | Payee           | Memo | Bank Memo       | Bank Id                      | Amount
// 1/24 | Monday, May 8 | GUSTO CO: GUSTO |      | GUSTO CO: GUSTO | 20200508 78118 50,000 29,067 | + $3066.98
// transaction 1> d
// Enter date (YYYY-MM-DD) or go (b)ack one day or to (n)ext day. (2020-05-08)
// transaction 1 date> n
// Tuesday, May 9
// transaction 1 date>
// Date <- Tuesday, May 9
// transaction 1> p
// Enter payee
// transaction 1 payee> Gusto
// Payee <- Gusto ?
// Commands: (o)k, (c)ancel, create (m)apping. (ok)
// transaction 1 payee confirm> m
// Enter pattern for mapping (GUSTO CO: GUSTO)
// transaction 1 payee mapping>
// New mapping: "GUSTO CO: GUSTO" -> "Gusto"
// transaction 1> m
// Enter memo
// transaction 1 memo> Salary
// Memo <- Salary
// transaction 1> a
// Set amount (3066.98)
// transaction 1 amount> 2000
// Amount <- + $2000.00
// transaction 1>
// #    | Date          | Payee           | Memo | Bank Memo       | Bank Id                      | Amount
// 2/24 | Monday, May 8 | GUSTO CO: GUSTO |      | GUSTO CO: GUSTO | 20200508 78118 50,000 29,067 | + $3066.98
// transaction 2>

const TransactionMachine = struct {
    transactions: var,
    imported: var,
    index: usize,
    state: union(enum) {
        date: struct {
            current: Date,

            pub fn go_back_one_day(self: *@This()) void {
                self.current = self.current.minusDays(1);
            }
            pub fn _handleValue(self: *@This(), context: *TransactionMachine, value: []const u8) void {
                if (value.len != 0) {}
            }
        }
    },

    pub fn go_to_next(self: *@This()) void {
        self.index += 1;
    }
    const shortcut_n = "go to next";
    pub fn _printState(self: *@This(), writer: var) !void {
        try writer.print("transaction {}", .{self.index});
    }
};

const Prompter = struct {
    allocator: *Allocator,
    writer: var,
    reader: var,
    output_to_terminal: bool,

    pub fn promptCommand(self: @This(), comptime commands: type, comptime state_fmt: []const u8, state_args: var) void {
        try self.writer.print(state_fmt, state_args);
        try self.writer.writeAll("> ");
    }
};

fn entry() void {
    const transactions: []const Transaction = undefined;
    const index: usize = 0;
    const current_transaction: *Transaction = &Transactions[index];
    while (true) {
        const input = try promptCommand(enum {
            set_date,
            const d = set_date;
        }, "transaction {}", .{index + 1});
        if (input.command) |command| switch (command) {
            .set_date => {
                current_transaction.date = get_date: {
                    var current_date = date;
                    // Enter date (YYYY-MM-DD) or go (b)ack one day or to (n)ext day. (2020-05-08)
                    while (true) {
                        const input = try promptCommand(enum {
                            done,
                            go_to_next_day,
                            const d = done;
                            const n = go_to_next_day;
                            const default = done;
                        }, "transaction {} date", .{index + 1});
                        if (input.command) |command| {
                            switch (command) {
                                .done => break :get_date current_date,
                                .go_to_next_day => {
                                    current_date = current_date.plusDays(1);
                                },
                            }
                        } else if (parse.date(input.value)) |d| {
                            break :get_date d;
                        } else |err| {
                            // invalid command
                        }
                    }
                };
            },
        };
    }
}

test "import" {
    var arena = ArenaAllocator.init(heap.page_allocator);
    defer arena.deinit();

    const cwd = fs.cwd();
    try cwd.deleteTree("./.test_files/import");
    try cwd.makePath("./.test_files/import");
    const account_file = try cwd.createFile("./.test_files/account_bank.tsv", .{});
    defer account_file.close();
    try account_file.writer().writeAll(
        \\date	amount	payee	category	note	bank note	reconciled
        \\2020-05-11	-14.23	Safeway	Supplies	groceries	SAFEWAY 234234234	n
        \\2020-04-30	+100.12	Olé Olé	eating out		OLEOLE 23423	y
    );

    const transactions = try cwd.createFile("./.test_files/example_bank_transactions.csv", .{});
    defer transactions.close();
    try transactions.writer().writeAll(
        \\"Transaction ID","Posting Date","Effective Date","Transaction Type","Amount","Check Number","Reference Number","Description","Transaction Category","Type","Balance","Memo","Extended Description"
        \\"20200508 78118 50,000 29,067","5/8/2020","5/8/2020","Debit","-500.00000","","16773445","To Share 15","","","17164.25000","","To Share 15"
        \\"20200505 78118 5,565 35,120","5/5/2020","5/5/2020","Debit","-55.65000","","16773444","Portland General CO: Portland General","","","17664.25000","","Portland General CO: Portland General"
        \\"20200501 78118 306,698 61,629","5/1/2020","5/1/2020","Credit","3066.98000","","16584030","GUSTO CO: GUSTO","","","17719.90000","","GUSTO CO: GUSTO"
    );

    var args = zig_args.TestArgIterator{
        .args = &[_][]const u8{
            "exe", "import", "--account", "bank", "--dir", "./.test_files/import", "./.test_files/example_bank_transactions.csv",
        },
    };
    try ImportOptions.exec(.{
        .arena = arena,
        .positionals = &[_][]const u8{"./.test_files/example_bank_transactions.csv"},
        .options = .{
            .account = "bank",
            .dir = "./.test_files/import",
        },
        .exe_name = "",
    });
    try cwd.deleteTree("./.test_files/import");
}

const ncurses = @import("ncurses.zig");

// budget import [--account <account>] [--dir <budgetdir>] <importfile>
pub const ImportOptions = struct {
    account: ?[]const u8,
    dir: ?[]const u8,

    pub const shorthands = .{ .a = "account" };
    pub fn exec(args: zig_args.ParseArgsResult(@This()), context: void) !void {
        defer args.arena.deinit();
        const stderr = &io.getStdErr().writer();

        const screen = try ncurses.Window.initscr();
        try screen.writer().print("Hello, {}", .{"world"});

        if (args.positionals.len != 1) {
            try stderr.print("Unexpected positional argument {}", .{args.positionals[1]});
            return error.UnexpectedPositional;
        }

        std.debug.warn("Hello, world\n", .{});
        for (args.positionals) |arg, i| {
            try screen.writer().print("positional {}: {}\n", .{ i, arg });
        }
    }
};
