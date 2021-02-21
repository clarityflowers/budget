const sqlite = @import("sqlite-zig/src/sqlite.zig");
const std = @import("std");
const log = std.log.scoped(.budget);

// SQLite doesn't enforce foreign constrains unless you tell it to

pub fn init(db_filename: [:0]const u8) !void {
    const db_filename_str = db_filename[0 .. db_filename.len - 1];
    log.info("Initializing budget {s}...", .{db_filename_str});
    const cwd = std.fs.cwd();
    if (cwd.accessZ(db_filename, .{})) {
        log.alert("Attempting to initialize a budget that already exists!", .{});
        return error.InvalidArguments;
    } else |err| {
        switch (err) {
            error.FileNotFound => {},
            else => |other_err| return other_err,
        }
    }

    var db = sqlite.Database.openWithOptions(db_filename, .{}) catch |err| {
        log.alert("The database file {x} couldn't be opened.", .{db_filename});
        return err;
    };
    errdefer cwd.deleteFile(db_filename) catch {};
    defer db.close() catch unreachable;

    try db.prepareEach(@embedFile("init.sql")).finish();
    log.info("All done! Your budget has been initialized at {s}.", .{db_filename});
}
