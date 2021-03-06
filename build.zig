const Builder = @import("std").build.Builder;

pub fn build(b: *Builder) void {
    const mode = b.standardReleaseOptions();
    // const lib = b.addStaticLibrary("budget", "src/main_lib.zig");
    // lib.setBuildMode(mode);
    // lib.install();

    const exe = b.addExecutable("budget", "src/main_cli.zig");
    exe.setBuildMode(mode);
    exe.addIncludeDir("include");
    exe.addIncludeDir("/usr/local/Cellar/sqlite/3.32.3/include/");
    exe.addLibPath("/usr/local/opt/ncurses/lib");
    exe.linkSystemLibrary("c");
    exe.linkSystemLibrary("ncursesw");
    exe.linkSystemLibrary("sqlite3");
    exe.install();

    const run_cmd = exe.run();
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    var main_tests = b.addTest("src/main_test.zig");
    main_tests.setBuildMode(mode);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&main_tests.step);
}
