const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const module = b.addModule("zircon_agent", .{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = optimize });
    const tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/all.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "zircon_agent", .module = module }} }) });
    b.step("test", "Exercise ACP and Codex subprocess protocols").dependOn(&b.addRunArtifact(tests).step);
    b.step("test-build", "Compile portable agent tests").dependOn(&tests.step);
}
