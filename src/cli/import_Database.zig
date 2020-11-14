const sqlite = @import("../sqlite-zig/src/sqlite.zig");

payee_autocomplete: sqlite.Statement,
payee_create: sqlite.Statement,
payee_match_create: sqlite.Statement,
payee_rename: sqlite.Statement,

pub fn init(db: *const sqlite.Database) !@This() {
    return @This(){
        .payee_autocomplete = try db.prepare(@embedFile("payee_completions.sql")),
        .payee_create = try db.prepare("INSERT INTO payees(name) values(?)"),
        .payee_match_create = try db.prepare(
            \\INSERT INTO payee_matches(payee_id, transfer_id, match, pattern)
            \\VALUES(?, ?, ?, ?)
        ),
        .payee_rename = try db.prepare(
            \\UPDATE OR FAIL payees
            \\SET name = ?
            \\WHERE id = ?
        ),
    };
}

pub fn deinit(self: @This()) void {
    self.payee_autocomplete.finalize() catch {};
    self.payee_create.finalize() catch {};
    self.payee_match_create.finalize() catch {};
    self.payee_rename.finalize() catch {};
}

pub const PayeeId = union(enum) {
    transfer: i64, payee: i64
};
pub const Match = enum {
    exact, prefix, suffix, contains
};

pub fn getError(self: @This()) ?[*:0]const u8 {
    return self.payee_match_create.dbHandle().errmsg();
}

pub fn createPayeeMatch(self: @This(), id: PayeeId, match: Match, pattern: []const u8) !void {
    const statement = self.payee_match_create;
    statement.reset() catch {};
    const payee_id = switch (id) {
        .payee => |payee_id| payee_id,
        else => null,
    };
    const transfer_id = switch (id) {
        .transfer => |transfer_id| transfer_id,
        else => null,
    };
    const match_type: ?[]const u8 = switch (match) {
        .exact => null,
        .prefix => "starts_with",
        .suffix => "ends_with",
        .contains => "contains",
    };
    try statement.bind(.{
        payee_id,
        transfer_id,
        pattern,
        match_type,
    });
    try statement.finish();
}

pub fn createPayee(self: @This(), name: []const u8) !i64 {
    const statement = self.payee_create;
    statement.reset() catch {};
    try statement.bind(.{name});
    try statement.finish();
    return statement.dbHandle().lastInsertRowId();
}
