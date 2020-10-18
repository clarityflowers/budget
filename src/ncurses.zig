const c = @cImport({
    @cInclude("ncurses.h");
});
const std = @import("std");
const io = std.io;

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

    pub const WriteError = error{NCursesPrintFailed};
    pub const Writer = io.Writer(@This(), WriteError, write);

    pub fn writer(self: @This()) Writer {
        return Writer{ .context = self };
    }

    fn write(self: @This(), str: []const u8) WriteError!usize {
        if (c.wprintw(self.ptr, @intToPtr([*c]u8, @ptrToInt(str.ptr))) == c.ERR) return WriteError.NCursesPrintFailed;
        return str.len;
    }
};

pub const stdscr = Window{ .ptr = c.strscr };

pub fn intrflush(
    window: *c.WINDOW,
) !void {
    try check(c.intrflush());
}
