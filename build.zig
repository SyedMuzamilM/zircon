//! Framework-first build. Core tests import no native window or GPU modules.
const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const dependency = b.dependency("zircon_ui", .{ .target = target, .optimize = optimize });
    const module = dependency.module("zircon_ui");
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("packages/zircon_ui/tests/all.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zircon_ui", .module = module }},
    }) });
    b.step("test-build", "Compile framework tests for the selected target").dependOn(&tests.step);
    const run = b.addRunArtifact(tests);
    b.step("test", "Test entity lifetimes and borrowing without native dependencies").dependOn(&run.step);
    const example = b.addExecutable(.{ .name = "counter-tree", .root_module = b.createModule(.{
        .root_source_file = b.path("examples/counter/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zircon_ui", .module = module }},
    }) });
    const example_run = b.addRunArtifact(example);
    b.step("counter", "Inspect a declarative counter without a window").dependOn(&example_run.step);
    const format = b.addFmt(.{ .paths = &.{ b.path("build.zig"), b.path("examples"), b.path("packages/zircon_ui/src/root.zig"), b.path("packages/zircon_ui/src/ui"), b.path("packages/zircon_ui/src/layout"), b.path("packages/zircon_ui/src/event"), b.path("packages/zircon_ui/src/entity"), b.path("packages/zircon_ui/src/app"), b.path("packages/zircon_ui/src/testing/headless.zig"), b.path("packages/zircon_ui/tests") }, .check = true });
    b.step("fmt", "Check framework formatting").dependOn(&format.step);
    const contracts = b.step("contracts", "Check compile-time view, handler, and result contracts");
    for ([_][2][]const u8{
        .{ "mutable_render", "render must receive (*const Self, *Ui)" },
        .{ "borrowed_read", "read/update results cannot borrow pointers or slices; copy into a caller-owned output argument" },
        .{ "invalid_handler", "onClick requires fn (*Self, *Event(Click), *Context(Self)) !void" },
    }) |fixture| {
        const invalid = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path(b.fmt("packages/zircon_ui/tests/compile_fail/{s}.zig", .{fixture[0]})),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zircon_ui", .module = module }},
        }) });
        invalid.expect_errors = .{ .contains = fixture[1] };
        contracts.dependOn(&invalid.step);
    }
    const check = b.step("check", "Run framework tests and formatting checks");
    check.dependOn(contracts);
    check.dependOn(&run.step);
    check.dependOn(&format.step);
    b.getInstallStep().dependOn(check);
}
