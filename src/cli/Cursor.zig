const ncurses = @import("ncurses.zig");

start: usize = 0,
escape: bool = false,

pub fn getResultOfInput(self: @This(), input: ncurses.Key, text: anytype) ?@This() {
    assertIsText(@TypeOf(text));
    return switch (input) {
        .control => |control| switch (control) {
            ncurses.key.left => if (self.start > 0)
                @This(){ .start = self.start - 1 }
            else
                @This(){ .start = self.start },
            ncurses.key.right => if (self.start < text.len)
                @This(){ .start = self.start + 1 }
            else
                @This(){ .start = self.start },
            ncurses.key.home => @This(){
                .start = 0,
            },
            ncurses.key.end_key => @This(){
                .start = text.len,
            },
            else => null,
        },
        .char => |char| if (self.escape) switch (char) {
            'f' => blk: {
                var start = self.start;
                var found_text = false;
                while (start < text.len) : (start += 1) {
                    if (text[start] == ' ' and found_text) break;
                    if (text[start] != ' ') found_text = true;
                }
                break :blk @This(){ .start = start };
            },
            'b' => blk: {
                var start = self.start;
                var found_text = false;
                while (start > 0 and text.len > 0) : (start -= 1) {
                    if (text[start - 1] == ' ' and found_text) break;
                    if (text[start - 1] != ' ') found_text = true;
                }
                break :blk @This(){ .start = start };
            },
            else => null,
        } else switch (char) {
            0x01 => @This(){ .start = 0 },
            0x05 => @This(){ .start = text.len },
            0x1B => @This(){ .start = self.start, .escape = true },
            else => null,
        },
    };
}

fn assertIsText(comptime Type: type) void {
    const err = "Expected a slice of 8-bit-or-larger unsigned integers, found: " ++ @typeName(Type);
    const info = @typeInfo(Type);
    if (info != .Pointer) @compileError(err);
    if (info.Pointer.size != .Slice) @compileError(err);
    const child_info = @typeInfo(info.Pointer.child);
    if (child_info != .Int) @compileError(err);
    if (child_info.Int.is_signed) @compileError(err);
    if (child_info.Int.bits < 8) @compileError(err);
}
