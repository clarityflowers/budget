const std = @import("std");

pub const ColumnSize = u8;

pub fn Writer(comptime columns: []const ColumnSize, comptime InnerWriter: type) type {
    return struct {
        pub const Error = InnerWriter.Error || error{TruncatedPrint};
        pub const Writer = std.io.Writer(*@This(), Error, write);

        inner_writer: InnerWriter,
        truncated_writer: ?ColumnWriter = null,
        row: usize = 0,
        column: usize = null,
        index: usize = 0,

        pub fn columnWriter(self: *@This()) Writer {
            return .{ .context = self };
        }

        fn write(self: *@This(), buffer: []const u8) Error!usize {
            // -1 to ensure that the last character of each column is a space,
            // for readability
            const amount_to_write = std.math.min(
                buffer.len,
                columns[self.current_column] - self.index - 1,
            );
            const amount_written = try self.inner_writer.write(buffer[0..amount_to_write]);
            if (amount_to_write < buffer.len) return error.TruncatedPrint;
            return amount_written;
        }

        pub fn nextColumn() !void {
            while (self.index < columns[self.column]) : (self.index += 1) {
                try self.inner_writer.writeByte(' ');
            }
            if (self.column == columns.len - 1) {
                self.column = 0;
                self.row += 1;
                try self.inner_writer.writeByte('\n');
            } else {
                self.column += 1;
            }
            self.index = 0;
        }

        /// Fill the current column with a value (using std.fmt args), then move
        /// to the next column. Returns error.TruncatedPrint if the result
        /// doesn't fit inside the given column.
        pub fn print(self: *@This(), comptime fmt: []const u8, args: anytype) !void {
            const writer = self.columnWriter();
            try writer.print(fmt, args);
            try self.nextColumn();
        }
    };
}
