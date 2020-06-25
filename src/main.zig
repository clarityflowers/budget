const std = @import("std");
const io = std.io;
const process = std.process;
const heap = std.heap;
const mem = std.mem;
const zig_args = @import("zig-args/args.zig");

const ArgIterator = process.ArgIterator;
const Allocator = mem.Allocator;
const ArenaAllocator = heap.ArenaAllocator;

comptime {
    if (std.builtin.is_test) {
        _ = @import("html_parser.zig");
    }
}

pub fn main() !void {
    @import("parser.zig").testQuotedString();
}

pub fn main2() !void {
    var arena = ArenaAllocator.init(heap.page_allocator);
    defer arena.deinit();
    const allocator = &arena.allocator;

    const out_stream = &io.getStdOut().outStream();

    const arg_iterator = &(try ArgIterator.initWithAllocator(allocator));

    if (!arg_iterator.skip()) return help(out_stream);

    if (arg_iterator.next(allocator)) |maybe_arg| {
        if (maybe_arg) |arg| {
            defer allocator.free(arg);
            if (mem.eql(u8, arg, "import")) {
                return import(out_stream, allocator, arg_iterator);
            }
        } else |err| {
            return err;
        }
    } else {
        return help(out_stream);
    }
}

pub fn importHelp(out_stream: var) !void {
    _ = try stream.write(
        \\Imports an external transaction file into a transaction log
    );
}

pub fn ParseResult(comptime Spec: type) type {
    return struct {
        exe: []const u8,
        options: Spec,
        positionals: []const []const u8,
        allocator: *Allocator,
        out_stream: Stream,
    };
}

const builtin = std.builtin;
const TypeInfo = builtin.TypeInfo;

pub fn getStringDecl(comptime Spec: type, comptime name: []const u8) ?[]const u8 {
    if (!@hasDecl(Spec, name)) return null;
    if (@TypeOf(@field(Spec, name)) != []const u8) {
        @compileError("'" ++ name ++ "' must be of type []const u8");
    }
    return @field(Spec, name);
}

pub fn assertIsString(decl: var) void {
    if (@TypeOf(decl) != []const u8) {
        @compileError("Usage must be a string");
    }
}

inline fn printWithExe(comptime str: []const u8, exe: []const u8, stream: var) !void {
    comptime var start: usize = 0;
    comptime var match: usize = 0;

    inline for (str) |char, i| {
        if (match == 0 and char == '{') {
            match += 1;
        } else if (match == 1 and char == '0') {
            match += 1;
        } else if (match == 2 and char == '}') {
            _ = try stream.write(str[start .. i - 2]);
            _ = try stream.write(exe);
            start = i + 1;
        } else if (match > 0) {
            match = 0;
        }
    }
    if (start < str.len) {
        _ = try stream.write(str[start..]);
    }
}

const testing = std.testing;
const expectEqualSlices = testing.expectEqualSlices;
const expect = testing.expect;
const expectEqual = testing.expectEqual;

test "printWithExe" {
    const expected = "Usage: test <command> [args]";
    var buf: [expected.len]u8 = undefined;
    const stream = &io.fixedBufferStream(buf[0..]).outStream();
    try printWithExe("Usage: {0} <command> [args]", "test", stream);
    expectEqualSlices(u8, expected, buf[0..]);
}

pub fn help(comptime Spec: type, exe: []const u8, stream: var) !void {
    if (@typeInfo(Spec) != .Struct)
        return {
            @compileError("Argument spec must be a struct.");
        };
    comptime var script_name = exe;
    if (@hasDecl(Spec, "script_name")) |name| {
        script_name = name;
    }
    if (@hasDecl(Spec, "usage")) {
        try printWithExe(usage, script_name);
    }
}

const Styles = struct {
    const Reset = "0";
    const Bold = "1";
};
pub fn termStyle(comptime styles: var) []const u8 {
    comptime var res: []const u8 = "\x1B[";
    inline for (styles) |style| {
        res = res ++ style ++ ";";
    }
    return res[0 .. res.len - 1] ++ "m";
}

pub fn tstste() !void {
    try parse(struct {
        pub const Commands = union(enum) {
            import: ImportArgs
        };

        pub const usage = "usage: {0} [command] [options]";
    });
}

pub const ImportArgs = struct {
    account: ?[]const u8 = null,

    pub fn main(args: @This()) !void {}
};

pub fn import(out_stream: var, allocator: *Allocator, args: *ArgIterator) !void {
    const options = try zig_args.parse(struct {
        help: bool = false,
        account: ?[]const u8 = null,

        pub const shorthands = .{ .a = "account" };
    }, args, allocator);
    args.deinit();

    for (options.positionals) |arg, i| {
        try out_stream.print("positional {}: {}\n", .{ i, arg });
    }
    if (options.options.help) {
        _ = try out_stream.write("Help mode\n");
    }
}
