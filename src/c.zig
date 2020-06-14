pub const c = @cImport({
    @cInclude("c.h");
    @cInclude("ncurses.h");
});

pub fn initscr() void {
    _ = c.initscr();
}

pub fn endwin() void {
    _ = c.endwin();
}

pub fn noecho() void {
    _ = c.noecho();
}

pub fn keypad(b: bool) void {
    _ = c.keypad(c.stdscr, b);
}

pub fn curs_set(visible: bool) void {
    if (visible) _ = c.curs_set(1) else _ = c.curs_set(0);
}

pub fn refresh() void {
    _ = c.refresh();
}

pub fn clear() void {
    _ = c.clear();
}

pub fn getmaxyx(rows: *i32, cols: *i32) void {
    rows.* = c.getmaxy(c.stdscr);
    cols.* = c.getmaxx(c.stdscr);
}

pub fn mvprintw(row: i32, col: i32, fmt: [*]const u8, args: var) void {
    _ = @call(.{}, c.mvprintw, .{ row, col, fmt } ++ args);
}
