const std = @import("std");
const math = std.math;
const fmt = std.fmt;

const DelimitedValueReader = @import("dsv.zig").DelimitedValueReader;
const Date = @import("date.zig").Date;

pub fn parseCents(comptime T: type, value: []const u8) !T {
    if (value.len == 0) return 0;
    const negative = value[0] == '-';
    const index: usize = if (negative) 1 else 0;
    const number_reader = &DelimitedValueReader{ .delimiter = '.', .line = value[index..] };
    const dollars = try fmt.parseInt(T, number_reader.nextValue() orelse "0", 10);
    const cents_string = number_reader.nextValue() orelse "00";
    var cents = if (cents_string.len == 0) 0 else try fmt.parseInt(i32, cents_string[0..2], 10);
    var res = (dollars * 100) + cents;
    if (negative) res *= -1;
    return res;
}

pub fn parseEnum(comptime Enum: type, str: []const u8) !Enum {
    switch (@typeInfo(Enum)) {
        .Enum => |info| {
            inline for (info.fields) |fld| {
                if (std.mem.eql(u8, str, fld.name)) {
                    return @intToEnum(Enum, fld.value);
                }
            }
            std.log.err("Failed to parse {} as an " ++ @typeName(Enum), .{str});
            return error.FailedToParseEnum;
        },
        else => {
            @compileError("Expected an enum type, found {}" ++ @typeName(Enum));
        },
    }
}
