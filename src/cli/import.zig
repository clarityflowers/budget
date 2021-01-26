const std = @import("std");
const import = @import("../import.zig");
const sqlite = @import("../sqlite-zig/src/sqlite.zig");
const log = @import("../log.zig");
const c = @import("../c.zig");
const Screen = @import("import_Screen.zig");
const ncurses = @import("ncurses.zig");
const attributes = @import("attributes.zig");

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
    try ncurses.startColor();
    try ncurses.raw();
    try ncurses.noecho();
    // try window.nodelay(true);
    _ = c.setlocale(c.LC_ALL, "en_US.UTF-8");
    try ncurses.nonl();
    try ncurses.useDefaultColors();
    window.cursor = .invisible;
    try attributes.initColors();
    try window.keypad(true);
    try window.intrflush(true);
    try window.refresh();
    try window.scrollOkay(false);
    const writer = window.wholeBox().writer();
    // var i: c_int = 0;
    // window.wrap = true;
    // while (i < ncurses.COLORS) : (i += 1) {
    //     try ncurses.initPair(3 + i, i, -1);
    //     window.attrSet(ncurses.attributes.colorPair(3 + i)) catch {};
    //     writer.print("{} ", .{i}) catch {};
    // }
    // while (true) {
    //     const input = window.getChar() catch null;
    //     if (input != null) return;
    //     std.time.sleep(1000);
    // }

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
