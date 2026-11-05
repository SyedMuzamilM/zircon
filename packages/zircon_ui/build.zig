const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const module = b.addModule("zircon_ui", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/entity_tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zircon_ui", .module = module }},
    }) });
    b.step("test", "Test the framework without a display or GPU").dependOn(&b.addRunArtifact(tests).step);
}
