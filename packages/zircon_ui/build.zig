const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const taffy = b.option(bool, "taffy", "Use Taffy for native-target row and column arrangement") orelse false;
    const optimize = b.standardOptimizeOption(.{});
    const native = b.option(bool, "native", "Enable native macOS windows and Metal") orelse false;
    const module = b.addModule("zircon_ui", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const options = b.addOptions();
    options.addOption(bool, "native", native);
    options.addOption(bool, "taffy", taffy);
    module.addOptions("zircon_options", options);
    if (taffy) {
        if (!target.query.isNativeTriple() or (target.result.os.tag != .linux and target.result.os.tag != .macos))
            @panic("Taffy currently supports host Linux and macOS targets");
        const cargo = b.addSystemCommand(&.{ "cargo", "build", "--release", "--locked", "--manifest-path" });
        cargo.addFileArg(b.path("taffy/Cargo.toml"));
        cargo.addFileInput(b.path("taffy/Cargo.lock"));
        cargo.addFileInput(b.path("taffy/src/lib.rs"));
        cargo.addArg("--target-dir");
        const output = cargo.addOutputDirectoryArg("cargo-target");
        const archive = output.path(b, "release/libzircon_taffy.a");
        b.addNamedLazyPath("taffy_archive", archive);
        module.addObjectFile(archive);
        if (target.result.os.tag == .linux) module.linkSystemLibrary("gcc_s", .{});
        module.link_libc = true;
    }
    if (native) {
        if (target.result.os.tag != .macos) @panic("native windows currently require macOS");
        module.link_libc = true;
        for ([_][]const u8{ "AppKit", "Metal", "QuartzCore", "CoreText", "CoreGraphics", "ImageIO", "CoreFoundation", "Foundation" }) |framework| module.linkFramework(framework, .{});
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
