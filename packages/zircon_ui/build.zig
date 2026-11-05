const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const native = b.option(bool, "native", "Enable native macOS windows and Metal") orelse false;
    const module = b.addModule("zircon_ui", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const options = b.addOptions();
    options.addOption(bool, "native", native);
    module.addOptions("zircon_options", options);
    if (native) {
        if (target.result.os.tag != .macos) @panic("native windows currently require macOS");
        module.link_libc = true;
        for ([_][]const u8{ "AppKit", "Metal", "QuartzCore", "CoreText", "CoreGraphics", "CoreFoundation", "Foundation" }) |framework| module.linkFramework(framework, .{});
        module.linkSystemLibrary("objc", .{});
    }
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/all.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zircon_ui", .module = module }},
    }) });
    b.step("test", "Test the framework without a display or GPU").dependOn(&b.addRunArtifact(tests).step);
}
