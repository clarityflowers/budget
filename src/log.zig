const std = @import("std");
const ncurses = @import("cli/ncurses.zig");
pub usingnamespace std.log.scoped(.budget);

fn getColorForLevel(comptime log_level: std.log.Level) []const u8 {
    return switch (log_level) {
        .emerg, .alert, .crit, .err => "\x1B[1;91m", // red
        .warn => "\x1B[1;93m", // yellow
        else => "",
    };
}

var use_colors: bool = true;
var level = switch (builtin.mode) {
    .Debug => .debug,
    .ReleaseSafe, .ReleaseFast, .ReleaseSmall => .info,
};

pub fn log(
    comptime log_level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    const stderr_file = std.io.getStdErr();
    const stderr = stderr_file.writer();
    const include_scope = !std.io.getStdIn().isTty() or !std.io.getStdOut().isTty();

    if (@enumToInt(log_level) > @enumToInt(std.log.level)) return;
    const needs_end = ncurses.isEnd() == false;
    if (needs_end) ncurses.end();

    if (use_colors) {
        comptime const color_for_level = getColorForLevel(log_level);
        const suffix = if (color_for_level.len > 0) "\x1B[0m" else "";
        if (include_scope) {
            nosuspend stderr.print(
                color_for_level ++ "budget: " ++ format ++ suffix ++ "\n",
                args,
            ) catch return;
        } else {
            nosuspend stderr.print(color_for_level ++ format ++ suffix ++ "\n", args) catch return;
        }
    } else {
        const level_tag = "[" ++ @tagName(log_level) ++ "] ";
        if (include_scope) {
            nosuspend stderr.print("budget: " ++ level_tag ++ format ++ "\n", args) catch return;
        } else {
            nosuspend stderr.print(level_tag ++ format ++ "\n", args) catch return;
        }
    }
    if (needs_end) {
        if (ncurses.getStdScreen()) |window| {
            window.refresh() catch {};
        }
    }
}
