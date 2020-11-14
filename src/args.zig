const std = @import("std");
const io = std.io;
const process = std.process;
const heap = std.heap;
const mem = std.mem;
const zig_args = @import("zig-args/args.zig");
const log = std.log.scoped(.budget);

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

pub const Error = error{
    InvalidArguments,
    OutOfMemory,
    Unexpected,
};

pub fn ParseArgsResult(comptime Spec: type) type {
    return struct {
        arena: ArenaAllocator,
        options: Spec,
        exe_name: []const u8,

        pub fn deinit(self: *@This()) void {
            arena.deinit();
        }
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

fn runMainFn(result: anytype, context: anytype) !void {
    const Spec = @TypeOf(result.options);
    if (@typeInfo(Spec) == .Union) {
        const tagName = @tagName(result.options);
        inline for (@typeInfo(Spec).Union.fields) |fld| {
            if (mem.eql(u8, tagName, fld.name)) {
                try runMainFn(ParseArgsResult(fld.field_type){
                    .options = @field(result.options, fld.name),
                    .arena = result.arena,
                    .exe_name = result.exe_name,
                }, context);
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
        try Spec.exec(result, context);
    }
}

pub fn parseWithGivenArgsAndRun(comptime Spec: type, iterator: anytype, allocator: *Allocator, context: anytype) !void {
    const result = try parseWithGivenArgs(Spec, iterator, allocator);
    try runMainFn(result, context);
}
pub fn parseAndRun(comptime Spec: type, allocator: *Allocator, context: anytype) !void {
    const result = try parse(Spec, allocator);
    try runMainFn(result, context);
}

pub fn parse(comptime Spec: type, allocator: *Allocator) Error!ParseArgsResult(Spec) {
    var arena = ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    var iterator = try ArgIterator.initWithAllocator(allocator);
    var exe_name: []const u8 = try (iterator.next(&arena.allocator) orelse "");
    const result = try parseInternal(Spec, &iterator, &arena.allocator);
    return ParseArgsResult(Spec){
        .arena = arena,
        .options = result,
        .exe_name = exe_name,
    };
}

pub fn parseWithGivenArgs(comptime Spec: type, iterator: anytype, allocator: *Allocator) !ParseArgsResult(Spec) {
    var arena = ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    var exe_name: []const u8 = try (iterator.next(&arena.allocator) orelse return error.EmptyArgsIterator);
    const result = try parseInternal(Spec, iterator, &arena.allocator);
    return ParseArgsResult(Spec){
        .arena = arena,
        .options = result.options,
        .exe_name = exe_name,
    };
}

fn positionalField(comptime Spec: type) ?std.builtin.TypeInfo.StructField {
    inline for (@typeInfo(Spec).Struct.fields) |spec_field| {
        if (std.mem.eql(u8, spec_field.name, "_")) {
            var result: ?std.builtin.TypeInfo.StructField = null;
            comptime var seen_optionals: bool = false;
            for (@typeInfo(spec_field.field_type).Struct.fields) |positional_field| {
                if (positional_field.field_type == []const u8) continue;
                switch (@typeInfo(positional_field.field_type)) {
                    .Pointer => |ptr| {
                        switch (ptr.size) {
                            .One, .C => @compileError("Cannot handle positional type " ++ @typeName(fld.field_type) ++ "."),
                            .Slice, .Many => {
                                if (result != null) @compileError("You can't use multiple variadic positional arguments, because there's no way of telling when one ends and the other begins!");
                                result = positional_field;
                            },
                        }
                    },
                    .Optional => {
                        seen_optionals = true;
                    },
                    else => {
                        if (seen_optionals) @compileError("Required positionals cannot occur after optional positionals");
                    },
                }
            }
            return result;
        }
    }
    return null;
}
fn PositionalArrayElement(comptime Spec: type) ?type {
    const field = positionalField(Spec) orelse return null;
    if (@typeInfo(field.field_type).Pointer.size != .Many) return null;
    return @typeInfo(field.field_type).Pointer.child;
}
fn PositionalArray(comptime Spec: type) type {
    const Element = PositionalArrayElement(Spec) orelse return void;
    return ArrayList(Element);
}

fn parseInternal(comptime Spec: type, args: anytype, allocator: *Allocator) Error!Spec {
    if (@TypeOf(args) != *ArgIterator and @TypeOf(args) != *TestArgIterator) {
        @compileError("expected type '" ++ @typeName(*ArgIterator) ++ "' or '" ++ @typeName(*TestArgIterator) ++ "', found '" ++ @typeName(@TypeOf(args)) ++ "'.");
    }
    const spec_info = @typeInfo(Spec);
    switch (spec_info) {
        .Void => {},
        .Union => |union_spec| {
            if (union_spec.tag_type == null) {
                @compileError("Union specs must be tagged.");
            }
            const command = try (args.next(allocator) orelse {
                log.alert("Missing command, expected one of: " ++ joinFieldNames(union_spec.fields, ", ") ++ ".", .{});
                return Error.InvalidArguments;
            });
            inline for (union_spec.fields) |field| {
                if (mem.eql(u8, field.name, command)) {
                    return @unionInit(
                        Spec,
                        field.name,
                        try parseInternal(field.field_type, args, allocator),
                    );
                }
            }
            log.alert("Unexpected command {}, expected one of: " ++ joinFieldNames(union_spec.fields, ", ") ++ ".", .{command});
            return Error.InvalidArguments;
        },
        .Struct => |struct_spec| {
            var options: Spec = undefined;
            var positionals_consumed: usize = 0;

            var positionals_array: PositionalArray(Spec) = if (PositionalArray(Spec) == void) {} else PositionalArray(Spec).init(allocator);

            var options_consumed = BufSet.init(allocator);

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
                        comptime const check_field = !mem.startsWith(u8, fld.name, "_");
                        if (check_field) {
                            if (std.mem.eql(u8, kv.name, fld.name)) {
                                @field(options, fld.name) = try parseOption(
                                    fld.field_type,
                                    args,
                                    fld.name,
                                    kv.value,
                                    allocator,
                                );
                                try options_consumed.put(fld.name);
                                break :found_blk true;
                            }
                        }
                    } else false;

                    if (!found) {
                        log.alert("Unknown option {}\n", .{kv.name});
                        return Error.InvalidArguments;
                    }
                } else {
                    if (!@hasField(Spec, "_")) {
                        log.alert("Unexpected positional arguments passed.", .{});
                        return Error.InvalidArguments;
                    }
                    inline for (@typeInfo(@TypeOf(options._)).Struct.fields) |fld, index| {
                        const field_info = @typeInfo(fld.field_type);
                        if (field_info == .Pointer and field_info.Pointer.child != u8) {
                            @compileError("TODO - implement this (got " ++ @typeName(fld.field_type) ++ ")"); //TODO
                        } else {
                            if (index == positionals_consumed) {
                                @field(options._, fld.name) = try parseOption(
                                    fld.field_type,
                                    args,
                                    fld.name,
                                    arg,
                                    allocator,
                                );
                                positionals_consumed += 1;
                                break;
                            }
                        }
                    }
                }
            }

            inline for (@typeInfo(Spec).Struct.fields) |fld| {
                if (comptime mem.eql(u8, fld.name, "_")) {
                    inline for (@typeInfo(fld.field_type).Struct.fields) |positional_field, index| {
                        if (positionals_consumed < index + 1) {
                            @field(options._, positional_field.name) = try defaultValue(positional_field, true);
                        }
                    }
                } else if (mem.startsWith(u8, fld.name, "_")) {
                    //continue
                } else if (fld.field_type == bool and fld.default_value == true) {} else if (!options_consumed.exists(fld.name)) {
                    @field(options, fld.name) = try defaultValue(fld, false);
                }
            }

            while (args.next(allocator)) |arg_or_error| {
                const arg = try arg_or_error;
                // try positionals.append(arg);
            }
            return options;
        },
        else => @compileError("Spec must be a struct or tagged union, but it was " ++ @typeName(Spec) ++ " instead."),
    }
}

fn defaultValue(comptime fld: std.builtin.TypeInfo.StructField, comptime is_positional: bool) Error!fld.field_type {
    if (fld.field_type == bool) {
        if (fld.default_value == true) {
            @compileError("Error with option \"" ++ fld.name ++ "\": booleans cannot default to true. Instead try inverting your option (for example, change \"--enable-property\" to \"--disable-property\".");
        }
        return false;
    } else if (fld.default_value) |default_value| {
        return default_value;
    } else if (@typeInfo(fld.field_type) == .Optional) {
        return null;
    } else {
        log.alert("Missing " ++ (if (is_positional) "positional argument \"" else "option \"--") ++ fld.name ++ "\".", .{});
        return Error.InvalidArguments;
    }
}

fn checkIsPresent(
    options: anytype,
    fld: std.builtin.TypeInfo.StructField,
    options_consumed: BufSet,
) !void {}

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
    expectError(Error.InvalidArguments, res);
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
    expectError(Error.InvalidArguments, res);
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

fn joinFieldNames(comptime fields: anytype, comptime joint: []const u8) []const u8 {
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
        return ArgumentError.FailedToParseBoolean;
}

const ArgumentError = error{
    FailedToParseBoolean,
    FailedToParseInt,
    FailedToParseFloat,
    FailedToParseEnum,
};
/// Converts an argument value to the target type.
fn convertArgumentValue(comptime T: type, textInput: []const u8) !T {
    if (T == []const u8) {
        return textInput;
    }
    switch (@typeInfo(T)) {
        .Optional => |opt| return try convertArgumentValue(opt.child, textInput),
        .Bool => if (textInput.len > 0)
            return parseBoolean(textInput)
        else
            return true, // boolean options are always true
        .Int => |int| return if (int.is_signed)
            std.fmt.parseInt(T, textInput, 10)
        else
            std.fmt.parseUnsigned(T, textInput, 10),
        .Float => return std.fmt.parseFloat(T, textInput),
        .Enum => return std.meta.stringToEnum(T, textInput) orelse error.ArgumentError,
        else => @compileError(@typeName(T) ++ " is not a supported argument type!"),
    }
}

/// Parses an option value into the correct type.
fn parseOption(
    comptime field_type: type,
    args: anytype,
    /// The name of the option that is currently parsed.
    comptime name: []const u8,
    /// Optional pre-defined value for options that use `--foo=bar`
    value: ?[]const u8,
    allocator: *Allocator,
) !field_type {
    const argval = if (requiresArg(field_type))
        value orelse
            try (args.next(allocator) orelse {
            log.alert(
                "Missing argument for {}.\n",
                .{name},
            );
            return Error.InvalidArguments;
        })
    else
        (value orelse "");

    return convertArgumentValue(field_type, argval) catch |err| {
        log.alert("Failed to parse option {}. Expected: {}, found: {}\n", .{
            name,
            getExpectedValue(field_type),
            argval,
        });
        return Error.InvalidArguments;
    };
}

pub fn getExpectedValue(comptime field_type: type) []const u8 {
    return switch (@typeInfo(field_type)) {
        .Optional => |fld| getExpectedValue(fld.child),
        .Int => |fld| @as([]const u8, fld.bits ++ "-bit " ++ if (fld.signed) "" else "un" ++ "signed integer"),
        .Float => |fld| fld.bits + "-bit float",
        .Bool => "true or false",
        .Enum => |fld| "one of: " ++ joinFieldNames(fld.fields, ", ") ++ ".",
        else => @compileError("Unexpected type " ++ @typeName(field_type)),
    };
}
