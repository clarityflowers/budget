const std = @import("std");
const sqlite = @import("../sqlite-zig/src/sqlite.zig");
const ncurses = @import("ncurses.zig");
const initNcurses = @import("curse.zig").init;
const Screen = @import("budget_Screen.zig");
const log = @import("../log.zig");

pub fn run(db: *const sqlite.Database, allocator: *std.mem.Allocator) !void {
    try log.openLogfile();
    defer log.closeLogfile();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var window = try ncurses.Window.init();
    defer ncurses.end();
    try initNcurses(&window);

    var screen = Screen.init(&arena.allocator);
    defer screen.deinit();

    if (try screen.render(&window.wholeBox(), null)) return;

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

        if (try screen.render(&window.wholeBox(), input)) return;
        if (input != null) {
            window.erase() catch {};
            if (try screen.render(&window.wholeBox(), null)) return;
        }
        try window.refresh();
    }
}
