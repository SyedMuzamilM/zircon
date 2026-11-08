const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const text = b.dependency("zircon_text", .{ .target = target, .optimize = optimize }).module("zircon_text");
    const workspace = b.dependency("zircon_workspace", .{ .target = target, .optimize = optimize }).module("zircon_workspace");
    const module = b.addModule("zircon_multibuffer", .{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = optimize, .imports = &.{ .{ .name = "zircon_text", .module = text }, .{ .name = "zircon_workspace", .module = workspace } } });
    const tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/all.zig"), .target = target, .optimize = optimize, .imports = &.{ .{ .name = "zircon_multibuffer", .module = module }, .{ .name = "zircon_text", .module = text }, .{ .name = "zircon_workspace", .module = workspace } } }) });
    const run = b.addRunArtifact(tests);
    b.step("test", "Test source identity, excerpt anchors and grouped edits").dependOn(&run.step);
    b.step("test-build", "Compile multibuffer tests").dependOn(&tests.step);
    b.step("check", "Run multibuffer tests and formatting").dependOn(&run.step);
}
