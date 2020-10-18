const std = @import("std");
const io = std.io;
const process = std.process;
const heap = std.heap;
const mem = std.mem;
const zig_args = @import("zig-args/args.zig");

const BufSet = std.BufSet;
const ArrayList = std.ArrayList;

const ArgIterator = process.ArgIterator;
const Allocator = mem.Allocator;
const ArenaAllocator = heap.ArenaAllocator;
const OutStream = io.OutStream;

const testing = std.testing;
const expect = testing.expect;
const expectEqual = testing.expectEqual;
const expectEqualStrings = testing.expectEqualStrings;
const expectError = testing.expectError;

pub fn ParseArgsResult(comptime Spec: type) type {
    return struct {
        arena: ArenaAllocator,
        options: Spec,
        positionals: []const []const u8,
        exe_name: []const u8,

        pub fn deinit(self: *@This()) void {
            arena.deinit();
        }
    };
}

fn InternalParseArgsResult(comptime Spec: type) type {
    return struct {
        options: Spec, positionals: []const []const u8
    };
}

pub const TestArgIterator = struct {
    args: []const []const u8,
    index: usize = 0,

    pub fn next(self: *@This(), allocator: *Allocator) ?(ArgIterator.NextError![]const u8) {
        if (self.index < self.args.len) {
            defer self.index += 1;
            return self.args[self.index];
        }
        return null;
    }
};

fn runMainFn(result: var, positionals: []const []const u8, arena: ArenaAllocator, exe_name: []const u8, context: var) !void {
    const Spec = @TypeOf(result);
    if (@typeInfo(Spec) == .Union) {
        const tagName = @tagName(result);
        inline for (@typeInfo(Spec).Union.fields) |fld| {
            if (mem.eql(u8, tagName, fld.name)) {
                try runMainFn(@field(result, fld.name), positionals, arena, exe_name, context);
                return;
            }
        }
        unreachable;
    }
    if (@hasDecl(Spec, "exec")) {
        const exec_info = @typeInfo(@TypeOf(Spec.exec));
        const err = "Expected exec fn to be \"fn (" ++ @typeName(ParseArgsResult(Spec)) ++ ", " ++ @typeName(@TypeOf(context)) ++ ") !void\", found: \"" ++ @typeName(@TypeOf(Spec.exec)) ++ "\".";
        if (exec_info != .Fn) @compileError(err);
        if (exec_info.Fn.args.len != 2) @compileError(err);
        if (exec_info.Fn.args[0].arg_type != ParseArgsResult(Spec)) @compileError(err);
        if (exec_info.Fn.args[1].arg_type != @TypeOf(context)) @compileError(err);
        if (exec_info.Fn.return_type == null) @compileError(err);
        const return_info = @typeInfo(exec_info.Fn.return_type.?);
        if (return_info != .ErrorUnion) @compileError(err);
        if (return_info.ErrorUnion.payload != void) @compileError(err);
        try Spec.exec(ParseArgsResult(Spec){
            .arena = arena,
            .options = result,
            .positionals = positionals,
            .exe_name = exe_name,
        }, context);
    }
}

pub fn parseAndRun(comptime Spec: type, iterator: var, allocator: *Allocator, err_stream: var, context: var) !void {
    const result = try parseWithGivenArgs(Spec, iterator, allocator, err_stream);
    try runMainFn(result.options, result.positionals, result.arena, result.exe_name, context);
}

pub fn parseWithGivenArgs(comptime Spec: type, iterator: var, allocator: *Allocator, err_stream: var) !ParseArgsResult(Spec) {
    var arena = ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    var exe_name: []const u8 = try (iterator.next(&arena.allocator) orelse return error.EmptyArgsIterator);
    const result = try parseInternal(Spec, iterator, &arena.allocator, err_stream);
    return ParseArgsResult(Spec){
        .arena = arena,
        .options = result.options,
        .positionals = result.positionals,
        .exe_name = exe_name,
    };
}

fn parseInternal(comptime Spec: type, args: var, allocator: *Allocator, err_stream: var) !InternalParseArgsResult(Spec) {
    if (@TypeOf(args) != *ArgIterator and @TypeOf(args) != *TestArgIterator) {
        @compileError("expected type '" ++ @typeName(*ArgIterator) ++ "' or '" ++ @typeName(*TestArgIterator) ++ "', found '" ++ @typeName(@TypeOf(args)) ++ "'.");
    }
    const spec_info = @typeInfo(Spec);
    switch (spec_info) {
        .Union => |union_spec| {
            if (union_spec.tag_type == null) {
                @compileError("Union specs must be tagged.");
            }
            const command = try (args.next(allocator) orelse {
                _ = try err_stream.write("Missing command, expected one of: " ++ joinFieldNames(union_spec.fields, ", ") ++ ".");
                return error.MissingCommand;
            });
            inline for (union_spec.fields) |field| {
                if (mem.eql(u8, field.name, command)) {
                    const command_result = try parseInternal(field.field_type, args, allocator, err_stream);
                    return InternalParseArgsResult(Spec){
                        .options = @unionInit(Spec, field.name, command_result.options),
                        .positionals = command_result.positionals,
                    };
                }
            }
            try err_stream.print("Unexpected command {}, expected one of: " ++ joinFieldNames(union_spec.fields, ", ") ++ ".", .{command});
            return error.UnexpectedCommand;
        },
        .Struct => |struct_spec| {
            var positionals = &ArrayList([]const u8).init(allocator);
            var options: Spec = undefined;

            const options_consumed = &BufSet.init(allocator);

            while (args.next(allocator)) |arg_or_error| {
                const arg = try arg_or_error;

                if (mem.eql(u8, arg, "--")) break; // all args after -- are considered positional
                if (mem.startsWith(u8, arg, "--")) {
                    const KV = struct {
                        name: []const u8,
                        value: ?[]const u8,
                    };

                    const kv = if (std.mem.indexOf(u8, arg, "=")) |index|
                        KV{
                            .name = arg[2..index],
                            .value = arg[index + 1 ..],
                        }
                    else
                        KV{
                            .name = arg[2..],
                            .value = null,
                        };

                    var found = found_blk: inline for (struct_spec.fields) |fld| {
                        if (std.mem.eql(u8, kv.name, fld.name)) {
                            @field(options, fld.name) = try parseOption(Spec, &options, args, fld.name, kv.value, allocator, err_stream);
                            try options_consumed.put(fld.name);
                            break :found_blk true;
                        }
                    } else false;

                    if (!found) {
                        try err_stream.print("Unknown option: {}\n", .{kv.name});
                        return error.UnknownOption;
                    }
                } else {
                    try positionals.append(arg);
                }
            }

            inline for (@typeInfo(Spec).Struct.fields) |fld| {
                if (mem.startsWith(u8, fld.name, "_")) {
                    // continue
                } else if (fld.field_type == bool and fld.default_value == true) {
                    @compileError("Error with option \"" ++ fld.name ++ "\": booleans cannot default to true. Instead try inverting your option (for example, change \"--enable-property\" to \"--disable-property\".");
                } else if (!options_consumed.exists(fld.name)) {
                    if (fld.field_type == bool) {
                        @field(options, fld.name) = false;
                    } else if (fld.default_value) |default_value| {
                        @field(options, fld.name) = default_value;
                    } else if (@typeInfo(fld.field_type) == .Optional) {
                        @field(options, fld.name) = null;
                    } else {
                        _ = try err_stream.write("Required option \"--" ++ fld.name ++ "\" was missing.");
                        return error.MissingOption;
                    }
                }
            }

            while (args.next(allocator)) |arg_or_error| {
                const arg = try arg_or_error;
                try positionals.append(arg);
            }
            return InternalParseArgsResult(Spec){
                .options = options,
                .positionals = positionals.toOwnedSlice(),
            };
        },
        else => @compileError("Spec must be a struct or tagged union, but it was " ++ @typeName(Spec) ++ " instead."),
    }
}

pub const NullOutStream = struct {
    const Error = error{};
    pub const Stream = OutStream(void, Error, write);
    pub fn write(self: void, bytes: []const u8) Error!usize {
        return bytes.len;
    }
};

pub fn nullOutStream() NullOutStream.Stream {
    return .{ .context = {} };
}

test "can handle string options" {
    var arena = ArenaAllocator.init(heap.page_allocator);
    defer arena.deinit();

    const TestSpec = struct {
        @"my-option": []const u8,
    };

    const err_stream = &ArrayList(u8).init(&arena.allocator).outStream();

    var iterator = TestArgIterator{
        .args = &[_][]const u8{
            "test-exe", "--my-option=hello", "world",
        },
    };
    const res = try parseWithGivenArgs(TestSpec, &iterator, &arena.allocator, err_stream);
    expectEqualStrings("hello", res.options.@"my-option");
    expectEqual(@as(usize, 1), res.positionals.len);
    expectEqualStrings("world", res.positionals[0]);
}

test "can handle optional options" {
    var arena = ArenaAllocator.init(heap.page_allocator);
    defer arena.deinit();

    const TestSpec = struct {
        @"optional-option": ?[]const u8, withdefault: []const u8 = "hello"
    };

    const err_stream = &ArrayList(u8).init(&arena.allocator).outStream();

    var iterator = TestArgIterator{
        .args = &[_][]const u8{
            "test-exe", "world",
        },
    };
    const res = try parseWithGivenArgs(TestSpec, &iterator, &arena.allocator, err_stream);
    expectEqual(@as(?[]const u8, null), res.options.@"optional-option");
    expectEqualStrings("hello", res.options.withdefault);
    expectEqual(@as(usize, 1), res.positionals.len);
    expectEqualStrings("world", res.positionals[0]);
}

test "can handle boolean options" {
    var arena = ArenaAllocator.init(heap.page_allocator);
    defer arena.deinit();

    const TestSpec = struct { boolean1: bool, boolean2: bool };

    var iterator = TestArgIterator{
        .args = &[_][]const u8{
            "test-exe", "--boolean2",
        },
    };
    const res = try parseWithGivenArgs(TestSpec, &iterator, &arena.allocator, &nullOutStream());
    expectEqual(false, res.options.boolean1);
    expectEqual(true, res.options.boolean2);
}

test "can handle int options" {
    var arena = ArenaAllocator.init(heap.page_allocator);
    defer arena.deinit();

    const TestSpec = struct { x: usize, y: i32 };

    var iterator = TestArgIterator{
        .args = &[_][]const u8{
            "test-exe", "--x", "32", "--y", "-10003",
        },
    };
    const res = try parseWithGivenArgs(TestSpec, &iterator, &arena.allocator, &nullOutStream());
    expectEqual(@as(usize, 32), res.options.x);
    expectEqual(@as(i32, -10003), res.options.y);
}

test "handles int overflow" {
    var arena = ArenaAllocator.init(heap.page_allocator);
    defer arena.deinit();

    const TestSpec = struct { x: u8 };

    var iterator = TestArgIterator{
        .args = &[_][]const u8{
            "test-exe", "--x", "-2",
        },
    };
    const res = parseWithGivenArgs(TestSpec, &iterator, &arena.allocator, &nullOutStream());
    expectError(error.FailedToParseInt, res);
}

test "can handle float options" {
    var arena = ArenaAllocator.init(heap.page_allocator);
    defer arena.deinit();

    const TestSpec = struct { x: f64 };

    var iterator = TestArgIterator{
        .args = &[_][]const u8{
            "test-exe", "--x", "-44.13",
        },
    };
    const res = try parseWithGivenArgs(TestSpec, &iterator, &arena.allocator, &nullOutStream());
    expectEqual(@as(f64, -44.13), res.options.x);
}

test "alerts on missing options" {
    var arena = ArenaAllocator.init(heap.page_allocator);
    defer arena.deinit();

    const TestSpec = struct {
        option: []const u8,
    };

    var iterator = TestArgIterator{
        .args = &[_][]const u8{
            "test-exe", "world",
        },
    };
    const res = parseWithGivenArgs(TestSpec, &iterator, &arena.allocator, &nullOutStream());
    expectError(error.MissingOption, res);
}

test "handles commands" {
    var arena = ArenaAllocator.init(heap.page_allocator);
    defer arena.deinit();

    const TestSpec = union(enum) {
        first: struct {
            hello: []const u8,
        }, second: struct {
            beepboop: u8
        }
    };

    var iterator = TestArgIterator{
        .args = &[_][]const u8{
            "test-exe", "first", "--hello", "world",
        },
    };
    const res = try parseWithGivenArgs(TestSpec, &iterator, &arena.allocator, &nullOutStream());
    expect(res.options == .first);
    expectEqualStrings("world", res.options.first.hello);
}

test "calls exec fn" {
    var arena = ArenaAllocator.init(heap.page_allocator);
    defer arena.deinit();

    var test_function_called = false;

    const TestSpec = union(enum) {
        first: struct {
            hello: []const u8,
            fn exec(args: ParseArgsResult(@This()), called: *bool) !void {
                expectEqualStrings("world", args.options.hello);
                called.* = true;
            }
        },
    };

    var iterator = TestArgIterator{
        .args = &[_][]const u8{
            "test-exe", "first", "--hello", "world",
        },
    };
    _ = try parseAndRun(TestSpec, &iterator, &arena.allocator, &nullOutStream(), &test_function_called);
    expect(test_function_called);
}

fn joinFieldNames(comptime fields: var, comptime joint: []const u8) []const u8 {
    var str: []const u8 = "";
    for (fields) |field, i| {
        if (i != 0) str = str ++ joint;
        str = str ++ field.name;
    }
    return str;
}

fn doesArgTypeRequireArg(comptime Type: type) bool {
    if (Type == []const u8)
        return true;

    return switch (@typeInfo(Type)) {
        .Int, .Float, .Enum => true,
        .Bool => false,
        else => @compileError(@typeName(Type) ++ " is not a supported argument type!"),
    };
}
/// Returns true if the given type requires an argument to be parsed.
fn requiresArg(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .Optional => |opt| doesArgTypeRequireArg(opt.child),
        else => doesArgTypeRequireArg(T),
    };
}

/// Parses a boolean option.
fn parseBoolean(str: []const u8) !bool {
    return if (std.mem.eql(u8, str, "yes"))
        true
    else if (std.mem.eql(u8, str, "true"))
        true
    else if (std.mem.eql(u8, str, "y"))
        true
    else if (std.mem.eql(u8, str, "no"))
        false
    else if (std.mem.eql(u8, str, "false"))
        false
    else if (std.mem.eql(u8, str, "n"))
        false
    else
        return error.NotABooleanValue;
}

const ArgumentError = error{
    FailedToParseBoolean,
    FailedToParseInt,
    FailedToParseFloat,
    FailedToParseEnum,
};
/// Converts an argument value to the target type.
fn convertArgumentValue(comptime T: type, textInput: []const u8) ArgumentError!T {
    if (T == []const u8)
        return textInput;
    switch (@typeInfo(T)) {
        .Optional => |opt| return try convertArgumentValue(opt.child, textInput),
        .Bool => if (textInput.len > 0)
            return parseBoolean(textInput) catch ArgumentError.FailedToParseBoolean
        else
            return true, // boolean options are always true
        .Int => |int| return if (int.is_signed)
            std.fmt.parseInt(T, textInput, 10) catch ArgumentError.FailedToParseInt
        else
            std.fmt.parseUnsigned(T, textInput, 10) catch ArgumentError.FailedToParseInt,
        .Float => return std.fmt.parseFloat(T, textInput) catch ArgumentError.FailedToParseFloat,
        .Enum => return std.meta.stringToEnum(T, textInput) orelse return error.FailedtoParseEnum,
        else => @compileError(@typeName(T) ++ " is not a supported argument type!"),
    }
}

/// Parses an option value into the correct type.
fn parseOption(
    comptime Spec: type,
    options: *Spec,
    args: var,
    /// The name of the option that is currently parsed.
    comptime name: []const u8,
    /// Optional pre-defined value for options that use `--foo=bar`
    value: ?[]const u8,
    allocator: *Allocator,
    err_stream: var,
) !@TypeOf(@field(options, name)) {
    const field_type = @TypeOf(@field(options, name));

    const argval = if (requiresArg(field_type))
        value orelse
            try (args.next(allocator) orelse {
            try err_stream.print(
                "Missing argument for {}.\n",
                .{name},
            );
            return error.MissingArgument;
        })
    else
        (value orelse "");

    return convertArgumentValue(field_type, argval) catch |err| {
        try err_stream.print("Failed to parse option {}. Expected: {}, found: {}\n", .{
            name,
            switch (err) {
                error.FailedToParseInt => @as([]const u8, "integer value of size " ++ @typeName(field_type)),
                error.FailedToParseFloat => "float of type " ++ @typeName(field_type),
                error.FailedToParseBoolean => "true or false",
                error.FailedToParseEnum => blk: {
                    var info = switch (@typeInfo(field_type)) {
                        .Enum => |en| en,
                        .Optional => |opt| switch (@typeInfo(opt.child)) {
                            .Enum => |en| en,
                            else => unreachable,
                        },
                        else => unreachable,
                    };
                    break :blk "one of: " ++ joinFieldNames(info.fields, ", ") ++ ".";
                },
            },
            argval,
        });
        return err;
    };
}
