const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const taffy = b.option(bool, "taffy", "Use Taffy for native-target row and column arrangement") orelse false;
    const optimize = b.standardOptimizeOption(.{});
    const native = b.option(bool, "native", "Enable native framework windows") orelse false;
    const text = b.dependency("zircon_text", .{ .target = target, .optimize = optimize }).module("zircon_text");
    const ui = b.dependency("zircon_ui", .{ .target = target, .optimize = optimize, .native = native, .taffy = taffy }).module("zircon_ui");
    const module = b.addModule("zircon_editor", .{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = optimize, .imports = &.{ .{ .name = "zircon_text", .module = text }, .{ .name = "zircon_ui", .module = ui } } });
    const tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/all.zig"), .target = target, .optimize = optimize, .imports = &.{ .{ .name = "zircon_editor", .module = module }, .{ .name = "zircon_text", .module = text }, .{ .name = "zircon_ui", .module = ui } } }) });
    b.step("test", "Verify editing, syntax, geometry and custom canvas").dependOn(&b.addRunArtifact(tests).step);
    b.step("test-build", "Compile editor tests").dependOn(&tests.step);
}
