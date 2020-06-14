const std = @import("std");
const testing = std.testing;
const mem = std.mem;
const heap = std.heap;

const expect = testing.expect;
const expectEqual = testing.expectEqual;
const expectEqualSlices = testing.expectEqualSlices;
const expectEqualStrings = testing.expectEqualStrings;

const Allocator = mem.Allocator;
const ArenaAllocator = heap.ArenaAllocator;
const ArrayList = std.ArrayList;

pub fn Result(comptime Output: type) type {
    return union(enum) {
        Ok: struct {
            in: Input, out: Output
        }, Err: struct {
            in: Input, err: anyerror
        }
    };
}

pub fn ok(input: Input, output: var) Result(@TypeOf(output)) {
    return .{
        .Ok = .{
            .in = input,
            .out = output,
        },
    };
}

pub fn err(comptime Output: type, input: Input, er: anyerror) Result(Output) {
    return .{
        .Err = .{
            .in = input,
            .err = er,
        },
    };
}

pub const Input = struct {
    str: []const u8,
    index: usize = 0,
    allocator: *Allocator,

    pub inline fn consume(self: @This(), len: usize) @This() {
        std.debug.assert(self.index + len <= self.str.len);
        return @This(){
            .str = self.str,
            .index = self.index + len,
            .allocator = self.allocator,
        };
    }

    pub inline fn get(self: @This()) []const u8 {
        if (self.index >= self.str.len) return "";
        return self.str[self.index..];
    }
};

pub fn Parser(comptime Output: type) type {
    return fn (input: Input) Result(Output);
}

pub fn matchLiteral(comptime expected: []const u8) Parser(void) {
    return struct {
        fn parse(input: Input) Result(void) {
            const str = input.get();
            if (expected.len <= str.len and mem.eql(u8, str[0..expected.len], expected)) {
                return ok(input.consume(expected.len), {});
            } else {
                return err(void, input, error.LiteralDidntMatch);
            }
        }
    }.parse;
}

test "matchLiteral" {
    comptime const parser = matchLiteral("Hello");
    expectOk(parser, "Hello, world!", 5, {});
    expectErr(parser, "Hell", error.LiteralDidntMatch);
    expectErr(parser, "Goodybye", error.LiteralDidntMatch);
}

inline fn isAlpha(char: u8) bool {
    return (char >= 'a' and char <= 'z') or (char >= 'A' and char <= 'Z');
}
inline fn isNum(char: u8) bool {
    return char >= '0' and char <= '9';
}
inline fn isAlphaNum(char: u8) bool {
    return isAlpha(char) or isNum(char);
}

pub fn identifier(input: Input) Result([]const u8) {
    var len: usize = 0;
    const str = input.get();
    if (str.len == 0) return err([]const u8, input, error.IdentifierMustNotBeEmpty);
    if (isAlpha(str[0])) {
        len += 1;
    } else {
        return err([]const u8, input, error.IdentifierMustStartWithAlphaChar);
    }
    for (str[1..]) |char| {
        if (isAlphaNum(char) or char == '-') {
            len += 1;
        } else {
            break;
        }
    }
    return ok(input.consume(len), str[0..len]);
}

test "identifier" {
    const ident1 = "i-am-an-identifier";
    expectOk(identifier, ident1, ident1.len, ident1);
    const ident2 = "not entirely an identifier";
    expectOk(identifier, ident2, 3, "not");
    expectErr(identifier, "!not at all an identifier", error.IdentifierMustStartWithAlphaChar);
}

fn Pair(comptime LH: type, comptime RH: type) type {
    return struct {
        lh: LH, rh: RH
    };
}

pub fn pair(comptime LH: type, comptime RH: type, comptime lh: Parser(LH), comptime rh: Parser(RH)) Parser(Pair(LH, RH)) {
    return struct {
        fn parse(in: Input) Result(Pair(LH, RH)) {
            return switch (lh(in)) {
                .Err => |res_err| err(Pair(LH, RH), res_err.in, res_err.err),
                .Ok => |res_lh| switch (rh(res_lh.in)) {
                    .Err => |res_rh| err(Pair(LH, RH), res_rh.in, res_rh.err),
                    .Ok => |res_rh| ok(res_rh.in, Pair(LH, RH){ .lh = res_lh.out, .rh = res_rh.out }),
                },
            };
        }
    }.parse;
}

test "pair" {
    comptime const tagOpener = pair(void, []const u8, matchLiteral("<"), identifier);
    expectOk(tagOpener, "<my-first-element/>", "<my-first-element".len, Pair(void, []const u8){ .lh = {}, .rh = "my-first-element" });
    expectErr(tagOpener, "oops", error.LiteralDidntMatch);
    expectErrAtIndex(tagOpener, "<!oops", error.IdentifierMustStartWithAlphaChar, "<".len);
}

pub fn map(comptime In: type, comptime Out: type, comptime in: Parser(In), comptime mapFn: fn (In) Out) Parser(Out) {
    return struct {
        fn mapResult(input: Input) Result(Out) {
            return switch (in(input)) {
                .Err => |res| err(Out, res.in, res.err),
                .Ok => |res| ok(res.in, mapFn(res.out)),
            };
        }
    }.mapResult;
}

pub inline fn left(comptime LH: type, comptime RH: type, comptime lh: Parser(LH), comptime rh: Parser(RH)) Parser(LH) {
    const takeLeft = struct {
        inline fn take(val: Pair(LH, RH)) LH {
            return val.lh;
        }
    }.take;
    return map(Pair(LH, RH), LH, pair(LH, RH, lh, rh), takeLeft);
}

pub fn right(comptime LH: type, comptime RH: type, comptime lh: Parser(LH), comptime rh: Parser(RH)) Parser(RH) {
    const takeRight = struct {
        inline fn take(val: Pair(LH, RH)) RH {
            return val.rh;
        }
    }.take;
    return map(Pair(LH, RH), RH, pair(LH, RH, lh, rh), takeRight);
}

test "right" {
    comptime const bracket = matchLiteral("<");
    comptime const tagOpener = right(void, []const u8, bracket, identifier);
    expectOk(tagOpener, "<my-first-element/>", "<my-first-element".len, "my-first-element");
    expectErr(tagOpener, "oops", error.LiteralDidntMatch);
    expectErrAtIndex(tagOpener, "<!oops", error.IdentifierMustStartWithAlphaChar, "<".len);
}

pub fn SliceOrCount(comptime T: type, is_count: bool) type {
    return if (is_count) usize else []const T;
}

/// Caller owns the resulting slice
pub fn nOrMore(comptime R: type, comptime parser: Parser(R), comptime n: usize, comptime is_count: bool) Parser(SliceOrCount(R, is_count)) {
    return struct {
        const NOrMoreResult = SliceOrCount(R, is_count);
        fn parse(in: Input) Result(NOrMoreResult) {
            const result = if (!is_count) &ArrayList(R).init(in.allocator) else undefined;
            var count: usize = 0;
            var in_res = in;
            while (true) : (count += 1) {
                switch (parser(in_res)) {
                    .Ok => |res| {
                        in_res = res.in;
                        if (!is_count) {
                            result.append(res.out) catch |append_err| return err(NOrMoreResult, in_res, append_err);
                        }
                    },
                    .Err => break,
                }
            }
            if (count < n) return err(NOrMoreResult, in_res, error.NotEnoughCopies);
            if (is_count) {
                return ok(in_res, count);
            } else {
                return ok(in_res, @as([]const R, result.items));
            }
        }
    }.parse;
}

test "nOrMore" {
    comptime const space = matchLiteral(" ");
    comptime const oneOrMoreSpaces = nOrMore(void, space, 1, true);
    expectOk(oneOrMoreSpaces, "   test", 3, @as(usize, 3));
    expectErr(oneOrMoreSpaces, "", error.NotEnoughCopies);

    comptime const zeroOrMoreIdentifiers = nOrMore([]const u8, left([]const u8, usize, identifier, nOrMore(void, space, 1, true)), 0, false);
    expectOk(zeroOrMoreIdentifiers, "one two 3three", "one two ".len, [_][]const u8{ "one", "two" });
    expectOk(zeroOrMoreIdentifiers, " one two", 0, [_][]const u8{});
    expectOk(zeroOrMoreIdentifiers, "one ", "one ".len, [_][]const u8{"one"});
}

/// caller owns returned slice
pub fn join(comptime Item: type, comptime Joint: type, comptime item: Parser(Item), comptime joint: Parser(Joint)) Parser([]const Item) {
    return struct {
        fn parse(input: Input) Result([]const Item) {
            const first_res = switch (item(input)) {
                .Err => |err_res| return err([]const Item, err_res.in, err_res.err),
                .Ok => |res| res,
            };
            comptime const listParser = nOrMore(Item, right(Joint, Item, joint, item), 0, false);
            const list_res = switch (listParser(first_res.in)) {
                .Err => |err_res| return err([]const Item, err_res.in, err_res.err),
                .Ok => |res| res,
            };
            const result = &ArrayList(Item).init(input.allocator);
            result.append(first_res.out) catch |er| {
                result.deinit();
                return err([]const Item, list_res.in, er);
            };
            result.appendSlice(list_res.out) catch |er| {
                result.deinit();
                return err([]const Item, list_res.in, er);
            };
            return ok(list_res.in, @as([]const Item, result.items));
        }
    }.parse;
}

test "join" {
    comptime const csv = join([]const u8, void, identifier, matchLiteral(","));
    expectOk(csv, "one,two,three,", "one,two,three".len, [_][]const u8{ "one", "two", "three" });
    expectErr(csv, ",one,two,three", error.IdentifierMustStartWithAlphaChar);
}

pub inline fn anyChar(input: Input) Result(u8) {
    const str = input.get();
    return if (str.len > 0) ok(input.consume(1), str[0]) else err(u8, input, error.NoMoreChars);
}

pub fn pred(comptime R: type, comptime parser: Parser(R), comptime predicate: fn (R) bool) Parser(R) {
    return struct {
        fn parse(input: Input) Result(R) {
            switch (parser(input)) {
                .Ok => |res| if (predicate(res.out)) return ok(res.in, res.out),
                else => {},
            }
            return err(R, input, error.DidntMatchPredicate);
        }
    }.parse;
}

test "pred and anyChar" {
    comptime const isBang = struct {
        fn check(char: u8) bool {
            return char == '!';
        }
    }.check;
    comptime const parser = pred(u8, anyChar, isBang);
    expectErr(parser, "bang!", error.DidntMatchPredicate);
    expectOk(parser, "!bang!", "!".len, @as(u8, '!'));
}

fn isWhitespace(char: u8) bool {
    return char == ' ' or char == '\t' or char == '\n' or char == '\r';
}

pub const whitespaceChar = pred(u8, anyChar, isWhitespace);

pub fn nOrMoreSpaces(comptime n: usize) Parser(usize) {
    return nOrMore(u8, whitespaceChar, n, true);
}

inline fn isNotQuote(char: u8) bool {
    return char != '"';
}

pub const quotedString = right(void, []const u8, matchLiteral("\""), left([]const u8, void, nOrMore(u8, pred(u8, anyChar, isNotQuote), 0, false), matchLiteral("\"")));

test "quotedString" {
    expectOk(quotedString, "\"hello, world,\" she said", "\"hello, world,\"".len, "hello, world,");
    expectErrAtIndex(quotedString, "\"hello, world,", error.LiteralDidntMatch, "\"hello, world,".len);
}

pub const AttributePair = Pair([]const u8, []const u8);
pub const Attribute = struct {
    key: []const u8, value: []const u8
};
fn toAttribute(attribute_pair: AttributePair) Attribute {
    return .{
        .key = attribute_pair.lh,
        .value = attribute_pair.rh,
    };
}
pub const attributePair = map(AttributePair, Attribute, pair([]const u8, []const u8, identifier, right(void, []const u8, matchLiteral("="), quotedString)), toAttribute);

pub const attributes = nOrMore(Attribute, right(usize, Attribute, nOrMoreSpaces(1), attributePair), 0, false);

test "attributes" {
    expectOk(attributes, " one=\"1\" two=\"2\"", " one=\"1\" two=\"2\"".len, [_]Attribute{ .{
        .key = "one",
        .value = "1",
    }, .{
        .key = "two",
        .value = "2",
    } });
}

pub const ElementStart = Pair([]const u8, []const Attribute);
pub const elementStart = right(void, ElementStart, matchLiteral("<"), pair([]const u8, []const Attribute, identifier, attributes));

pub const Element = struct {
    name: []const u8, attributes: []const Attribute = &[_]Attribute{}, children: []const Element = &[_]Element{}
};

fn intoElement(start: ElementStart) Element {
    return .{
        .name = start.lh,
        .attributes = start.rh,
    };
}
pub const singleElement = map(ElementStart, Element, left(ElementStart, void, elementStart, matchLiteral("/>")), intoElement);

test "single element" {
    const expected = "<div class=\"zone\"/>";
    expectOk(singleElement, expected, expected.len, Element{
        .name = "div",
        .attributes = &[_]Attribute{.{
            .key = "class",
            .value = "zone",
        }},
    });
}

pub const openElement = map(ElementStart, Element, left(ElementStart, void, elementStart, matchLiteral(">")), intoElement);

pub fn either(comptime R: type, comptime first: Parser(R), comptime second: Parser(R)) Parser(R) {
    return struct {
        fn parse(input: Input) Result(R) {
            return switch (first(input)) {
                .Ok => |res| ok(res.in, res.out),
                .Err => switch (second(input)) {
                    .Ok => |res| ok(res.in, res.out),
                    .Err => |res| err(R, res.in, res.err),
                },
            };
        }
    }.parse;
}

pub const element = wrappedInWhitespace(Element, either(Element, singleElement, parentElement));
pub const children = nOrMore(Element, element, 0, false);
pub const closeElementStart = matchLiteral("</");
pub const closeElementEnd = right(usize, void, nOrMoreSpaces(0), matchLiteral(">"));

pub fn parentElement(input: Input) Result(Element) {
    const open_res = switch (openElement(input)) {
        .Ok => |res| res,
        .Err => |res| return err(Element, res.in, res.err),
    };
    const children_res = switch (children(open_res.in)) {
        .Ok => |res| res,
        .Err => |res| return err(Element, res.in, res.err),
    };
    const close_start_res = switch (closeElementStart(children_res.in)) {
        .Ok => |res| res,
        .Err => |res| return err(Element, res.in, res.err),
    };
    const str = close_start_res.in.get();

    var final_res = open_res.out;
    const expected = final_res.name;
    if (expected.len > str.len or !mem.eql(u8, str[0..expected.len], expected)) {
        return err(Element, close_start_res.in, error.ElementWasNotClosed);
    }

    const close_end_res = switch (closeElementEnd(close_start_res.in.consume(expected.len))) {
        .Ok => |res| res,
        .Err => |res| return err(Element, res.in, res.err),
    };

    final_res.children = children_res.out;

    return ok(close_end_res.in, final_res);
}

pub fn wrappedInWhitespace(comptime R: type, comptime parser: Parser(R)) Parser(R) {
    return right(usize, R, nOrMoreSpaces(0), left(R, usize, parser, nOrMoreSpaces(0)));
}

test "parseHtml" {
    const str =
        \\<article>
        \\  <p class="part-1" ><test /></p>
        \\  <br />
        \\</article>
    ;
    expectErrAtIndex(element, str, error.Whatever, 9);
    expectOk(element, str, str.len, Element{
        .name = "Article",
        .children = &[_]Element{.{
            .name = "p",
            .attributes = &[_]Attribute{.{ .key = "class", .value = "part-1" }},
            .children = &[_]Element{.{ .name = "test" }},
        }},
    });
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
            @compileError("can only convert arrays and slices to slices");
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

fn expectOk(comptime parser: var, str: []const u8, consumed: usize, output: var) void {
    var arena = ArenaAllocator.init(heap.page_allocator);
    defer arena.deinit();
    const allocator = &arena.allocator;
    const in = Input{ .str = str, .allocator = allocator };
    const res = parser(in);
    expect(res == .Ok);
    expectEqual(in.consume(consumed), res.Ok.in);
    expectSame(output, res.Ok.out);
}

fn expectErrAtIndex(parser: var, str: []const u8, expected_error: anyerror, index: usize) void {
    var arena = ArenaAllocator.init(heap.page_allocator);
    defer arena.deinit();
    const allocator = &arena.allocator;
    const in = Input{ .str = str, .allocator = allocator };
    const res = parser(in);
    expect(res == .Err);
    expectEqual(in.consume(index), res.Err.in);
    expectEqual(expected_error, res.Err.err);
}
fn expectErr(parser: var, str: []const u8, expected_error: anyerror) void {
    expectErrAtIndex(parser, str, expected_error, 0);
}
