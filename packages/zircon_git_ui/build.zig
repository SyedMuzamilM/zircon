const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const native = b.option(bool, "native", "Enable native rendering") orelse false;
    const zircon_ui = b.dependency("zircon_ui", .{ .target = target, .optimize = optimize, .native = native }).module("zircon_ui");
    const zircon_editor = b.dependency("zircon_editor", .{ .target = target, .optimize = optimize, .native = native }).module("zircon_editor");
    const zircon_text = b.dependency("zircon_text", .{ .target = target, .optimize = optimize }).module("zircon_text");
    const zircon_workspace = b.dependency("zircon_workspace", .{ .target = target, .optimize = optimize }).module("zircon_workspace");
    const zircon_multibuffer = b.dependency("zircon_multibuffer", .{ .target = target, .optimize = optimize }).module("zircon_multibuffer");
    const zircon_git = b.dependency("zircon_git", .{ .target = target, .optimize = optimize }).module("zircon_git");
    const zircon_widgets = b.dependency("zircon_widgets", .{ .target = target, .optimize = optimize, .native = native }).module("zircon_widgets");
    const module = b.addModule("zircon_git_ui", .{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = optimize, .imports = &.{
        .{ .name = "zircon_ui", .module = zircon_ui },
        .{ .name = "zircon_editor", .module = zircon_editor },
        .{ .name = "zircon_text", .module = zircon_text },
        .{ .name = "zircon_workspace", .module = zircon_workspace },
        .{ .name = "zircon_multibuffer", .module = zircon_multibuffer },
        .{ .name = "zircon_git", .module = zircon_git },
        .{ .name = "zircon_widgets", .module = zircon_widgets },
    } });
    const tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/all.zig"), .target = target, .optimize = optimize, .imports = &.{
        .{ .name = "zircon_git_ui", .module = module },
        .{ .name = "zircon_ui", .module = zircon_ui },
        .{ .name = "zircon_editor", .module = zircon_editor },
        .{ .name = "zircon_text", .module = zircon_text },
        .{ .name = "zircon_workspace", .module = zircon_workspace },
        .{ .name = "zircon_multibuffer", .module = zircon_multibuffer },
        .{ .name = "zircon_git", .module = zircon_git },
        .{ .name = "zircon_widgets", .module = zircon_widgets },
    } }) });
    b.step("test", "Run package tests").dependOn(&b.addRunArtifact(tests).step);
}
