const ncurses = @import("ncurses.zig");
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
