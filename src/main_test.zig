comptime {
    _ = @import("args.zig");
    _ = @import("import.zig");
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
    }, {});
    try cwd.deleteTree("./.test_files/import");
}
