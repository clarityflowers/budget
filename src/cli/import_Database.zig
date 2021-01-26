const sqlite = @import("../sqlite-zig/src/sqlite.zig");
const import = @import("../import.zig");

handle: *const sqlite.Database,
payee_autocomplete: sqlite.Statement,
payee_create: sqlite.Statement,
payee_match_create: sqlite.Statement,
category_autocomplete: sqlite.Statement,
category_group_create: sqlite.Statement,
category_create: sqlite.Statement,
category_match_create: sqlite.Statement,
category_autofill: import.AutofillCategoryQuery,

pub fn init(db: *const sqlite.Database) !@This() {
    return @This(){
        .handle = db,
        .payee_autocomplete = try db.prepare(@embedFile("payee_completions.sql")),
        .payee_create = try db.prepare("INSERT INTO payees(name) values(?)"),
        .payee_match_create = try db.prepare(
            \\INSERT OR REPLACE INTO payee_matches(payee_id, transfer_id, match, pattern)
            \\VALUES(?, ?, ?, ?)
        ),
        .category_autocomplete = try db.prepare(@embedFile("category_completions.sql")),
        .category_group_create = try db.prepare("INSERT INTO category_groups(name) VALUES (?)"),
        .category_create = try db.prepare("INSERT INTO categories(category_group_id, name) VALUES (?, ?)"),
        .category_match_create = try db.prepare(
            \\INSERT OR REPLACE INTO category_matches(payee_id, category_id, amount, note, note_pattern)
            \\VALUES (?, ?, ?, ?, ?)
        ),
        .category_autofill = try import.AutofillCategoryQuery.init(db),
    };
}

pub fn deinit(self: @This()) void {
    self.payee_autocomplete.finalize() catch {};
    self.payee_create.finalize() catch {};
    self.payee_match_create.finalize() catch {};
    self.category_autocomplete.finalize() catch {};
    self.category_group_create.finalize() catch {};
    self.category_create.finalize() catch {};
    self.category_match_create.finalize() catch {};
    self.category_autofill.deinit();
}

pub const PayeeId = union(enum) {
    transfer: i64, payee: i64
};
pub const Match = enum {
    exact,
    prefix,
    suffix,

    pub fn toString(self: @This()) ?[]const u8 {
        return switch (self) {
            .exact => null,
            .prefix => "starts_with"[0..],
            .suffix => "ends_with"[0..],
        };
    }
};

pub const Error = error{ CreatePayeeMatchFailed, CreatePayeeFailed, RenamePayeeFailed };

pub fn getError(self: @This()) ?[*:0]const u8 {
    return self.payee_match_create.dbHandle().errmsg();
}

pub fn createPayeeMatch(
    self: @This(),
    id: PayeeId,
    match: Match,
    pattern: []const u8,
) !void {
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
    const match_type = match.toString();
    statement.bind(.{
        payee_id,
        transfer_id,
        pattern,
        match_type,
    }) catch return Error.CreatePayeeMatchFailed;
    statement.finish() catch return Error.CreatePayeeMatchFailed;
}

pub fn createPayee(self: @This(), name: []const u8) !i64 {
    const statement = self.payee_create;
    statement.reset() catch {};
    statement.bind(.{name}) catch return Error.CreatePayeeFailed;
    statement.finish() catch return Error.CreatePayeeFailed;
    return statement.dbHandle().lastInsertRowId();
}

pub fn iterateCategoryMatches(self: @This(), str: []const u8) !CategoryMatchIterator {
    self.category_autocomplete.reset() catch {};
    self.category_autocomplete.bind(.{str}) catch return error.CategoryMatchFailed;
    const result: CategoryMatchIterator = .{
        .statement = self.category_autocomplete,
    };
    return result;
}

pub const CategoryMatchId = union(enum) {
    perfect: CategoryId,
    category_perfect: i64,
    group_perfect_category_partial: i64,
    group_perfect: i64,
    group_partial,
    category_partial,
};
pub const CategoryMatch = struct {
    id: CategoryMatchId,
    completion: []const u8,
    match: []const u8,
};

pub const CategoryMatchIterator = struct {
    statement: sqlite.Statement,

    pub fn next(self: @This()) !?CategoryMatch {
        if (self.statement.step() catch return error.CategoryMatchFailed) {
            const completion = self.statement.columnText(2);
            const match = self.statement.columnText(4);
            const id = switch (self.statement.columnInt(3)) {
                0 => if (self.statement.columnType(0) == .Null)
                    CategoryMatchId{ .perfect = .{ .income = .{} } }
                else
                    CategoryMatchId{ .perfect = .{ .budget = self.statement.columnInt64(1) } },
                1 => CategoryMatchId{ .category_perfect = self.statement.columnInt64(1) },
                2 => CategoryMatchId{ .group_perfect_category_partial = self.statement.columnInt64(1) },
                3 => CategoryMatchId{ .group_perfect = self.statement.columnInt64(0) },
                4 => CategoryMatchId{ .group_partial = .{} },
                5 => CategoryMatchId{ .category_partial = .{} },
                else => unreachable,
            };

            return CategoryMatch{
                .id = id,
                .completion = completion,
                .match = match,
            };
        }
        return null;
    }
};

pub const CategoryId = union(@TagType(import.Category)) {
    income,
    budget: i64,
};

pub fn createCategoryGroup(self: @This(), name: []const u8) !i64 {
    self.category_group_create.reset() catch {};
    self.category_group_create.bind(.{name}) catch return error.CreateCategoryGroupFailed;
    self.category_group_create.finish() catch return error.CreateCategoryGroupFailed;
    return self.category_group_create.dbHandle().lastInsertRowId();
}

pub fn createCategory(self: @This(), group_id: i64, name: []const u8) !i64 {
    self.category_create.reset() catch {};
    self.category_create.bind(.{ group_id, name }) catch return error.CreateCategoryFailed;
    self.category_create.finish() catch return error.CreateCategoryFailed;
    return self.category_group_create.dbHandle().lastInsertRowId();
}

pub const CategoryMatchNote = struct {
    value: []const u8,
    match: Match,
};

pub fn createCategoryMatch(
    self: @This(),
    payee: i64,
    category_id: CategoryId,
    amount: ?i32,
    note: ?CategoryMatchNote,
) !void {
    self.category_match_create.reset() catch {};
    const id: ?i64 = if (category_id == .budget) category_id.budget else null;
    const note_value: ?[]const u8 = if (note) |n| n.value else null;
    const note_pattern: ?[]const u8 = if (note) |n| n.match.toString() else null;
    self.category_match_create.bind(.{
        payee,
        id,
        amount,
        note_value,
        note_pattern,
    }) catch return error.CreateCategoryMatchFailed;
    self.category_match_create.finish() catch return error.CreateCategoryMatchFailed;
}
