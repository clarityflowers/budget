const std = @import("std");
const testing = std.testing;
const mem = std.mem;
const heap = std.heap;
const io = std.io;

const expect = testing.expect;
const expectEqual = testing.expectEqual;
const expectEqualSlices = testing.expectEqualSlices;
const expectEqualStrings = testing.expectEqualStrings;
const expectError = testing.expectError;

const Allocator = mem.Allocator;
const ArenaAllocator = heap.ArenaAllocator;
const ArrayList = std.ArrayList;
const SegmentedList = std.SegmentedList;

pub fn Result(comptime Output: type) type {
    return struct {
        index: usize = 0,
        out: Output,
    };
}

pub fn pass(index: usize, output: var) Result(@TypeOf(output)) {
    return .{
        .index = index,
        .out = output,
    };
}

pub const NextFailure = enum {
    none,
    child,
    children,
};
pub const Failure = struct {
    err: anyerror,
    index: usize,
    next: union(NextFailure) {
        none, child: *const Failure, children: []const Failure
    },

    pub fn deinitChildren(self: *const @This(), allocator: *Allocator) void {
        switch (self.next) {
            .none => {},
            .child => |child| {
                child.deinit(allocator);
            },
            .children => |children| {
                for (children) |child| {
                    child.deinitChildren(allocator);
                }
                allocator.free(children);
            },
        }
    }

    pub fn deinit(self: *const @This(), allocator: *Allocator) void {
        self.deinitChildren(allocator);
        allocator.destroy(self);
    }

    pub fn expectToBe(self: *const @This(), err: anyerror, index: usize) *const @This() {
        expectEqual(err, self.err);
        expectEqual(index, self.index);
        return self;
    }

    pub fn expectLast(self: *const @This()) void {
        expectEqual(NextFailure.none, self.next);
    }
    pub fn expectChild(self: *const @This(), err: anyerror, index: usize) *const @This() {
        expectEqual(NextFailure.child, self.next);
        var child = self.next.child;
        return child.expectToBe(err, index);
    }
    pub fn expectChildren(self: *const @This(), amount: usize) []const Failure {
        expectEqual(NextFailure.children, self.next);
        expectEqual(amount, self.next.children.len);
        return self.next.children;
    }

    pub fn print(self: *const @This(), str: []const u8, stream: var) anyerror!void {
        var ln_number: usize = 1;
        var ln_start: usize = 0;
        const ln_end: usize = blk: {
            for (str) |char, i| {
                if (char == '\n') {
                    if (i >= self.index) break :blk i;
                    ln_number += 1;
                    ln_start = i;
                }
            }
            break :blk str.len;
        };
        try stream.print("{}\n{}:{}\n  ", .{ @errorName(self.err), ln_number, str[ln_start..ln_end] });
        var i: usize = ln_start;
        while (i < self.index) : (i += 1) {
            try stream.writeByte(' ');
        }
        _ = try stream.write("^\n\n");

        switch (self.next) {
            .none => {},
            .child => |child| try child.print(str, stream),
            .children => |children| for (children) |child, child_i| {
                try stream.print("---{} CHILD {}:---\n", .{ @errorName(self.err), child_i });
                try child.print(str, stream);
            },
        }
    }
};

pub const State = struct {
    str: []const u8,
    allocator: *Allocator,
    failure_list: ?*Failure = null,
    failure_branches: SegmentedList(ArrayList(Failure), 4),

    pub inline fn get(self: *@This(), index: usize) []const u8 {
        if (index >= self.str.len) return "";
        return self.str[index..];
    }

    pub fn fail(self: *@This(), index: usize, comptime err: anyerror) !void {
        const new_failure = try self.allocator.create(Failure);
        new_failure.err = err;
        new_failure.index = index;
        if (self.failure_list) |head| {
            new_failure.next = .{ .child = head };
        } else {
            new_failure.next = .none;
        }
        self.failure_list = new_failure;
    }

    pub fn branchFailures(self: *@This()) !void {
        if (self.failure_list) |failure| {
            var new_branch = ArrayList(Failure).init(self.allocator);
            try new_branch.append(failure.*);
            try self.failure_branches.push(new_branch);
            self.allocator.destroy(failure);
            self.failure_list = null;
        }
    }

    pub fn addBranch(self: *@This()) !void {
        if (self.failure_list) |failure| {
            defer self.allocator.destroy(failure);
            if (self.failure_branches.pop()) |*branch| {
                errdefer branch.deinit();
                try branch.append(failure.*);
                try self.failure_branches.push(branch.*);
            }
        }
    }

    pub fn abandonBranch(self: *@This()) void {
        if (self.failure_branches.pop()) |*branch| {
            branch.deinit();
        }
    }

    pub fn endBranches(self: *@This(), index: usize, comptime err: anyerror) !void {
        try self.addBranch();
        const new_failure = try self.allocator.create(Failure);
        errdefer self.allocator.destroy(new_failure);
        new_failure.err = err;
        new_failure.index = index;
        if (self.failure_branches.pop()) |*branch| {
            errdefer branch.deinit();
            new_failure.next = .{ .children = branch.toOwnedSlice() };
        }
        self.failure_list = new_failure;
    }

    pub fn expectFailure(self: *@This(), comptime parser: var, err: anyerror, index: usize) *const Failure {
        expectError(error.NotParsed, parser(self, 0));
        expect(self.failure_list != null);
        return self.failure_list.?.expectToBe(err, index);
    }

    pub fn expectSuccess(self: *@This(), comptime parser: var, index: usize, expected_output: var) void {
        const result = parser(self, 0);
        if (result) |res| {
            expectSame(expected_output, res.out);
            expectEqual(index, res.index);
        } else |err| {
            if (self.failure_list) |list| list.print(self.str, io.getStdErr().outStream()) catch unreachable;
            unreachable;
        }
    }

    pub fn reset(self: *@This(), str: []const u8) *State {
        self.str = str;
        self.deinit();
        return self;
    }
    pub fn init(str: []const u8, allocator: *Allocator) @This() {
        return @This(){
            .str = str,
            .allocator = allocator,
            .failure_branches = SegmentedList(ArrayList(Failure), 4).init(allocator),
        };
    }

    pub fn resetFailures(self: *@This()) void {
        if (self.failure_list) |failure_list| {
            failure_list.deinit(self.allocator);
            self.failure_list = null;
        }
    }
    pub fn clearBranches(self: *@This()) void {
        self.failure_branches.shrink(0);
    }

    pub fn deinit(self: *@This()) void {
        self.resetFailures();
        self.clearBranches();
    }
};

pub const Error = error{ NotParsed, OutOfMemory };

pub fn Parser(comptime Output: type) type {
    return fn (state: *State, index: usize) Error!Result(Output);
}

pub fn literal(comptime expected: []const u8) Parser(void) {
    return struct {
        fn parse(state: *State, index: usize) Error!Result(void) {
            const str = state.get(index);
            if (expected.len <= str.len and mem.eql(u8, str[0..expected.len], expected)) {
                return pass(index + expected.len, {});
            } else {
                try state.fail(index, error.MatchLiteral);
                return error.NotParsed;
            }
        }
    }.parse;
}

pub fn isAlpha(char: u8) bool {
    return (char >= 'a' and char <= 'z') or (char >= 'A' and char <= 'Z');
}
pub const identifier = some(pred(anyChar, isAlpha));

test "literal" {
    var arena = ArenaAllocator.init(heap.page_allocator);
    defer arena.deinit();
    const allocator = &arena.allocator;

    comptime const parser = literal("Hello");
    var state = &State.init("Hello, world!", allocator);
    state.expectSuccess(parser, 5, {});
    state.reset("Hell").expectFailure(parser, error.MatchLiteral, 0).expectLast();
    state.reset("Goodbye").expectFailure(parser, error.MatchLiteral, 0).expectLast();
}

pub fn Pair(comptime LH: type, comptime RH: type) type {
    return struct {
        lh: LH, rh: RH
    };
}

fn OutputOfResult(comptime result: type) ?type {
    const res = @typeInfo(result);

    const res_fields = @typeInfo(Result(void)).Struct.fields;
    if (res != .Struct) return null;
    if (res.Struct.fields.len != res_fields.len) return null;
    if (!mem.eql(u8, res.Struct.fields[0].name, res_fields[0].name)) return null;
    if (res.Struct.fields[0].field_type != res_fields[0].field_type) return null;
    if (!mem.eql(u8, res.Struct.fields[1].name, res_fields[1].name)) return null;

    return res.Struct.fields[1].field_type;
}

pub fn OutputOf(parser: var) type {
    comptime {
        const T = @TypeOf(parser);
        const err = "Expected value to be a Parser, but instead it was a(n) " ++ @typeName(T) ++ ".";
        const info = @typeInfo(T);

        if (info != .Fn) @compileError(err);
        if (info.Fn.args.len != 2) @compileError(err);
        if (info.Fn.args[0].arg_type != *State) @compileError(err);
        if (info.Fn.args[1].arg_type != usize) @compileError(err);
        if (info.Fn.return_type == null) @compileError(err);
        const ret_info = @typeInfo(info.Fn.return_type.?);
        if (ret_info != .ErrorUnion) @compileError(err);
        if (ret_info.ErrorUnion.error_set != Error) @compileError(err);
        return OutputOfResult(ret_info.ErrorUnion.payload) orelse @compileError(err);
    }
}

pub fn pair(comptime lh: var, comptime rh: var) Parser(Pair(OutputOf(lh), OutputOf(rh))) {
    return struct {
        fn parse(state: *State, index: usize) Error!Result(Pair(OutputOf(lh), OutputOf(rh))) {
            if (lh(state, index)) |lh_res| {
                if (rh(state, lh_res.index)) |rh_res| {
                    return pass(rh_res.index, Pair(OutputOf(lh), OutputOf(rh)){ .lh = lh_res.out, .rh = rh_res.out });
                } else |err| {
                    try state.fail(lh_res.index, error.PairMissingRight);
                    return err;
                }
            } else |err| {
                try state.fail(index, error.PairMissingLeft);
                return err;
            }
        }
    }.parse;
}

test "pair" {
    var arena = ArenaAllocator.init(heap.page_allocator);
    defer arena.deinit();
    const allocator = &arena.allocator;

    comptime const parser = pair(literal("<"), identifier);
    const state = &State.init("<myFirstElement/>", allocator);
    state.expectSuccess(parser, "<myFirstElement".len, Pair(void, []const u8){ .lh = {}, .rh = "myFirstElement" });
    state.reset("oops").expectFailure(parser, error.PairMissingLeft, 0).expectChild(error.MatchLiteral, 0).expectLast();
    state.reset("<!oops").expectFailure(parser, error.PairMissingRight, 1).expectChild(error.NotEnoughCopies, 1).expectChild(error.DidntMatchPredicate, 1).expectLast();
}

pub fn ResultOf(comptime function: var) type {
    comptime {
        const info = @typeInfo(@TypeOf(function));
        if (info != .Fn) @compileError("Expected a Fn but got a variable of type " ++ @typeName(@TypeOf(function)));
        return info.Fn.return_type orelse void;
    }
}

pub fn MappedParser(comptime parser: var, comptime function: var) type {
    comptime {
        const Out = ResultOf(function);
        const In = OutputOf(parser);
        const info = @typeInfo(@TypeOf(function));
        const Expected = fn (In) Out;
        if (@TypeOf(function) != Expected) {
            @compileError("Expected map function to have type '" ++ @typeName(Expected) ++ "' but instead it was type '" ++ @typeName(@TypeOf(function)) ++ "'.");
        }
        return Parser(Out);
    }
}

pub fn map(comptime in: var, comptime mapFn: var) MappedParser(in, mapFn) {
    return struct {
        fn mapResult(state: *State, index: usize) Error!Result(ResultOf(mapFn)) {
            const res = try in(state, index);
            return pass(res.index, mapFn(res.out));
        }
    }.mapResult;
}

pub inline fn left(comptime lh: var, comptime rh: var) @TypeOf(lh) {
    const takeLeft = struct {
        inline fn take(val: Pair(OutputOf(lh), OutputOf(rh))) OutputOf(lh) {
            return val.lh;
        }
    }.take;
    return map(pair(lh, rh), takeLeft);
}

pub fn right(comptime lh: var, comptime rh: var) @TypeOf(rh) {
    const takeRight = struct {
        inline fn take(val: Pair(OutputOf(lh), OutputOf(rh))) OutputOf(rh) {
            return val.rh;
        }
    }.take;
    return map(pair(lh, rh), takeRight);
}

test "right" {
    var arena = ArenaAllocator.init(heap.page_allocator);
    defer arena.deinit();
    const allocator = &arena.allocator;

    comptime const parser = right(literal("<"), identifier);
    const state = &State.init("<myFirstElement/>", allocator);
    state.expectSuccess(parser, "<myFirstElement".len, "myFirstElement");
    state.reset("oops").expectFailure(parser, error.PairMissingLeft, 0).expectChild(error.MatchLiteral, 0).expectLast();
    state.reset("<!oops").expectFailure(parser, error.PairMissingRight, 1).expectChild(error.NotEnoughCopies, 1).expectChild(error.DidntMatchPredicate, 1).expectLast();
}

pub fn SliceOrCount(comptime T: type, is_count: bool) type {
    return if (is_count) usize else []const T;
}

/// Caller owns the resulting slice
pub fn nOrMore(comptime parser: var, comptime n: usize, comptime is_count: bool) Parser(SliceOrCount(OutputOf(parser), is_count)) {
    return struct {
        const R = OutputOf(parser);
        const NOrMoreResult = SliceOrCount(R, is_count);
        fn parse(state: *State, index: usize) Error!Result(NOrMoreResult) {
            const result = if (!is_count) &ArrayList(R).init(state.allocator) else undefined;
            errdefer if (!is_count) result.deinit();
            var count: usize = 0;
            var in = index;
            while (true) : (count += 1) {
                const res = parser(state, in) catch break;
                in = res.index;
                if (!is_count) {
                    try result.append(res.out);
                }
            }
            if (count < n) {
                try state.fail(in, error.NotEnoughCopies);
                return error.NotParsed;
            }
            state.resetFailures();
            if (is_count) {
                return pass(in, count);
            } else {
                return pass(in, @as([]const R, result.items));
            }
        }
    }.parse;
}

pub fn anyNumberOf(comptime parser: var) Parser([]const OutputOf(parser)) {
    return nOrMore(parser, 0, false);
}
pub fn countAnyNumberOf(comptime parser: var) Parser(usize) {
    return nOrMore(parser, 0, true);
}
pub fn some(comptime parser: var) Parser([]const OutputOf(parser)) {
    return nOrMore(parser, 1, false);
}
pub fn countSome(comptime parser: var) Parser(usize) {
    return nOrMore(parser, 1, true);
}

test "nOrMore" {
    var arena = ArenaAllocator.init(heap.page_allocator);
    defer arena.deinit();
    const allocator = &arena.allocator;

    comptime const space = literal(" ");
    comptime const parser = countSome(space);
    const state = &State.init("   test", allocator);
    state.expectSuccess(parser, 3, @as(usize, 3));
    state.reset("").expectFailure(parser, error.NotEnoughCopies, 0).expectChild(error.MatchLiteral, 0).expectLast();

    comptime const parser2 = anyNumberOf(left(identifier, parser));
    state.reset("one  two 3three").expectSuccess(parser2, "one  two ".len, &[_][]const u8{ "one", "two" });
    state.reset(" one two").expectSuccess(parser2, 0, [_][]const u8{});
}

/// caller owns returned slice
pub fn join(comptime item: var, comptime joint: var) Parser([]const OutputOf(item)) {
    comptime const listParser = some(right(joint, item));
    return struct {
        fn parse(state: *State, index: usize) Error!Result([]const OutputOf(item)) {
            const first_res = item(state, index) catch |err| {
                try state.fail(index, error.JoinMissingFirstItem);
                return err;
            };
            const list_res = try listParser(state, first_res.index);

            const result = &ArrayList(OutputOf(item)).init(state.allocator);
            errdefer result.deinit();
            try result.append(first_res.out);
            try result.appendSlice(list_res.out);
            return pass(list_res.index, @as([]const OutputOf(item), result.items));
        }
    }.parse;
}

test "join" {
    var arena = ArenaAllocator.init(heap.page_allocator);
    defer arena.deinit();
    const allocator = &arena.allocator;

    comptime const csv = join(identifier, literal(","));

    const state = &State.init("one,two,three,", allocator);
    state.expectSuccess(csv, "one,two,three".len, [_][]const u8{ "one", "two", "three" });
    state.reset(",one,two,three").expectFailure(csv, error.JoinMissingFirstItem, 0).expectChild(error.NotEnoughCopies, 0).expectChild(error.DidntMatchPredicate, 0).expectLast();
}

pub fn anyChar(state: *State, index: usize) Error!Result(u8) {
    const str = state.get(index);
    if (str.len > 0) {
        return pass(index + 1, str[0]);
    } else {
        try state.fail(index, error.NoMoreChars);
        return error.NotParsed;
    }
}

pub fn pred(comptime parser: var, comptime predicate: fn (val: OutputOf(parser)) bool) @TypeOf(parser) {
    return struct {
        fn parse(state: *State, index: usize) Error!Result(OutputOf(parser)) {
            const res = try parser(state, index);
            if (predicate(res.out)) {
                return pass(res.index, res.out);
            } else {
                try state.fail(index, error.DidntMatchPredicate);
                return error.NotParsed;
            }
        }
    }.parse;
}

test "pred and anyChar" {
    var arena = ArenaAllocator.init(heap.page_allocator);
    defer arena.deinit();
    const allocator = &arena.allocator;

    comptime const isBang = struct {
        fn check(char: u8) bool {
            return char == '!';
        }
    }.check;
    comptime const parser = pred(anyChar, isBang);

    const state = &State.init("bang!", allocator);
    state.expectFailure(parser, error.DidntMatchPredicate, 0).expectLast();
    state.reset("!bang!").expectSuccess(parser, 1, @as(u8, '!'));
}

pub fn skip(comptime parser: u8) Parser(void) {
    return struct {
        fn parse(state: *State, index: usize) Error!Result(void) {
            res = try parser(state, index);
            return pass(res.index, {});
        }
    }.parse;
}

fn isWhitespace(char: u8) bool {
    return char == ' ' or char == '\t' or char == '\n' or char == '\r';
}

pub const whitespaceChar = pred(anyChar, isWhitespace);
pub const someSpaces = countSome(whitespaceChar);
pub const anyNumberOfSpaces = countAnyNumberOf(whitespaceChar);

pub fn either(comptime first: var, comptime second: var) @TypeOf(first) {
    if (@TypeOf(first) != @TypeOf(second)) {
        @compileError("either() requires both parsers to have the same output type, but your types were " ++ @typeName(ResultOf(first)) ++ " and " ++ @typeName(ResultOf(second)) ++ ".");
    }
    return struct {
        fn parse(state: *State, index: usize) Error!Result(OutputOf(first)) {
            if (first(state, index)) |res| {
                return res;
            } else |err_lh| {
                switch (err_lh) {
                    error.OutOfMemory => return err_lh,
                    error.NotParsed => {
                        try state.branchFailures();
                        if (second(state, index)) |res| {
                            state.resetFailures();
                            state.abandonBranch();
                            return res;
                        } else |err_rh| {
                            switch (err_rh) {
                                error.OutOfMemory => {
                                    state.resetFailures();
                                    return err_rh;
                                },
                                error.NotParsed => {
                                    try state.endBranches(index, error.NeitherMatch);
                                    return error.NotParsed;
                                },
                            }
                        }
                    },
                }
            }
        }
    }.parse;
}

fn ResultOfThenFn(comptime parser: var, comptime thenFn: var) type {
    comptime const err = "Expect thenFn to be 'fn(ResultOf(parser), *State, usize) Error!Result(T)' but it was '" ++ @typeName(@TypeOf(thenFn)) ++ "' instead.";
    const info = @typeInfo(@TypeOf(thenFn));
    if (info != .Fn) @compileError(err);
    if (info.Fn.return_type) |ret_type| {
        const ret_info = @typeInfo(ret_type);
        if (ret_info != .ErrorUnion) @compileError(err);
        const T = OutputOfResult(ret_info.ErrorUnion.payload) orelse @compileError(err);
        const Expected = fn (OutputOf(parser), *State, usize) Error!Result(T);
        if (@TypeOf(thenFn) != Expected) @compileError("Expect thenFn to be '" ++ @typeName(Expected) ++ "' but it was '" ++ @typeName(@TypeOf(thenFn)) ++ "' instead.");
        return T;
    } else @compileError(err);
}

pub fn then(comptime parser: var, comptime thenFn: var) Parser(ResultOfThenFn(parser, thenFn)) {
    return struct {
        fn parse(state: *State, index: usize) Error!Result(ResultOfThenFn(parser, thenFn)) {
            const res = try parser(state, index);
            return try thenFn(res.out, state, res.index);
        }
    }.parse;
}

pub fn wrappedInWhitespace(comptime parser: var) @TypeOf(parser) {
    return right(anyNumberOfSpaces, left(parser, anyNumberOfSpaces));
}

fn toSlice(comptime T: type, value: var) []const T {
    switch (@typeInfo(@TypeOf(value))) {
        .Pointer => |pointer| {
            switch (pointer.size) {
                .Slice => {
                    return value;
                },
                else => {
                    return value.*;
                },
            }
        },
        .Array => {
            return value[0..];
        },
        else => {
            @compileError("can only convert arrays and slices to slices, but this is type \"" ++ @typeName(@TypeOf(value)) ++ "\"");
        },
    }
}

fn toValue(comptime T: type, value: var) T {
    switch (@typeInfo(@TypeOf(value))) {
        .Pointer => |pointer| {
            switch (pointer.size) {
                .Slice => {
                    return value;
                },
                else => {
                    return value.*;
                },
            }
        },
        else => {
            return value;
        },
    }
}

fn expectSameSlices(comptime T: type, expected: []const T, actual: []const T) void {
    expectEqual(expected.len, actual.len);
    for (expected) |expected_item, i| {
        expectSame(expected_item, actual[i]);
    }
}

fn expectSame(expected: var, actual: var) void {
    switch (@typeInfo(@TypeOf(expected))) {
        .Pointer => |pointer| {
            switch (pointer.size) {
                .Slice => {
                    if (pointer.child == u8) {
                        expectEqualStrings(expected, toSlice(u8, actual));
                    } else {
                        expectSameSlices(pointer.child, expected, toSlice(pointer.child, actual));
                    }
                },
                else => {
                    expectSame(expected.*, actual);
                },
            }
        },
        .Array => |array| {
            if (array.child == u8) {
                expectEqualStrings(expected[0..], toSlice(u8, actual));
            } else {
                expectSameSlices(array.child, expected[0..], toSlice(array.child, actual));
            }
        },
        .Struct => |strct| {
            inline for (strct.fields) |field| {
                expectSame(@field(expected, field.name), @field(actual, field.name));
            }
        },
        else => expectEqual(expected, actual),
    }
}
