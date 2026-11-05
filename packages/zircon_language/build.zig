const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const text = b.dependency("zircon_text", .{ .target = target, .optimize = optimize }).module("zircon_text");
    const module = b.addModule("zircon_language", .{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "zircon_text", .module = text }} });
    const tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/all.zig"), .target = target, .optimize = optimize, .imports = &.{ .{ .name = "zircon_language", .module = module }, .{ .name = "zircon_text", .module = text } } }) });
    b.step("test", "Verify framing and real language-server subprocesses").dependOn(&b.addRunArtifact(tests).step);
    b.step("test-build", "Compile language client tests").dependOn(&tests.step);
    const fmt = b.addFmt(.{ .paths = &.{ b.path("build.zig"), b.path("src"), b.path("tests") }, .check = true });
    const check = b.step("check", "Verify protocol and formatting");
    check.dependOn(&b.addRunArtifact(tests).step);
    check.dependOn(&fmt.step);
}
