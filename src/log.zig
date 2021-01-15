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

var logfile: ?std.fs.File = null;

pub fn log(
    comptime log_level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    const stderr_file = if (logfile) |f| f else std.io.getStdErr();
    const stderr = stderr_file.writer();
    const include_scope = !std.io.getStdIn().isTty() or !std.io.getStdOut().isTty();

    if (@enumToInt(log_level) > @enumToInt(std.log.level)) return;

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
}

const logfile_path = "budget.log";

pub fn openLogfile() !void {
    logfile = try std.fs.cwd().createFile(logfile_path, .{ .read = true });
}

pub fn printLogfile() void {
    if (logfile) |file| {
        const stderr = std.io.getStdErr().writer();
        file.seekTo(0) catch {};
        const reader = file.reader();
        const buffer_size = 256;
        var buffer: [buffer_size]u8 = undefined;
        while (true) {
            const len = reader.read(&buffer) catch break;
            stderr.writeAll(buffer[0..len]) catch {};
            if (len < buffer_size) break;
        }
        file.setEndPos(0) catch {};
    }
}

pub fn closeLogfile() void {
    printLogfile();
    if (logfile) |file| {
        file.close();
        std.fs.cwd().deleteFile(logfile_path) catch {};
    }
}
