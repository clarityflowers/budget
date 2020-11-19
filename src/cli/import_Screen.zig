const std = @import("std");
const PayeeEditor = @import("import_PayeeEditor.zig");
const sqlite = @import("../sqlite-zig/src/sqlite.zig");
const ncurses = @import("ncurses.zig");
const import = @import("../import.zig");
const Currency = @import("../Currency.zig");
const attr = @import("attributes.zig").attr;
const Database = @import("import_Database.zig");

db: Database,
allocator: *std.mem.Allocator,
data: import.PreparedImport,
// payees: std.AutoHashMap(i64, import.Payee),
state: ScreenState = .{},
attempting_interrupt: bool = false,
initialized: bool = false,

const Field = union(enum) {
    payee: PayeeEditor,
    category,
};
const ScreenState = struct {
    field: Field,
    current: usize = 0,
};

pub const DB = struct {};

pub fn init(
    db: *const sqlite.Database,
    data: import.PreparedImport,
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
    };
    if (data.transactions[0].payee != .unknown) {
        result.state = result.getNextMissing() orelse result.state;
    }
    return result;
}

pub fn deinit(self: *@This()) void {
    self.db.deinit();
}

pub fn getNextMissing(self: @This()) ?ScreenState {
    const current = self.data.transactions[self.state.current];
    if (self.state.field == .payee) {
        if (current.category == null) {
            return ScreenState{
                .current = self.state.current,
                .field = .category,
            };
        }
    }
    var i = (self.state.current + 1) % self.data.transactions.len;
    while (i != self.state.current) : (i = (i + 1) % self.data.transactions.len) {
        const transaction = self.data.transactions[i];
        if (transaction.payee == .unknown) {
            return ScreenState{
                .current = i,
                .field = .{ .payee = undefined },
            };
        } else if (transaction.category == null) {
            return ScreenState{
                .current = i,
                .field = .category,
            };
        }
    }
    return null;
}

pub fn moveUp(self: @This()) ScreenState {
    var result = self.state;
    if (result.current == 0) {
        result.current = self.data.transactions.len - 1;
    } else {
        result.current -= 1;
    }
    switch (result.field) {
        .payee => result.field = .{ .payee = undefined },
        .category => result.field = .category,
    }
    return result;
}

pub fn moveDown(self: @This()) ScreenState {
    var result = self.state;
    result.current = (result.current + 1) % self.data.transactions.len;
    switch (result.field) {
        .payee => result.field = .{ .payee = undefined },
        .category => result.field = .category,
    }
    return result;
}

pub fn next(self: @This()) ScreenState {
    var result = self.state;
    switch (result.field) {
        .payee => {
            result.field = .category;
        },
        .category => {
            result = self.moveDown();
            result.field = .{ .payee = undefined };
        },
    }
    return result;
}
pub fn prev(self: @This()) ScreenState {
    var result = self.state;
    switch (result.field) {
        .payee => {
            result = self.moveUp();
            result.field = .category;
            // self.field = .amount;
        },
        .category => {
            result.field = .{ .payee = undefined };
        },
        // .memo => {
        //     self.field = .category;
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

pub fn render(self: *@This(), box: *ncurses.Box, input_key: ?ncurses.Key) !bool {
    if (self.initialized == false) {
        self.initState();
        self.initialized = true;
    }
    var input = input_key;
    const transactions = self.data.transactions;

    var window = box.box(.{
        .height = box.bounds.height - 3,
    });
    var new_state: ?ScreenState = null;
    box.setCursor(.invisible);
    box.attrSet(0) catch {};

    // window.wrap = true;
    const number_to_display = (@intCast(usize, window.bounds.height - 1) / 4);
    const state = new_state orelse self.state;
    const start = std.math.min(
        transactions.len - number_to_display,
        if (state.current < (number_to_display / 2)) 0 else (state.current - (number_to_display / 2)),
    );
    const writer = window.writer();
    for (transactions[start..]) |transaction, i| {
        const row = i * 4 + 1;
        if (row + 4 > window.bounds.height) break;
        window.move(.{ .line = row + 1 });
        writer.print("{Day, Mon DD} ┊ ", .{transaction.date}) catch {};
        const is_current = i + start == state.current;
        {
            const highlight = is_current and state.field == .payee;
            if (highlight) {
                window.attrSet(attr(.attention_highlight)) catch {};
            }
            if (transaction.payee == .unknown) {
                if (!highlight) {
                    window.attrSet(attr(.attention)) catch {};
                }
                writer.print("({})", .{transaction.payee}) catch {};
            } else {
                writer.print("{}", .{transaction.payee}) catch {};
            }
            window.attrSet(0) catch {};
        }
        window.move(.{ .line = row + 2 });
        const amount = Currency{ .amount = transaction.amount };
        writer.print("{: >11} ┊ ", .{amount}) catch {};
        {
            const highlight = is_current and state.field == .category;
            if (highlight) {
                window.attrSet(attr(.attention_highlight)) catch {};
            }
            if (transaction.category) |category| {
                writer.print("{: <20}", .{transaction.category}) catch {};
            } else {
                if (!highlight) {
                    window.attrSet(attr(.attention)) catch {};
                }
                writer.print("(enter a category)", .{}) catch {};
            }
            window.attrSet(0) catch {};
        }
        window.move(.{ .line = row + 3 });
        writer.print("            ┊ {}", .{transaction.memo}) catch {};
        window.move(.{ .line = row + 4 });
        writer.print("────────────", .{}) catch {};
        if (i + start == transactions.len - 1) {
            window.writeCodepoint('┴') catch {};
        } else {
            window.writeCodepoint('┼') catch {};
        }
        window.fillLine('─') catch {};
    }
    const max_y = window.bounds.height;
    box.move(.{ .line = max_y });
    box.fillLine('═') catch {};

    if (input != null and input.? == .char and input.?.char == 0x04) { //^D
        std.process.exit(1);
    }

    var lower_box = box.box(.{ .line = max_y + 1, .height = 3 });
    if (self.attempting_interrupt) {
        lower_box.move(.{});
        lower_box.writer().print("Press ^C again to quit.", .{}) catch {};
    } else {
        switch (self.state.field) {
            .payee => |*payee_editor| {
                if (try payee_editor.render(input, &lower_box)) {
                    input = null;
                }
            },
            else => {},
        }
    }

    var attempting_interrupt = false;
    if (input) |key| {
        switch (key) {
            .control => |ctl| switch (ctl) {
                ncurses.key.up => {
                    new_state = self.moveUp();
                },
                ncurses.key.down => {
                    new_state = self.moveDown();
                },
                ncurses.key.btab => {
                    new_state = self.prev();
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
                    new_state = self.next();
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
            .category => {},
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
    switch (self.state.field) {
        .payee => |*payee| {
            payee.* = PayeeEditor.init(
                self.db,
                &self.data.transactions[self.state.current].payee,
                &self.data.payees,
                &self.data.accounts,
                self.allocator,
            );
        },
        else => {},
    }
}
