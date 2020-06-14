const std = @import("std");
const testing = std.testing;
pub const Month = @import("dates/month.zig").Month;
pub const Week = @import("dates/week.zig").Week;
pub const Date = @import("dates/date.zig").Date;

comptime {
    if (std.builtin.is_test) {
        _ = @import("dates/date.zig");
        _ = @import("dates/week.zig");
        _ = @import("dates/month.zig");
    }
}
