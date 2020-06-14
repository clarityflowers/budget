const c = @cImport({
    @cInclude("ncurses.h");
});

fn check(val: c_int) !void {
    if (val == c.ERR) return error.NCursesError;
}

pub fn cbreak() !void {
    try check(c.cbreak());
}
pub fn noecho() !void {
    try check(c.noecho());
}

pub fn nonl() !void {
    try check(c.nonl());
}

pub const Window = struct {
    ptr: *c.WINDOW,

    pub fn initscr() !@This() {
        if (c.initscr()) |ptr| {
            return @This(){ .ptr = ptr };
        } else {
            return error.NcursesError;
        }
    }

    pub fn intrflush(self: @This(), bf: bool) !void {
        try check(c.intrflush(self.ptr, bf));
    }

    pub fn keypad(self: @This(), bf: bool) !void {
        try check(c.keypad(self.ptr, bf));
    }
};

pub const stdscr = Window{ .ptr = c.strscr };

pub fn intrflush(
    window: *c.WINDOW,
) !void {
    try check(c.intrflush());
}
