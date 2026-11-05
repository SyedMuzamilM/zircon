const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const module = b.addModule("zircon_extensions", .{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = optimize });
    module.addAnonymousImport("oxide_manifest", .{ .root_source_file = b.path("examples/oxide/extension.json") });
    const tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/all.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "zircon_extensions", .module = module }} }) });
    const run = b.addRunArtifact(tests);
    b.step("test", "Verify local contribution extensions").dependOn(&run.step);
    b.step("test-build", "Compile extension tests").dependOn(&tests.step);
    const fmt = b.addFmt(.{ .paths = &.{ b.path("build.zig"), b.path("src"), b.path("tests") }, .check = true });
    const check = b.step("check", "Test and format extension package");
    check.dependOn(&run.step);
    check.dependOn(&fmt.step);
}
