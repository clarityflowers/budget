const std = @import("std");
const logger = @import("log.zig");
const account_actions = @import("account.zig");
const zig_args = @import("args.zig");
const sqlite = @import("sqlite-zig/src/sqlite.zig");
const DelimitedValueReader = @import("dsv.zig").DelimitedValueReader;
const import_actions = @import("import.zig");
const cli = @import("cli.zig");

pub const log = logger.log;

const ParseArgsResult = zig_args.ParseArgsResult;

pub fn MemPerfAllocator(comptime active: bool) type {
    return struct {
        const GPA = std.heap.GeneralPurposeAllocator(.{ .enable_memory_limit = active });

        gpa: GPA = .{},
        max_allocated: usize = 0,
        allocator: std.mem.Allocator = if (active)
            .{
                .resizeFn = resize,
                .allocFn = alloc,
            }
        else
            gpa.allocator,

        pub fn resize(allocator: *std.mem.Allocator, buf: []u8, buf_align: u29, new_len: usize, len_align: u29, ret_addr: usize) !usize {
            var self = @fieldParentPtr(@This(), "allocator", allocator);
            const result = try self.gpa.allocator.resizeFn(&self.gpa.allocator, buf, buf_align, new_len, len_align, ret_addr);
            self.max_allocated = std.math.max(self.gpa.total_requested_bytes, self.max_allocated);
            return result;
        }

        pub fn alloc(allocator: *std.mem.Allocator, len: usize, ptr_align: u29, len_align: u29, ret_addr: usize) ![]u8 {
            var self = @fieldParentPtr(@This(), "allocator", allocator);
            const result = try self.gpa.allocator.allocFn(&self.gpa.allocator, len, ptr_align, len_align, ret_addr);
            self.max_allocated = std.math.max(self.gpa.total_requested_bytes, self.max_allocated);
            return result;
        }

        pub fn deinit(self: *@This()) void {
            _ = self.gpa.deinit();
        }
    };
}

pub const Bytes = struct {
    value: usize,

    const KILOBYTE = 1024;
    const MEGABYTE = KILOBYTE * 1024;
    const GIGABYTE = MEGABYTE * 1024;
    pub fn format(
        self: @This(),
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        if (self.value >= GIGABYTE) {
            try writer.print("{d:0.1}GB", .{@intToFloat(f32, self.value) / GIGABYTE});
        } else if (self.value >= MEGABYTE) {
            try writer.print("{d:0.1}MB", .{@intToFloat(f32, self.value) / MEGABYTE});
        } else if (self.value >= KILOBYTE) {
            try writer.print("{d:0.1}KB", .{@intToFloat(f32, self.value) / KILOBYTE});
        } else {
            try writer.print("{d}B", .{self.value});
        }
    }
};

pub fn mainWrapped() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        _ = gpa.deinit();
    }
    var arena = std.heap.ArenaAllocator.init(&gpa.allocator);
    defer arena.deinit();
    try zig_args.parseAndRun(Spec, &arena.allocator, Context{ .allocator = &arena.allocator });
}

pub fn main() !u8 {
    mainWrapped() catch |err| switch (err) {
        error.InvalidArguments => {
            if (std.builtin.mode == .Debug) return err;
            return 1;
        },
        error.Interrupted => {
            if (std.builtin.link_libc or std.builtin.os.tag == .linux) {
                std.os.raise(std.os.SIGINT) catch {};
            }
            return 1;
        },
        else => |other_error| {
            if (std.builtin.mode == .Debug) return err;
            logger.alert("{}", .{@errorName(other_error)});
            return 1;
        },
    };
    return 0;
}

pub const Context = struct {
    allocator: *std.mem.Allocator
};

const Spec = union(enum) {
    init: struct {
        budget: ?[]const u8,

        pub fn exec(result: ParseArgsResult(@This()), context: Context) !void {
            const db_file = try getBudgetFilePath(result.options, context.allocator);
            try @import("init.zig").init(db_file);
        }
    },
    convert: struct {
        _: struct {
            account: []const u8
        },
        budget: ?[]const u8,

        pub fn exec(result: ParseArgsResult(@This()), context: Context) !void {
            const db_file = try getBudgetFilePath(result.options, context.allocator);
            const db = try sqlite.Database.openWithOptions(db_file, .{ .mode = .readonly });
            const column_input = try std.io.getStdIn().reader().readUntilDelimiterAlloc(context.allocator, '\n', 1024 * 1024);
            const rules = try account_actions.getImportRules(&db, result.options._.account, column_input, context.allocator);
            std.debug.print("{}\n", .{rules});
        }
    },
    configure: union(enum) {
        import: struct {
            _: struct {
                name: []const u8,
                date_column: []const u8,
                date_format: []const u8,
                income_column: []const u8,
                expenses_column: []const u8,
            },
            payee: ?[]const u8,
            memo: ?[]const u8,
            id: ?[]const u8,
            budget: ?[]const u8,
            type: account_actions.FileType = .csv,

            pub fn exec(result: ParseArgsResult(@This()), context: Context) !void {
                const db_file = try getBudgetFilePath(result.options, context.allocator);
                try account_actions.configureImport(db_file, .{
                    .account_name = result.options._.name,
                    .date_column = result.options._.date_column,
                    .date_format = result.options._.date_format,
                    .income_column = result.options._.income_column,
                    .expenses_column = result.options._.expenses_column,
                    .payee_columns = result.options.payee,
                    .memo_columns = result.options.memo,
                    .id_columns = result.options.id,
                    .file_type = result.options.type,
                });
            }
        }
    },
    import: struct {
        _: struct {
            name: []const u8,
        },
        budget: ?[]const u8,
        file: ?[]const u8,

        pub fn exec(result: ParseArgsResult(@This()), context: Context) !void {
            const db_file = try getBudgetFilePath(result.options, context.allocator);
            const db = try sqlite.Database.openWithOptions(db_file, .{ .mode = .readwrite });
            const reader = if (result.options.file) |file|
                (try std.fs.cwd().openFile(file, .{})).reader()
            else
                std.io.getStdIn().reader();
            var prepared_import = try import_actions.prepareImport(
                &db,
                result.options._.name,
                reader,
                context.allocator,
            );
            try cli.runInteractiveImport(&db, &prepared_import, context.allocator);
        }
    },
    account: union(enum) {
        create: struct {
            _: struct {
                name: []const u8,
                type: account_actions.AccountType,
            },
            budget: ?[]const u8,
            exclude_from_budget: bool,

            pub fn exec(result: ParseArgsResult(@This()), context: Context) !void {
                const db_file = try getBudgetFilePath(result.options, context.allocator);
                try account_actions.create(
                    db_file,
                    result.options._.name,
                    result.options._.type,
                    !result.options.exclude_from_budget,
                );
            }
        },
        // list: struct {
        //     budget: ?[]const u8,
        //     pub fn exec(result: ParseArgsResult(@This()), context: Context) !void {
        //         const db_file = try getBudgetFilePath(result.options, context.allocator);
        //         const db = try sqlite.Database.openWithOptions(db_file, .{ .mode = .readonly });
        //         const accounts = try account_actions.getAccounts(&db, context.allocator);
        //         const stdout = std.io.getStdOut().writer();
        //         for (accounts) |account| {
        //             try stdout.print("{}\n", .{account.name});
        //         }
        //     }
        // },
    },
};

//  lets stay focused next time yea? remember that i love u <3
//  - [x] how do we set up import rules?
//  - [x] consume & parse import rules
//  - [x] get import rules out of db
//  - [x] perform conversion
//  - [x] delete already existing transactions
//  - [x] how does autofill get configured?
//  - [x] autofill payees
//  - [x] autofill categories
//  - [ ] oh jeez that means its time to build the interactive part
//      - [x] display current transaction
//      - [x] enter/shift+enter to move between transactions
//      - [x] tab/shift+tab to move between columns
//      - [x] typing to insert new values
//      - [x] autocomplete
//      - [x] set up new autocompletes
//      - [x] altering existing autocompletes
//      - [x] set note
//      - [x] set date
//      - [ ] set amount
//      - [ ] split transactions
//      - [ ] add new transaction
//      - [ ] check totals
//      - [ ] sql mode
//      - [ ] run arbitrary command
//
//  don't work on these things yet!!!
//  - [ ] help text
//
//  out of scope
//  - cli
//      - rename categories & groups
//      - create auto-splits

pub fn getBudgetFilePath(options: anytype, allocator: *std.mem.Allocator) ![:0]const u8 {
    const slice = options.budget orelse (std.process.getEnvVarOwned(allocator, "BUDGET_PATH") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => blk: {
            logger.notice("No budget file was provided, so using ./my-budget.db as a default. To use a different path, use the --budget option or set the $BUDGET_PATH environment variable.", .{});
            break :blk "./my-budget.db";
        },
        else => |other_err| return other_err,
    });
    defer if (options.budget != null) allocator.free(slice);

    const zero_terminated = try allocator.allocWithOptions(u8, slice.len, null, 0);
    errdefer allocator.free(zero_terminated);
    std.mem.copy(u8, zero_terminated, slice);
    return zero_terminated;
}

pub fn panic(msg: []const u8, error_return_trace: ?*std.builtin.StackTrace) noreturn {
    @import("cli/ncurses.zig").end();
    std.builtin.default_panic(msg, error_return_trace);
}
