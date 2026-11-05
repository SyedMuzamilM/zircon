const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const module = b.addModule("zircon_markdown", .{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = optimize });
    const tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/all.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "zircon_markdown", .module = module }} }) });
    const run = b.addRunArtifact(tests);
    b.step("test", "Test Markdown blocks, inline spans and source ranges").dependOn(&run.step);
    b.step("test-build", "Compile portable Markdown tests").dependOn(&tests.step);
    const check = b.step("check", "Test and format Markdown package");
    check.dependOn(&run.step);
    check.dependOn(&b.addFmt(.{ .paths = &.{ b.path("build.zig"), b.path("src"), b.path("tests") }, .check = true }).step);
}
