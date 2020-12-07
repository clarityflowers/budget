const std = @import("std");
const ncurses = @import("ncurses.zig");
const attr = @import("attributes.zig").attr;
const import = @import("../import.zig");
const Currency = @import("../Currency.zig");

pub const FieldTag = enum {
    payee,
    category,
    memo,
};

pub const Error = ncurses.Box.WriteError;

pub fn render(
    window: *ncurses.Box,
    current: usize,
    field: FieldTag,
    transactions: []const import.ImportedTransaction,
) Error!void {
    window.attrSet(0) catch {};

    const number_to_display = (@intCast(usize, window.bounds.height - 1) / 4);
    const start = std.math.min(
        transactions.len - number_to_display,
        if (current < (number_to_display / 2)) 0 else (current - (number_to_display / 2)),
    );
    const writer = window.writer();
    window.move(.{});
    writer.writeAll("─" ** 12) catch {};
    if (start > 0) {
        window.writeCodepoint('┼') catch {};
    } else {
        window.writeCodepoint('┬') catch {};
    }
    window.fillLine('─') catch {};

    for (transactions[start..std.math.min(transactions.len, start + number_to_display + 1)]) |transaction, i| {
        const row = i * 4 + 1;
        window.move(.{ .line = row });
        writer.print("{Day, Mon DD} │ ", .{transaction.date}) catch {};
        const is_current = i + start == current;
        {
            const highlight = is_current and field == .payee;

            if (transaction.payee == .unknown) {
                if (highlight) {
                    window.attrSet(attr(.attention_highlight)) catch {};
                } else {
                    window.attrSet(attr(.attention)) catch {};
                }
                writer.print("({})", .{transaction.payee}) catch {};
            } else {
                if (highlight) {
                    window.attrSet(attr(.highlight)) catch {};
                }
                writer.print("{}", .{transaction.payee}) catch {};
            }
            window.attrSet(0) catch {};
        }
        window.move(.{ .line = row + 1 });
        const amount = Currency{ .amount = transaction.amount };
        writer.print("{: >11} │ ", .{amount}) catch {};
        {
            const highlight = is_current and field == .category;
            if (transaction.category) |category| {
                if (highlight) {
                    window.attrSet(attr(.highlight)) catch {};
                }
                writer.print("{: <20}", .{transaction.category}) catch {};
            } else {
                if (transaction.payee == .payee) {
                    if (highlight) {
                        window.attrSet(attr(.attention_highlight)) catch {};
                    } else {
                        window.attrSet(attr(.attention)) catch {};
                    }
                    writer.print("(enter a category)", .{}) catch {};
                }
            }
            window.attrSet(0) catch {};
        }
        window.move(.{ .line = row + 2 });
        try writer.writeAll(" " ** 12 ++ "│ ");
        {
            const highlight = is_current and field == .memo;
            if (highlight) {
                window.attrSet(attr(.highlight)) catch {};
                if (transaction.memo.len == 0) {
                    try writer.writeAll("(enter a memo)");
                } else {
                    try writer.writeAll(transaction.memo);
                }
            } else {
                try writer.writeAll(transaction.memo);
            }
        }
        window.attrSet(0) catch {};
        window.move(.{ .line = row + 3 });
        writer.writeAll("─" ** 12) catch {};
        if (i + start == transactions.len - 1) {
            window.writeCodepoint('┴') catch {};
        } else {
            window.writeCodepoint('┼') catch {};
        }
        window.fillLine('─') catch {};
    }
}
