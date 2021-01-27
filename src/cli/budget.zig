const sqlite = @import("../sqlite-zig/src/main.zig");
const ncurses = @import("ncurses.zig");

const initNcurses = @import("init_ncurses.zig").init;
pub fn run(db: *const )