const c = @import("../c.zig");
const std = @import("std");
const io = std.io;
const log = std.log.scoped(.ncurses);
pub var COLORS: @TypeOf(c.COLORS) = undefined;

pub const Key = union(enum) {
    control: c_int, char: u21
};

fn check(val: c_int) !void {
    if (val == c.ERR) {
        return error.NCursesError;
    }
}

/// Normally, the tty driver buffers typed characters until a newline or car-
/// riage return is typed.  The cbreak routine disables  line  buffering  and
/// erase/kill  character-processing  (interrupt  and flow control characters
/// are unaffected), making characters typed by the user  immediately  avail-
/// able to the program.  The nocbreak routine returns the terminal to normal
/// (cooked) mode.
///
/// Initially the terminal may or may not be in cbreak mode, as the  mode  is
/// inherited;  therefore, a program should call cbreak or nocbreak explicit-
/// ly.  Most interactive programs using curses set the  cbreak  mode.   Note
/// that  cbreak  overrides raw.  [See curs_getch(3X) for a discussion of how
/// these routines interact with echo and noecho.]
pub fn cbreak() !void {
    try check(c.cbreak());
}

/// The  raw  and noraw routines place the terminal into or out of raw
/// mode.  Raw mode is similar to  cbreak  mode,  in  that  characters
/// typed  are  immediately  passed  through to the user program.  The
/// differences are that in raw mode, the  interrupt,  quit,  suspend,
/// and  flow control characters are all passed through uninterpreted,
/// instead of generating a signal.  The behavior of the BREAK key de-
/// pends  on other bits in the tty driver that are not set by curses.
pub fn raw() !void {
    try check(c.raw());
}

/// The echo and noecho routines control whether characters typed by the user
/// are  echoed by getch as they are typed.  Echoing by the tty driver is al-
/// ways disabled, but initially getch is in echo mode, so  characters  typed
/// are  echoed.  Authors of most interactive programs prefer to do their own
/// echoing in a controlled area of the screen, or not to  echo  at  all,  so
/// they  disable  echoing by calling noecho.  [See curs_getch(3X) for a dis-
/// cussion of how these routines interact with cbreak and nocbreak.]
pub fn noecho() !void {
    try check(c.noecho());
}
pub fn nonl() !void {
    try check(c.nonl());
}

pub fn startColor() !void {
    try check(c.start_color());
    COLORS = c.COLORS;
}

pub fn useDefaultColors() !void {
    try check(c.use_default_colors());
}
pub fn assumeDefaultColors(fg: c_int, bg: c_int) !void {
    try check(c.assume_default_colors(fg, bg));
}
pub fn initPair(pair: c_int, foreground: c_int, background: c_int) !void {
    try check(c.init_extended_pair(pair, foreground, background));
}
pub fn initColor(color: c_short, r: c_short, g: c_short, b: c_short) !void {
    try check(c.init_color(color, r, g, b));
}
pub fn canChangeColor() bool {
    return c.can_change_color();
}
pub const CursorState = enum { invisible, normal, very_visible };
pub fn setCursor(value: CursorState) !void {
    try check(c.curs_set(@enumToInt(value)));
}
pub fn getColorAttr(color: c_int) c_int {
    return c.COLOR_PAIR(color);
}

pub fn end() void {
    _ = c.endwin();
}
pub fn isEnd() bool {
    return c.isendwin();
}

pub const attributes = struct {
    pub const normal = @intCast(c_int, c.A_NORMAl);
    pub const standout = c.A_STANDOUT;
    pub const underline = c.A_UNDERLINE;
    pub const reverse = c.A_REVERSE;
    pub const blink = c.A_BLINK;
    pub const dim = c.A_DIM;
    pub const bold = @intCast(c_int, c.A_BOLD);
    pub const protect = c.A_PROTECT;
    pub const invis = c.A_INVIS;
    pub const altcharset = c.A_ALTCHARSET;
    pub inline fn colorPair(n: c_int) c_int {
        return c.COLOR_PAIR(n);
    }
};
pub fn getAcs(char: u8) c_uint {
    if (c.acs_map != 0) {
        return c.acs_map[char];
    }
    return 0;
}
pub const acs = struct {
    pub const ulcorner = 'l';
    pub const llcorner = 'm';
    pub const urcorner = 'k';
    pub const lrcorner = 'j';
    pub const ltee = 't';
    pub const rtee = 'u';
    pub const btee = 'v';
    pub const ttee = 'w';
    pub const hline = 'q';
    pub const vline = 'x';
    pub const plus = 'n';
    pub const s1 = 'o';
    pub const s9 = 's';
    pub const diamond = '`';
    pub const ckboard = 'a';
    pub const degree = 'f';
    pub const plminus = 'g';
    pub const bullet = '~';
    pub const larrow = ',';
    pub const rarrow = '+';
    pub const darrow = '.';
    pub const uarrow = '-';
    pub const board = 'h';
    pub const lantern = 'i';
    pub const block = '0';
    pub const s3 = 'p';
    pub const s7 = 'r';
    pub const lequal = 'y';
    pub const gequal = 'z';
    pub const pi = '{';
    pub const nequal = '|';
    pub const sterling = '}';
};
pub const drawing = struct {
    pub const block = c.ACS_BLOCK;
    pub const board = c.ACS_BOARD;
    pub const btee = c.ACS_BTEE;
    pub const bullet = c.ACS_BULLET;
    pub const ckboard = c.ACS_CKBOARD;
    pub const darrow = c.ACS_DARROW;
    pub const degree = c.ACS_DEGREE;
    pub const diamond = c.ACS_DIAMOND;
    pub const gequal = c.ACS_GEQUAL;
    pub const hline = c.ACS_HLINE;
    pub const lantern = c.ACS_LANTERN;
    pub const larrow = c.ACS_LARROW;
    pub const lequal = c.ACS_LEQUAL;
    pub const llcorner = c.ACS_LLCORNER;
    pub const lrcorner = c.ACS_LRCORNER;
    pub const ltee = c.ACS_LTEE;
    pub const nequal = c.ACS_NEQUAL;
    pub const pi = c.ACS_PI;
    pub const plminus = c.ACS_PLMINUS;
    pub const plus = c.ACS_PLUS;
    pub const rarrow = c.ACS_RARROW;
    pub const rtee = c.ACS_RTEE;
    pub const s1 = c.ACS_S1;
    pub const s3 = c.ACS_S3;
    pub const s7 = c.ACS_S7;
    pub const s9 = c.ACS_S9;
    pub const sterling = c.ACS_STERLING;
    pub const ttee = c.ACS_TTEE;
    pub const uarrow = c.ACS_UARROW;
    pub const ulcorner = c.ACS_ULCORNER;
    pub const urcorner = c.ACS_URCORNER;
    pub const vline = c.ACS_VLINE;
};
pub const ControlKey = enum(u64) {
    brk, down, up, left, right, home, enter, btab, unknown, dc
};
pub const key = struct {
    pub const brk = c.KEY_BREAK;
    pub const down = c.KEY_DOWN;
    pub const up = c.KEY_UP;
    pub const left = c.KEY_LEFT;
    pub const right = c.KEY_RIGHT;
    pub const home = c.KEY_HOME;
    pub const backspace = c.KEY_BACKSPACE;
    pub const f0 = c.KEY_F(0);
    pub const f1 = c.KEY_F(1);
    pub const f2 = c.KEY_F(2);
    pub const f3 = c.KEY_F(3);
    pub const f4 = c.KEY_F(4);
    pub const f5 = c.KEY_F(5);
    pub const f6 = c.KEY_F(6);
    pub const f7 = c.KEY_F(7);
    pub const f8 = c.KEY_F(8);
    pub const f9 = c.KEY_F(9);
    pub const f10 = c.KEY_F(10);
    pub const f11 = c.KEY_F(11);
    pub const f12 = c.KEY_F(12);
    pub const dl = c.KEY_DL;
    pub const il = c.KEY_IL;
    pub const dc = c.KEY_DC;
    pub const ic = c.KEY_IC;
    pub const eic = c.KEY_EIC;
    pub const clear = c.KEY_CLEAR;
    pub const eos = c.KEY_EOS;
    pub const eol = c.KEY_EOL;
    pub const sf = c.KEY_SF;
    pub const sr = c.KEY_SR;
    pub const npage = c.KEY_NPAGE;
    pub const ppage = c.KEY_PPAGE;
    pub const stab = c.KEY_STAB;
    pub const ctab = c.KEY_CTAB;
    pub const catab = c.KEY_CATAB;
    pub const enter = c.KEY_ENTER;
    pub const sreset = c.KEY_SRESET;
    pub const reset = c.KEY_RESET;
    pub const print = c.KEY_PRINT;
    pub const ll = c.KEY_LL;
    pub const a1 = c.KEY_A1;
    pub const a3 = c.KEY_A3;
    pub const b2 = c.KEY_B2;
    pub const c1 = c.KEY_C1;
    pub const c3 = c.KEY_C3;
    pub const btab = c.KEY_BTAB;
    pub const beg = c.KEY_BEG;
    pub const cancel = c.KEY_CANCEL;
    pub const close = c.KEY_CLOSE;
    pub const command = c.KEY_COMMAND;
    pub const copy = c.KEY_COPY;
    pub const create = c.KEY_CREATE;
    pub const end_key = c.KEY_END;
    pub const exit = c.KEY_EXIT;
    pub const find = c.KEY_FIND;
    pub const help = c.KEY_HELP;
    pub const mark = c.KEY_MARK;
    pub const message = c.KEY_MESSAGE;
    pub const mouse = c.KEY_MOUSE;
    pub const move = c.KEY_MOVE;
    pub const next = c.KEY_NEXT;
    pub const open = c.KEY_OPEN;
    pub const options = c.KEY_OPTIONS;
    pub const previous = c.KEY_PREVIOUS;
    pub const redo = c.KEY_REDO;
    pub const reference = c.KEY_REFERENCE;
    pub const refresh = c.KEY_REFRESH;
    pub const replace = c.KEY_REPLACE;
    pub const resize = c.KEY_RESIZE;
    pub const restart = c.KEY_RESTART;
    pub const res = c.KEY_RESUME;
    pub const save = c.KEY_SAVE;
    pub const sbeg = c.KEY_SBEG;
    pub const scancel = c.KEY_SCANCEL;
    pub const scommand = c.KEY_SCOMMAND;
    pub const scopy = c.KEY_SCOPY;
    pub const screate = c.KEY_SCREATE;
    pub const sdc = c.KEY_SDC;
    pub const sdl = c.KEY_SDL;
    pub const select = c.KEY_SELECT;
    pub const send = c.KEY_SEND;
    pub const seol = c.KEY_SEOL;
    pub const sexit = c.KEY_SEXIT;
    pub const sfind = c.KEY_SFIND;
    pub const shelp = c.KEY_SHELP;
    pub const shome = c.KEY_SHOME;
    pub const sic = c.KEY_SIC;
    pub const sleft = c.KEY_SLEFT;
    pub const smessage = c.KEY_SMESSAGE;
    pub const smove = c.KEY_SMOVE;
    pub const snext = c.KEY_SNEXT;
    pub const soptions = c.KEY_SOPTIONS;
    pub const sprevious = c.KEY_SPREVIOUS;
    pub const sprint = c.KEY_SPRINT;
    pub const sredo = c.KEY_SREDO;
    pub const sreplace = c.KEY_SREPLACE;
    pub const sright = c.KEY_SRIGHT;
    pub const srsume = c.KEY_SRSUME;
    pub const ssave = c.KEY_SSAVE;
    pub const ssuspend = c.KEY_SSUSPEND;
    pub const sundo = c.KEY_SUNDO;
    pub const sus = c.KEY_SUSPEND;
    pub const undo = c.KEY_UNDO;
};

pub const Window = struct {
    ptr: *c.WINDOW,
    out_of_bounds: bool = false,
    wrap: bool = false,
    cursor: CursorState = .normal,

    pub fn init() !@This() {
        if (c.initscr()) |ptr| {
            return @This(){ .ptr = ptr };
        } else {
            return error.NCursesError;
        }
    }

    /// The  keypad option enables the keypad of the user's terminal.  If enabled
    /// (bf is TRUE), the user can press a function key (such as  an  arrow  key)
    /// and  wgetch  returns  a single value representing the function key, as in
    /// KEY_LEFT.  If disabled (bf is FALSE), curses does not treat function keys
    /// specially  and  the program has to interpret the escape sequences itself.
    /// If the keypad in the terminal can be turned on (made to transmit) and off
    /// (made to work locally), turning on this option causes the terminal keypad
    /// to be turned on when wgetch is called.  The default value for  keypad  is
    /// false.
    pub fn keypad(self: @This(), bf: bool) !void {
        try check(c.keypad(self.ptr, bf));
    }

    pub const WriteError = error{ NCursesError, InvalidUtf8 };
    pub const Writer = io.Writer(*@This(), WriteError, write);

    pub fn writer(self: *@This()) Writer {
        return Writer{ .context = self };
    }

    const elipses: [4]c_int = [4]c_int{ '.', '.', '.', 0 };

    fn write(self: *@This(), str: []const u8) WriteError!usize {
        if (self.out_of_bounds) return str.len;
        var view = try std.unicode.Utf8View.init(str);
        var it = view.iterator();
        while (it.nextCodepoint()) |codepoint| {
            if (!self.wrap) {
                if (self.getx() >= self.getMaxPosition().column - 3) {
                    while (self.getx() != 0) {
                        try check(c.addwstr(&[_]c_int{'.'}));
                    }
                    break;
                }
            }
            const as_c_int: [2]c_int = .{ codepoint, 0 };
            try check(c.addwstr(
                @ptrCast([*c]const c_int, &as_c_int),
            ));
        }
        return str.len;
    }

    pub fn writeCodepoint(self: @This(), codepoint: c_uint) WriteError!void {
        try check(c.waddnwstr(
            self.ptr,
            @ptrCast([*c]const c_int, &codepoint),
            1,
        ));
    }

    pub fn writeCodepoints(self: @This(), codepoints: []const u21) WriteError!void {
        for (codepoints) |codepoint| {
            try self.writeCodepoint(codepoint);
        }
    }

    pub fn fillLine(self: @This(), codepoint: c_uint) WriteError!void {
        try self.writeCodepoint(codepoint);
        while (self.getx() != 0) {
            try self.writeCodepoint(codepoint);
        }
    }

    pub fn move(self: *@This(), position: Position) void {
        var new_position = position;
        while (new_position.column >= self.getMaxPosition().column) {
            new_position.column -= self.getMaxPosition().column;
            new_position.line += 1;
        }
        check(c.wmove(self.ptr, @intCast(c_int, new_position.line), @intCast(c_int, new_position.column))) catch {
            self.out_of_bounds = true;
        };
    }

    pub fn moveX(self: @This(), x: i32) void {
        check(c.wmovex(self.ptr, x)) catch {
            self.out_of_bounds = true;
        };
    }

    /// If  the  intrflush option is enabled, (bf is TRUE), when an interrupt key
    /// is pressed on the keyboard (interrupt, break, quit) all output in the tty
    /// driver queue will be flushed, giving the effect of faster response to the
    /// interrupt, but causing curses to have the wrong idea of what  is  on  the
    /// screen.  Disabling (bf is FALSE), the option prevents the flush.  The de-
    /// fault for the option is inherited from the tty driver settings.  The win-
    /// dow argument is ignored.
    pub fn intrflush(self: @This(), bf: bool) !void {
        try check(c.intrflush(self.ptr, bf));
    }

    pub fn refresh(self: @This()) !void {
        try check(c.wrefresh(self.ptr));
        try setCursor(self.cursor);
    }

    pub inline fn getx(self: @This()) usize {
        return @intCast(usize, c.getcurx(self.ptr));
    }
    pub inline fn gety(self: @This()) usize {
        return @intCast(usize, c.getcury(self.ptr));
    }
    pub inline fn getPosition(self: @This()) Position {
        return Position{
            .line = self.gety(),
            .column = self.getx(),
        };
    }

    pub const Position = struct {
        column: usize = 0,
        line: usize = 0,
    };
    pub inline fn getMaxPosition(self: @This()) Position {
        return .{
            .column = @intCast(usize, c.getmaxx(self.ptr)),
            .line = @intCast(usize, c.getmaxy(self.ptr)),
        };
    }
    pub fn attrSet(self: @This(), attr: c_int) !void {
        try check(c.wattrset(self.ptr, attr));
    }
    pub fn getChar(self: @This()) !Key {
        var wide_char: c_int = undefined;
        const result = c.wget_wch(self.ptr, &wide_char);
        try check(result);

        if (result == c.KEY_CODE_YES) {
            return Key{
                .control = wide_char,
            };
        } else {
            return Key{ .char = @truncate(u21, std.math.absCast(wide_char)) };
        }
    }

    pub fn erase(self: @This()) !void {
        try check(c.werase(self.ptr));
    }

    pub fn nodelay(self: @This(), value: bool) !void {
        try check(c.nodelay(self.ptr, value));
    }

    /// The scrollok option controls what happens when the cursor of  a  window
    /// is  moved  off  the edge of the window or scrolling region, either as a
    /// result of a newline action on the bottom line, or typing the last char-
    /// acter of the last line.  If disabled, (bf is FALSE), the cursor is left
    /// on the bottom line.  If enabled, (bf is TRUE), the window  is  scrolled
    /// up one line (Note that to get the physical scrolling effect on the ter-
    /// minal, it is also necessary to call idlok).
    pub fn scrollOkay(self: @This(), value: bool) !void {
        try check(c.scrollok(self.ptr, value));
    }
};

pub fn getStdScreen() ?Window {
    return Window{
        .ptr = c.stdscr orelse return null,
    };
}
