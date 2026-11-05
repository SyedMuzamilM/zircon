const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const text = b.dependency("zircon_text", .{ .target = target, .optimize = optimize });
    const module = b.addModule("zircon_workspace", .{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "zircon_text", .module = text.module("zircon_text") }} });
    const tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/all.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "zircon_workspace", .module = module }} }) });
    b.step("test", "Verify workspace files and lifecycle").dependOn(&b.addRunArtifact(tests).step);
    b.step("test-build", "Compile workspace tests").dependOn(&tests.step);
}
