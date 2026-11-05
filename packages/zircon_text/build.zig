const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const module = b.addModule("zircon_text", .{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = optimize });
    const tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/all.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "zircon_text", .module = module }} }) });
    b.step("test", "Test persistent documents, snapshots, history and search").dependOn(&b.addRunArtifact(tests).step);
    b.step("test-build", "Compile portable document tests").dependOn(&tests.step);
    const format = b.addFmt(.{ .paths = &.{ b.path("build.zig"), b.path("src"), b.path("tests") }, .check = true });
    const check = b.step("check", "Test and check package formatting");
    check.dependOn(&b.addRunArtifact(tests).step);
    check.dependOn(&format.step);
}
