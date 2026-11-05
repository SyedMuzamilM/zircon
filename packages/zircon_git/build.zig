const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const module = b.addModule("zircon_git", .{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = optimize });
    const tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/all.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "zircon_git", .module = module }} }) });
    const parser_tests = b.addTest(.{ .root_module = module });
    const parser_run = b.addRunArtifact(parser_tests);
    const run = b.addRunArtifact(tests);
    run.step.dependOn(&parser_run.step);
    b.step("test", "Exercise Git against temporary repositories").dependOn(&run.step);
    const compile_tests = b.step("test-build", "Compile Git package tests");
    compile_tests.dependOn(&tests.step);
    compile_tests.dependOn(&parser_tests.step);
    const check = b.step("check", "Test Git behavior and formatting");
    check.dependOn(&run.step);
    check.dependOn(&b.addFmt(.{ .paths = &.{ b.path("build.zig"), b.path("src"), b.path("tests") }, .check = true }).step);
}
