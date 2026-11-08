const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const native = b.option(bool, "native", "Enable native rendering") orelse false;
    const zircon_ui = b.dependency("zircon_ui", .{ .target = target, .optimize = optimize, .native = native }).module("zircon_ui");
    const module = b.addModule("zircon_widgets", .{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = optimize, .imports = &.{
        .{ .name = "zircon_ui", .module = zircon_ui },
    } });
    const tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/all.zig"), .target = target, .optimize = optimize, .imports = &.{
        .{ .name = "zircon_widgets", .module = module },
        .{ .name = "zircon_ui", .module = zircon_ui },
    } }) });
    b.step("test", "Run package tests").dependOn(&b.addRunArtifact(tests).step);
}
