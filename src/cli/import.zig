const std = @import("std");
const import = @import("../import.zig");
const sqlite = @import("../sqlite-zig/src/sqlite.zig");
const log = @import("../log.zig");
const Screen = @import("import_Screen.zig");
const ncurses = @import("ncurses.zig");
const attributes = @import("curse.zig");
const initNcurses = @import("curse.zig").init;

fn printColors(window: ncurses.Window) !void {
    const writer = window.wholeBox().writer();
    var i: c_int = 0;
    window.wrap = true;
    while (i < ncurses.COLORS) : (i += 1) {
        try ncurses.initPair(3 + i, i, -1);
        window.attrSet(ncurses.attributes.colorPair(3 + i)) catch {};
        writer.print("{} ", .{i}) catch {};
    }
    const input = window.getChar() catch null;
}

pub fn runInteractiveImport(
    db: *const sqlite.Database,
    data: *import.PreparedImport,
    allocator: *std.mem.Allocator,
    account_id: i64,
) !usize {
    try log.openLogfile();
    defer log.closeLogfile();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var window = try ncurses.Window.init();
    defer ncurses.end();
    try initNcurses(&window);

    var screen = try Screen.init(db, data, allocator, account_id);

    defer screen.deinit();
    if (try screen.render(&window.wholeBox(), null)) |result| return result;

    while (true) {
        const input = window.getChar() catch null;

        if (input) |i| switch (i) {
            .control => |control| switch (control) {
                ncurses.key.resize => {
                    window.erase() catch {};
                    try ncurses.refresh();
                },
                else => {},
            },
            else => {},
        };
        window.erase() catch {};

        if (try screen.render(&window.wholeBox(), input)) |result| return result;
        if (input != null) {
            window.erase() catch {};
            if (try screen.render(&window.wholeBox(), null)) |result| return result;
        }
        try window.refresh();
    }
}
