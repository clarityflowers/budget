const std = @import("std");

amount: i64,
negative_zero: bool = false,

pub fn format(
    self: @This(),
    fmt: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) @TypeOf(writer).Error!void {
    var buffer: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(buffer[0..]);
    const fbs_writer = fbs.writer();
    if (self.amount < 0 or (self.negative_zero and self.amount == 0)) {
        fbs_writer.writeByte('-') catch {};
    }
    var amount = @intCast(u64, if (self.amount < 0) -self.amount else self.amount);
    fbs_writer.print("${d}.{d:0>2}", .{ amount / 100, amount % 100 }) catch {};
    try std.fmt.formatText(fbs.getWritten(), "s", options, writer);
}
