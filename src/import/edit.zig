pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = &gpa.allocator;

    const screen = try ncurses.Window.initscr();
    try ncurses.cbreak();
    try ncurses.noecho();
    try ncurses.nonl();
    try ncurses.startColor();
    try ncurses.useDefaultColors();
    try screen.intrflush(false);
    try screen.keypad(true);
    window.cursor = .invisible;

    const writer = screen.writer();
    try writer.print("({}, {}) ", .{ screen.getx(), screen.gety() });
    try screen.attrSet(ncurses.attributes.bold);
    try writer.print("({}, {}) ", .{ screen.getx(), screen.gety() });
    while (true) {
        const character = try screen.getChar();
        if (character < 128) {
            try screen.move(2, 0);
            try writer.writeByte(@intCast(u8, character));
        }
        try screen.refresh();
    }
}
