const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;

const fmt = std.fmt;
const math = std.math;

const testing = std.testing;
const expectEqualSlices = testing.expectEqualSlices;
const expectError = testing.expectError;

const parse = @import("parse.zig");
const Date = @import("dates.zig").Date;

pub const DelimitedValueReader = struct {
    delimiter: u8 = ',',
    token_start: usize = 0,
    line: []const u8,

    /// the value's lifetime is the same as the line's
    pub fn nextValue(self: *@This()) ?[]const u8 {
        if (self.token_start >= self.line.len) return null;
        const quoted = self.line[self.token_start] == '"';
        if (quoted) self.token_start += 1;
        var token_end = self.token_start;
        while (token_end < self.line.len) : (token_end += 1) {
            const token = self.line[token_end];
            if (quoted) {
                if (token == '"' and (token_end == self.line.len - 2 or self.line[token_end + 1] == self.delimiter)) {
                    break;
                }
            } else if (token == self.delimiter) {
                break;
            }
        }

        const result = self.line[self.token_start..token_end];
        if (quoted) token_end += 1;
        self.token_start = token_end + 1;
        return result;
    }

    /// Appends all values in the line onto the given array list, and returns a span containing
    /// those values.
    pub fn collectIntoArrayList(self: *@This(), list: *std.ArrayList([]const u8)) ![][]const u8 {
        const start = list.items.len;
        while (self.nextValue()) |value| {
            try list.append(value);
        }
        return list.items[start..];
    }

    /// Returns all of the values in the line into a caller-owned slice.
    pub fn collect(self: *@This(), allocator: *std.mem.Allocator) ![][]const u8 {
        var list = std.ArrayList([]const u8).init(allocator);
        errdefer list.deinit();
        return try self.collectIntoArrayList(&list);
    }

    pub fn nextValueAsCents(self: *@This(), comptime T: type) !T {
        return try parse.parseCents(T, try self.nextValue());
    }

    pub fn nextValueAsDate(self: *@This()) !Date {
        return try Date.parse(try self.nextValue());
    }
};

test "read quoted csv" {
    const csv =
        \\"hello, world!","value 2","value 3"
    ;
    var reader = DelimitedValueReader(','){ .line = csv };
    expectEqualSlices(u8, "hello, world!", try reader.nextValue());
    expectEqualSlices(u8, "value 2", try reader.nextValue());
    expectEqualSlices(u8, "value 3", try reader.nextValue());
    expectError(error.NoMoreValues, reader.nextValue());
}
test "read tsv" {
    const tsv =
        \\hello, world!	value 2	value 3
    ;
    var reader = DelimitedValueReader('\t'){ .line = tsv };
    expectEqualSlices(u8, "hello, world!", try reader.nextValue());
    expectEqualSlices(u8, "value 2", try reader.nextValue());
    expectEqualSlices(u8, "value 3", try reader.nextValue());
    expectError(error.NoMoreValues, reader.nextValue());
}

pub fn LineReader(comptime Stream: type, max_line_size: usize) type {
    return struct {
        stream: Stream,
        current_line: ArrayList(u8),
        end_of_stream: bool = false,

        pub fn init(stream: Stream, allocator: *Allocator) @This() {
            return @This(){
                .stream = stream,
                .current_line = ArrayList(u8).init(allocator),
            };
        }

        pub fn deinit(self: *@This()) void {
            self.current_line.deinit();
        }

        /// each line is valid until the next line is accessed
        pub fn nextLine(self: *@This()) !?[]u8 {
            if (self.end_of_stream) return null;
            self.stream.readUntilDelimiterArrayList(&self.current_line, '\n', max_line_size) catch |err| switch (err) {
                error.EndOfStream => self.end_of_stream = true,
                else => return err,
            };
            return self.current_line.items;
        }
    };
}

pub fn lineReader(
    stream: anytype,
    max_line_size: usize,
    allocator: *std.mem.Allocator,
) LineReader(@TypeOf(stream), max_line_size) {
    return LineReader(@typeOf(stream, max_line_size)).init(stream, allocator);
}

pub fn DelimitedRecordReader(comptime Stream: type, comptime delimiter: u8, max_line_size: usize) type {
    return struct {
        reader: LineReader(Stream, max_line_size),

        pub fn init(stream: Stream, allocator: *Allocator) @This() {
            return @This(){
                .reader = LineReader(Stream, max_line_size).init(stream, allocator),
            };
        }

        pub fn deinit(self: *@This()) void {
            self.reader.deinit();
        }

        /// each line is valid until the next line is accessed
        pub fn nextLine(self: *@This()) !?DelimitedValueReader(delimiter) {
            if (try self.reader.nextLine()) |line| {
                return DelimitedValueReader(delimiter){ .line = line };
            }
            return null;
        }
    };
}
