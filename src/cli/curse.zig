const ncurses = @import("ncurses.zig");
const c = @import("../c.zig");

pub fn init(window: *ncurses.Window) !void {
    try ncurses.startColor();
    try ncurses.raw();
    try ncurses.noecho();
    _ = c.setlocale(c.LC_ALL, "en_US.UTF-8");
    try ncurses.nonl();
    try ncurses.useDefaultColors();
    window.cursor = .invisible;
    try initColors();
    try window.keypad(true);
    try window.intrflush(true);
    try window.refresh();
    try window.scrollOkay(false);
}

pub fn attr(attribute: enum {
    highlight,
    attention,
    attention_highlight,
    dim,
    err,
}) c_int {
    return switch (attribute) {
        .attention => ncurses.attributes.colorPair(1) | ncurses.attributes.bold,
        .attention_highlight => ncurses.attributes.colorPair(2),
        .highlight => ncurses.attributes.colorPair(3),
        .dim => ncurses.attributes.colorPair(4),
        .err => ncurses.attributes.colorPair(5),
    };
}

pub fn initColors() !void {
    try ncurses.initPair(1, 6, -1);
    try ncurses.initPair(2, 0, 6);
    try ncurses.initPair(3, 0, 7);
    try ncurses.initPair(4, 8, -1);
    try ncurses.initPair(5, 1, -1);
}
