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

const parse = @import("parser.zig");
const pair = parse.pair;
const right = parse.right;
const left = parse.left;
const literal = parse.literal;
const anyNumberOf = parse.anyNumberOf;
const pred = parse.pred;
const anyChar = parse.anyChar;
const someSpaces = parse.someSpaces;
const anyNumberOfSpaces = parse.anyNumberOfSpaces;
const map = parse.map;
const then = parse.then;
const wrappedInWhitespace = parse.wrappedInWhitespace;
const either = parse.either;

inline fn isAlpha(char: u8) bool {
    return (char >= 'a' and char <= 'z') or (char >= 'A' and char <= 'Z');
}
inline fn isNum(char: u8) bool {
    return char >= '0' and char <= '9';
}
inline fn isAlphaNum(char: u8) bool {
    return isAlpha(char) or isNum(char);
}
pub fn identifier(state: *parse.State, index: usize) parse.Error!parse.Result([]const u8) {
    var len: usize = 0;
    const str = state.get(index);
    if (str.len == 0) {
        try state.fail(index, error.EmptyIdentifier);
        return error.NotParsed;
    }
    if (isAlpha(str[0])) {
        len += 1;
    } else {
        try state.fail(index, error.NotAnIdentifier);
        return error.NotParsed;
    }
    for (str[1..]) |char| {
        if (isAlphaNum(char) or char == '-') {
            len += 1;
        } else {
            break;
        }
    }
    return parse.pass(index + len, str[0..len]);
}

test "identifier" {
    var arena = ArenaAllocator.init(heap.page_allocator);
    defer arena.deinit();
    const allocator = &arena.allocator;

    comptime const parser = identifier;
    const ident1 = "i-am-an-identifier";
    const state = &parse.State.init(ident1, allocator);
    state.expectSuccess(parser, ident1.len, ident1);
    const ident2 = "not entirely an identifier";
    state.reset(ident2).expectSuccess(parser, "not".len, "not");
    state.reset("!not at all an identifier").expectFailure(parser, error.NotAnIdentifier, 0).expectLast();
    state.reset("").expectFailure(parser, error.EmptyIdentifier, 0).expectLast();
}

inline fn isNotQuote(char: u8) bool {
    return char != '"';
}

pub const quotedString = right(literal("\""), left(anyNumberOf(pred(anyChar, isNotQuote)), literal("\"")));

test "quotedString" {
    var arena = ArenaAllocator.init(heap.page_allocator);
    defer arena.deinit();
    const allocator = &arena.allocator;

    const state = &parse.State.init("\"hello, world,\" she said", allocator);
    state.expectSuccess(quotedString, "\"hello, world,\"".len, "hello, world,");
    state.reset("\"hello, world,").expectFailure(quotedString, error.PairMissingRight, "\"".len).expectChild(error.PairMissingRight, "\"hello, world,".len).expectChild(error.MatchLiteral, "\"hello, world,".len).expectLast();
    state.reset("hello world").expectFailure(quotedString, error.PairMissingLeft, 0).expectChild(error.MatchLiteral, 0).expectLast();
}

pub const AttributePair = parse.Pair([]const u8, []const u8);
pub const Attribute = struct {
    key: []const u8, value: []const u8
};
fn toAttribute(attribute_pair: AttributePair) Attribute {
    return .{
        .key = attribute_pair.lh,
        .value = attribute_pair.rh,
    };
}
pub const attributePair = map(pair(identifier, right(literal("="), quotedString)), toAttribute);

pub const attributes = anyNumberOf(right(someSpaces, attributePair));

test "attributes" {
    var arena = ArenaAllocator.init(heap.page_allocator);
    defer arena.deinit();
    const allocator = &arena.allocator;

    const state = &parse.State.init(" one=\"1\" two=\"2\"", allocator);
    state.expectSuccess(attributes, " one=\"1\" two=\"2\"".len, [_]Attribute{ .{
        .key = "one",
        .value = "1",
    }, .{
        .key = "two",
        .value = "2",
    } });
}

pub const ElementStart = parse.Pair([]const u8, []const Attribute);
pub const elementStart = right(literal("<"), pair(identifier, attributes));

pub const Element = struct {
    name: []const u8, attributes: []const Attribute = &[_]Attribute{}, children: []const Element = &[_]Element{}
};

fn intoElement(start: ElementStart) Element {
    return .{
        .name = start.lh,
        .attributes = start.rh,
    };
}
pub const singleElement = map(left(elementStart, right(anyNumberOfSpaces, literal("/>"))), intoElement);

test "single element" {
    var arena = ArenaAllocator.init(heap.page_allocator);
    defer arena.deinit();
    const allocator = &arena.allocator;

    const str = "<div class=\"zone\" />";
    const state = &parse.State.init(str, allocator);
    state.expectSuccess(singleElement, str.len, Element{
        .name = "div",
        .attributes = &[_]Attribute{.{
            .key = "class",
            .value = "zone",
        }},
    });
}
pub const openElement = map(left(elementStart, right(anyNumberOfSpaces, literal(">"))), intoElement);

const el = return wrappedInWhitespace(either(singleElement, parentElement));
pub fn element(state: *parse.State, index: usize) parse.Error!parse.Result(Element) {
    const res = el(state, index) catch |err| {
        try state.fail(index, error.Element);
        return err;
    };
    return parse.pass(res.index, res.out);
}
pub const childElements = anyNumberOf(element);
pub const closeElementStart = literal("</");
pub const closeElementEnd = right(anyNumberOfSpaces, literal(">"));

const parentStart = left(pair(openElement, childElements), closeElementStart);
fn matchClosingTag(out: parse.OutputOf(parentStart), state: *parse.State, index: usize) parse.Error!parse.Result(Element) {
    errdefer state.allocator.free(out.rh);

    const str = state.get(index);
    const expected = out.lh.name;
    if (str.len < expected.len or !mem.eql(u8, str[0..expected.len], expected)) {
        try state.fail(index, error.ClosingTag);
        return error.NotParsed;
    }
    var final_res = out.lh;
    final_res.children = out.rh;
    return parse.pass(index + expected.len, final_res);
}
pub const parentElement = left(then(parentStart, matchClosingTag), right(anyNumberOfSpaces, literal(">")));

test "parseHtml" {
    var arena = ArenaAllocator.init(heap.page_allocator);
    defer arena.deinit();
    const allocator = &arena.allocator;

    const simplest_str = "<test />";
    const state = &parse.State.init(simplest_str, allocator);
    comptime const parser = element;
    state.expectSuccess(parser, simplest_str.len, Element{ .name = "test" });

    const simple_str =
        \\<p class="part-1" ><test /></p>
    ;
    state.reset(simple_str).expectSuccess(parser, simple_str.len, Element{
        .name = "p",
        .attributes = &[_]Attribute{.{ .key = "class", .value = "part-1" }},
        .children = &[_]Element{.{ .name = "test" }},
    });

    const str =
        \\<article>
        \\  <p class="part-1" ><test /></p>
        \\  <br />
        \\</article>
    ;
    state.reset(str).expectSuccess(parser, str.len, Element{
        .name = "article",
        .children = &[_]Element{ .{
            .name = "p",
            .attributes = &[_]Attribute{.{ .key = "class", .value = "part-1" }},
            .children = &[_]Element{.{ .name = "test" }},
        }, .{ .name = "br" } },
    });
}
