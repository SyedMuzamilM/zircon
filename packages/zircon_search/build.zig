const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const text = b.dependency("zircon_text", .{ .target = target, .optimize = optimize }).module("zircon_text");
    const module = b.addModule("zircon_search", .{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "zircon_text", .module = text }} });
    const tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/all.zig"), .target = target, .optimize = optimize, .imports = &.{ .{ .name = "zircon_search", .module = module }, .{ .name = "zircon_text", .module = text } } }) });
    const run = b.addRunArtifact(tests);
    b.step("test", "Test multi-buffer and disk search").dependOn(&run.step);
    b.step("test-build", "Compile portable search tests").dependOn(&tests.step);
    const check = b.step("check", "Run search tests and formatting");
    check.dependOn(&run.step);
    check.dependOn(&b.addFmt(.{ .paths = &.{ b.path("build.zig"), b.path("src"), b.path("tests") }, .check = true }).step);
}
