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
    if (target.result.os.tag == .macos) {
        const native_dependency = b.dependency("zircon_ui", .{ .target = target, .optimize = optimize, .native = true });
        const native_ui = native_dependency.module("zircon_ui");
        const counter_native = b.addExecutable(.{ .name = "zircon-counter", .root_module = b.createModule(.{
            .root_source_file = b.path("examples/counter_native/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zircon_ui", .module = native_ui }},
        }) });
        b.step("counter-native", "Open the native framework counter").dependOn(&b.addRunArtifact(counter_native).step);
        b.step("build-native", "Compile native framework applications").dependOn(&counter_native.step);
        const native = b.createModule(.{ .root_source_file = b.path("packages/zircon_ui/src/native_test_root.zig"), .target = target, .optimize = optimize, .link_libc = true });
        const native_options = b.addOptions();
        native_options.addOption(bool, "native", true);
        native.addOptions("zircon_options", native_options);
        for ([_][]const u8{ "AppKit", "Metal", "QuartzCore", "CoreText", "CoreGraphics", "CoreFoundation", "Foundation" }) |framework| native.linkFramework(framework, .{});
        native.linkSystemLibrary("objc", .{});
        const native_tests = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path("packages/zircon_ui/tests/native_all.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "native", .module = native }},
        }) });
        const window_tests = b.addTest(.{ .root_module = native });
        const window_run = b.addRunArtifact(window_tests);
        const native_run = b.addRunArtifact(native_tests);
        native_run.step.dependOn(&window_run.step);
        b.step("test-native", "Verify native windows, input, CoreText and Metal").dependOn(&native_run.step);
    }
    const format = b.addFmt(.{ .paths = &.{ b.path("build.zig"), b.path("packages/zircon_ui"), b.path("examples") }, .check = true });
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
