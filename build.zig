const Builder = @import("std").build.Builder;
const std = @import("std");
pub fn build(b: *Builder) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();
    const b_opts = b.addOptions();

    const example = b.addExecutable("example", "examples/example.zig");
    const tests = b.addTest("src/zbox.zig");

    const example_log = b.fmt("{s}/{s}/{s}", .{ b.build_root, b.cache_root, "example.log" });
    b_opts.addOption([]const u8, "log_path", example_log);
    example.addOptions("build_options", b_opts);
    example.setTarget(target);
    example.setBuildMode(mode);
    example.addPackagePath("zbox", "src/zbox.zig");
    example.install();

    tests.setTarget(target);
    tests.setBuildMode(mode);

    const test_step = b.step("test", "run package's test suite");
    test_step.dependOn(&tests.step);
}
