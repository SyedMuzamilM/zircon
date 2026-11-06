//! Framework-first build. Core tests import no native window or GPU modules.
const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const dependency = b.dependency("zircon_ui", .{ .target = target, .optimize = optimize, .native = false });
    const module = dependency.module("zircon_ui");
    const text_dependency = b.dependency("zircon_text", .{ .target = target, .optimize = optimize });
    const text_module = text_dependency.module("zircon_text");
    const workspace_dependency = b.dependency("zircon_workspace", .{ .target = target, .optimize = optimize });
    const workspace_module = workspace_dependency.module("zircon_workspace");
    const editor_dependency = b.dependency("zircon_editor", .{ .target = target, .optimize = optimize });
    const editor_module = editor_dependency.module("zircon_editor");
    const git_module = b.dependency("zircon_git", .{ .target = target, .optimize = optimize }).module("zircon_git");
    const extension_module = b.dependency("zircon_extensions", .{ .target = target, .optimize = optimize }).module("zircon_extensions");
    const search_module = b.dependency("zircon_search", .{ .target = target, .optimize = optimize }).module("zircon_search");
    const language_module = b.dependency("zircon_language", .{ .target = target, .optimize = optimize }).module("zircon_language");
    const markdown_module = b.dependency("zircon_markdown", .{ .target = target, .optimize = optimize }).module("zircon_markdown");
    var feature_tests: std.ArrayList(*std.Build.Step.Compile) = .empty;
    var feature_runs: std.ArrayList(*std.Build.Step.Run) = .empty;
    for ([_]struct { name: []const u8, module: *std.Build.Module }{
        .{ .name = "zircon_git", .module = git_module },
        .{ .name = "zircon_extensions", .module = extension_module },
        .{ .name = "zircon_search", .module = search_module },
        .{ .name = "zircon_language", .module = language_module },
        .{ .name = "zircon_markdown", .module = markdown_module },
    }) |feature| {
        const test_module = b.createModule(.{ .root_source_file = b.path(b.fmt("packages/{s}/tests/all.zig", .{feature.name})), .target = target, .optimize = optimize });
        test_module.addImport(feature.name, feature.module);
        test_module.addImport("zircon_text", text_module);
        const artifact = b.addTest(.{ .root_module = test_module });
        const execute = b.addRunArtifact(artifact);
        b.step(b.fmt("test-{s}", .{feature.name[7..]}), b.fmt("Test {s} package", .{feature.name})).dependOn(&execute.step);
        feature_tests.append(b.allocator, artifact) catch @panic("OOM");
        feature_runs.append(b.allocator, execute) catch @panic("OOM");
    }
    const editor_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("packages/zircon_editor/tests/all.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "zircon_editor", .module = editor_module }, .{ .name = "zircon_text", .module = text_module }, .{ .name = "zircon_ui", .module = module } },
    }) });
    const editor_run = b.addRunArtifact(editor_tests);
    b.step("test-editor", "Test editor commands, selections, syntax, and canvas").dependOn(&editor_run.step);
    const app_module = b.createModule(.{
        .root_source_file = b.path("apps/zircon/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "zircon_ui", .module = module }, .{ .name = "zircon_text", .module = text_module }, .{ .name = "zircon_workspace", .module = workspace_module }, .{ .name = "zircon_editor", .module = editor_module }, .{ .name = "zircon_git", .module = git_module }, .{ .name = "zircon_extensions", .module = extension_module }, .{ .name = "zircon_search", .module = search_module }, .{ .name = "zircon_language", .module = language_module }, .{ .name = "zircon_markdown", .module = markdown_module } },
    });
    const app_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("apps/zircon/tests/all.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "zircon", .module = app_module }, .{ .name = "zircon_ui", .module = module }, .{ .name = "zircon_text", .module = text_module }, .{ .name = "zircon_workspace", .module = workspace_module } },
    }) });
    app_tests.root_module.addAnonymousImport("language_fixture", .{ .root_source_file = b.path("packages/zircon_language/tests/fixture.py") });
    app_tests.root_module.addAnonymousImport("image_fixture", .{ .root_source_file = b.path("packages/zircon_extensions/tests/fixtures/pixel.png") });
    const app_run = b.addRunArtifact(app_tests);
    b.step("test-app", "Exercise editor workspace journeys").dependOn(&app_run.step);
    const workspace_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("packages/zircon_workspace/tests/all.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zircon_workspace", .module = workspace_module }},
    }) });
    const workspace_run = b.addRunArtifact(workspace_tests);
    b.step("test-workspace", "Test file identities, saves, and project navigation").dependOn(&workspace_run.step);
    const text_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("packages/zircon_text/tests/all.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zircon_text", .module = text_module }},
    }) });
    const text_run = b.addRunArtifact(text_tests);
    b.step("test-text", "Test persistent document storage, history, and search").dependOn(&text_run.step);
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("packages/zircon_ui/tests/all.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zircon_ui", .module = module }},
    }) });
    const git_parser_tests = b.addTest(.{ .root_module = git_module });
    const git_parser_run = b.addRunArtifact(git_parser_tests);
    b.step("test-git-parsers", "Test Git record parsers and line diff").dependOn(&git_parser_run.step);
    const portable_compile = b.step("test-build", "Compile portable tests for the selected target");
    for (feature_tests.items) |artifact| portable_compile.dependOn(&artifact.step);
    portable_compile.dependOn(&git_parser_tests.step);
    portable_compile.dependOn(&tests.step);
    portable_compile.dependOn(&text_tests.step);
    portable_compile.dependOn(&workspace_tests.step);
    portable_compile.dependOn(&editor_tests.step);
    portable_compile.dependOn(&app_tests.step);
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
        const native_editor = b.dependency("zircon_editor", .{ .target = target, .optimize = optimize, .native = true }).module("zircon_editor");
        const native_app = b.createModule(.{
            .root_source_file = b.path("apps/zircon/src/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{ .{ .name = "zircon_ui", .module = native_ui }, .{ .name = "zircon_text", .module = text_module }, .{ .name = "zircon_workspace", .module = workspace_module }, .{ .name = "zircon_editor", .module = native_editor }, .{ .name = "zircon_git", .module = git_module }, .{ .name = "zircon_extensions", .module = extension_module }, .{ .name = "zircon_search", .module = search_module }, .{ .name = "zircon_language", .module = language_module }, .{ .name = "zircon_markdown", .module = markdown_module } },
        });
        const ui_review = b.addExecutable(.{ .name = "zircon-ui-review", .root_module = b.createModule(.{
            .root_source_file = b.path("tools/capture_ui_review.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{ .{ .name = "zircon", .module = native_app }, .{ .name = "zircon_ui", .module = native_ui } },
        }) });
        const ui_review_run = b.addRunArtifact(ui_review);
        ui_review_run.addArgs(&.{ b.option([]const u8, "review-project", "Review fixture project") orelse ".", b.option([]const u8, "review-output", "Review screenshot directory") orelse "/tmp/zircon-ui-review/current" });
        b.step("capture-ui-review", "Capture deterministic native editor review scenarios").dependOn(&ui_review_run.step);
        const app_native_tests = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path("apps/zircon/tests/native_journey.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{ .{ .name = "zircon", .module = native_app }, .{ .name = "zircon_ui", .module = native_ui } },
        }) });
        app_native_tests.root_module.addAnonymousImport("language_fixture", .{ .root_source_file = b.path("packages/zircon_language/tests/fixture.py") });
        app_native_tests.root_module.addAnonymousImport("image_fixture", .{ .root_source_file = b.path("packages/zircon_extensions/tests/fixtures/pixel.png") });
        const app_native_run = b.addRunArtifact(app_native_tests);
        b.step("test-editor-native", "Drive native editor input, persistence, and close policy").dependOn(&app_native_run.step);
        const settings_native_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("apps/zircon/tests/settings_native.zig"), .target = target, .optimize = optimize, .imports = &.{ .{ .name = "zircon", .module = native_app }, .{ .name = "zircon_ui", .module = native_ui } } }) });
        const settings_native_run = b.addRunArtifact(settings_native_tests);
        settings_native_run.step.dependOn(&app_native_run.step);
        b.step("test-settings-native", "Reproduce settings opening through native window notifications").dependOn(&settings_native_run.step);
        const real_language_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("apps/zircon/tests/clangd_journey.zig"), .target = target, .optimize = optimize, .imports = &.{ .{ .name = "zircon", .module = native_app }, .{ .name = "zircon_ui", .module = native_ui } } }) });
        const real_language_run = b.addRunArtifact(real_language_tests);
        real_language_run.step.dependOn(&settings_native_run.step);
        b.step("test-language-real", "Accept a completion from the installed Apple clangd").dependOn(&real_language_run.step);
        const zircon = b.addExecutable(.{ .name = "zircon", .root_module = b.createModule(.{
            .root_source_file = b.path("apps/zircon/src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{ .{ .name = "zircon", .module = native_app }, .{ .name = "zircon_ui", .module = native_ui } },
        }) });
        b.installArtifact(zircon);
        b.installFile("assets/icons/LICENSES", "share/zircon/icons-LICENSES");
        b.installFile("assets/icons/SOURCE.md", "share/zircon/icons-SOURCE.md");
        const zircon_run = b.addRunArtifact(zircon);

        b.step("run", "Open the Zircon native text editor").dependOn(&zircon_run.step);
        b.step("build-editor", "Compile the native Zircon editor").dependOn(&zircon.step);
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
        for ([_][]const u8{ "AppKit", "Metal", "QuartzCore", "CoreText", "CoreGraphics", "ImageIO", "CoreFoundation", "Foundation" }) |framework| native.linkFramework(framework, .{});
        native.linkSystemLibrary("objc", .{});
        const text_bench = b.addExecutable(.{ .name = "zircon-text-bench", .root_module = b.createModule(.{ .root_source_file = b.path("tools/bench_text.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "native", .module = native }} }) });
        b.step("build-bench-text", "Build the native shaping-cache benchmark").dependOn(&b.addInstallArtifact(text_bench, .{}).step);
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
        app_native_run.step.dependOn(&native_run.step);
        b.step("test-native", "Verify native windows, input, CoreText and Metal").dependOn(&native_run.step);
    }
    const format = b.addFmt(.{ .paths = &.{ b.path("build.zig"), b.path("packages"), b.path("apps"), b.path("examples") }, .check = true });
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
    for (feature_runs.items) |execute| check.dependOn(&execute.step);
    check.dependOn(&git_parser_run.step);
    check.dependOn(contracts);
    check.dependOn(&run.step);
    check.dependOn(&text_run.step);
    check.dependOn(&workspace_run.step);
    check.dependOn(&editor_run.step);
    check.dependOn(&app_run.step);
    check.dependOn(&format.step);
    b.getInstallStep().dependOn(check);
}
