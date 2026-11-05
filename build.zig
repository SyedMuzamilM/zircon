//! Framework-first build. Core tests import no native window or GPU modules.
const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const dependency = b.dependency("zircon_ui", .{ .target = target, .optimize = optimize });
    const module = dependency.module("zircon_ui");
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("packages/zircon_ui/tests/entity_tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zircon_ui", .module = module }},
    }) });
    b.step("test-build", "Compile framework tests for the selected target").dependOn(&tests.step);
    const run = b.addRunArtifact(tests);
    b.step("test", "Test entity lifetimes and borrowing without native dependencies").dependOn(&run.step);
    const format = b.addFmt(.{ .paths = &.{ b.path("build.zig"), b.path("packages/zircon_ui/src/entity"), b.path("packages/zircon_ui/src/app"), b.path("packages/zircon_ui/src/testing/headless.zig"), b.path("packages/zircon_ui/tests") }, .check = true });
    b.step("fmt", "Check framework formatting").dependOn(&format.step);
    const check = b.step("check", "Run framework tests and formatting checks");
    check.dependOn(&run.step);
    check.dependOn(&format.step);
    b.getInstallStep().dependOn(check);
}
