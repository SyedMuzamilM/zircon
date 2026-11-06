//! Drives actual AppKit input and verifies rendered editor state and disk bytes.
const std = @import("std");
const ui = @import("zircon_ui");
const zircon = @import("zircon");
const t = std.testing;
const native = ui.testing.native;
const objc = native.objc;
test {
    _ = @import("workspace_polish_tests.zig");
    _ = @import("experience_tests.zig");
}
fn bytes(self: *const zircon.Shell, a: std.mem.Allocator, out: *[]u8) !void {
    const tab = self.tabs.items[self.active];
    var snapshot = try self.workspace.snapshot(tab.document);
    defer snapshot.deinit();
    out.* = try snapshot.copy(a, .{ .start = 0, .end = snapshot.byteLen() });
}
fn sendKey(app: *ui.App, h: ui.WindowHandle, key: ui.Key, mods: ui.Modifiers) !void {
    try app.dispatch(h, .{ .key_down = .{ .key = key, .modifiers = mods } });
}
fn nativeKey(window: objc.Id, code: u16, characters: []const u8, flags: usize) !void {
    const number = objc.send(isize, window, "windowNumber", .{});
    const event = objc.send(objc.Id, objc.class("NSEvent"), "keyEventWithType:location:modifierFlags:timestamp:windowNumber:context:characters:charactersIgnoringModifiers:isARepeat:keyCode:", .{ @as(usize, 10), objc.CGPoint{}, flags, native.now(), number, @as(objc.Id, null), objc.string(characters), objc.string(characters), false, code });
    // Bind synthetic keys to this window. Posting to NSApplication lets focus
    // changes redirect queued keystrokes into a later test's window.
    objc.send(void, window, "sendEvent:", .{event});
    for (0..32) |_| try native.pump(0);
}
fn command(app: *ui.App, owner: ui.Entity(zircon.Shell), which: zircon.Command) !void {
    const Call = struct {
        fn invoke(self: *zircon.Shell, cx: *ui.Context(zircon.Shell), action: zircon.Command) !void {
            var event: ui.Event(ui.Click) = .{ .data = .{} };
            try self.onCommand(&event, cx, action);
        }
    };
    try app.update(owner, Call.invoke, .{which});
}
test "native editor edits finds replaces splits saves and protects dirty close" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const source = "const std = @import(\"std\");\n\n// A document rendered by Zircon UI.\npub fn main() void {\n    std.debug.print(\"Hello, Zircon!\\n\", .{});\n}\n";
    try tmp.dir.writeFile(t.io, .{ .sub_path = "hello.zig", .data = source });
    const root_path = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root_path);
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    var shell = try zircon.Shell.init(t.allocator, t.io, root_path, "hello.zig");
    const h = app.openWindow(zircon.Shell, .{ .title = "Zircon · Native verification", .visible = false, .chrome = .integrated, .width = 1160, .height = 760 }, shell) catch |err| {
        shell.deinit(t.allocator);
        return err;
    };
    const owner = try app.windowEntity(zircon.Shell, h);
    try app.update(owner, zircon.Shell.bootstrap, .{h});
    _ = try app.step(0);
    const pool = objc.Pool.init();
    defer pool.deinit();
    const nsapp = objc.send(objc.Id, objc.class("NSApplication"), "sharedApplication", .{});
    const list = objc.send(objc.Id, nsapp, "windows", .{});
    const window = objc.send(objc.Id, list, "objectAtIndex:", .{@as(usize, 0)});
    const view = objc.send(objc.Id, window, "contentView", .{});
    try (try app.window(h)).snapshot("/tmp/zircon-editor-initial.png");
    try t.expectEqual(@as(isize, 1), objc.send(isize, window, "titleVisibility", .{}));
    try t.expect(objc.send(usize, window, "styleMask", .{}) & (1 << 15) != 0);
    for ([_]usize{ 0, 1, 2 }) |button| {
        const control = objc.send(objc.Id, window, "standardWindowButton:", .{button});
        try t.expect(control != null);
        try t.expect(!objc.send(bool, control, "isHidden", .{}));
    }
    try command(&app, owner, .settings);
    _ = try app.step(0.1);
    const Read = struct {
        fn child(self: *const zircon.Shell) ui.WindowHandle {
            return self.settings_window.?;
        }
    };
    const child = try app.read(owner, Read.child, .{});
    try (try app.window(child)).snapshot("/tmp/zircon-settings.png");
    const native_windows = objc.send(objc.Id, nsapp, "windows", .{});
    var child_window: objc.Id = null;
    for (0..objc.send(usize, native_windows, "count", .{})) |index| {
        const candidate = objc.send(objc.Id, native_windows, "objectAtIndex:", .{index});
        if (std.mem.eql(u8, objc.fromString(objc.send(objc.Id, candidate, "title", .{})), "Zircon Settings")) {
            child_window = candidate;
            break;
        }
    }
    try t.expect(child_window != null);
    try t.expectEqual(window, objc.send(objc.Id, child_window, "parentWindow", .{}));
    try app.closeWindow(child);
    _ = try app.step(0.2);
    _ = try app.window(h);
    _ = objc.send(bool, window, "makeFirstResponder:", .{view});

    try nativeKey(window, 0, "a", 1 << 20);
    _ = try app.step(1);
    objc.send(void, view, "insertText:replacementRange:", .{ objc.string("const answer = 42;\n"), Range{ .location = @as(usize, std.math.maxInt(isize)), .length = 0 } });
    _ = try app.step(2);
    var actual: []u8 = undefined;
    try app.read(owner, bytes, .{ t.allocator, &actual });
    try t.expectEqualStrings("const answer = 42;\n", actual);
    t.allocator.free(actual);
    try nativeKey(window, 6, "z", 1 << 20);
    _ = try app.step(3);
    try app.read(owner, bytes, .{ t.allocator, &actual });
    try t.expectEqualStrings(source, actual);
    t.allocator.free(actual);
    try nativeKey(window, 6, "z", (1 << 20) | (1 << 17));
    _ = try app.step(4);
    try command(&app, owner, .split);
    _ = try app.step(5);
    try command(&app, owner, .replace);
    _ = try app.step(6);
    try app.dispatch(h, .{ .text = "42" });
    _ = try app.step(7);
    try sendKey(&app, h, .tab, .{});
    _ = try app.step(8);
    try app.dispatch(h, .{ .text = "84" });
    _ = try app.step(9);
    try command(&app, owner, .replace_all);
    _ = try app.step(10);
    try sendKey(&app, h, .escape, .{});
    _ = try app.step(11);
    try command(&app, owner, .save);
    _ = try app.step(12);
    const disk = try tmp.dir.readFileAlloc(t.io, "hello.zig", t.allocator, .limited(1024));
    defer t.allocator.free(disk);
    try t.expectEqualStrings("const answer = 84;\n", disk);
    try (try app.window(h)).snapshot("/tmp/zircon-editor-split.png");
    try command(&app, owner, .palette);
    _ = try app.step(13);
    try app.dispatch(h, .{ .text = "Save" });
    _ = try app.step(14);
    try (try app.window(h)).snapshot("/tmp/zircon-editor-palette.png");
    try sendKey(&app, h, .escape, .{});
    _ = try app.step(15);
    try app.dispatch(h, .{ .text = "// unsaved\n" });
    _ = try app.step(16);
    objc.send(void, window, "performClose:", .{@as(objc.Id, null)});
    for (0..16) |_| try native.pump(0);
    _ = try app.step(17);
    _ = try app.window(h);
    try (try app.window(h)).snapshot("/tmp/zircon-editor-dirty-close.png");
    try command(&app, owner, .dismiss);
    _ = try app.step(18);
    _ = try app.window(h);
    try command(&app, owner, .save);
    _ = try app.step(19);
    objc.send(void, window, "performClose:", .{@as(objc.Id, null)});
    for (0..16) |_| try native.pump(0);
    _ = try app.step(20);
    try t.expectError(error.WindowNotFound, app.window(h));
}
const Range = extern struct { location: usize, length: usize };

test "native search and palette typing refresh replacement ranges between keystrokes" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root_path = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root_path);
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "sample.zig", .data = "const std = @import(\"std\");\n\npub fn main() void {\n    std.debug.print(\"Hello, Zircon!\\n\", .{});\n}\n" });
    const shell = try zircon.Shell.init(t.allocator, t.io, root_path, "sample.zig");
    const h = try app.openWindow(zircon.Shell, .{ .title = "Zircon field regression", .visible = false }, shell);
    const owner = try app.windowEntity(zircon.Shell, h);
    try app.update(owner, zircon.Shell.bootstrap, .{h});
    _ = try app.step(4);
    const pool = objc.Pool.init();
    defer pool.deinit();
    const nsapp = objc.send(objc.Id, objc.class("NSApplication"), "sharedApplication", .{});
    const windows = objc.send(objc.Id, nsapp, "windows", .{});
    var window: objc.Id = null;
    for (0..objc.send(usize, windows, "count", .{})) |i| {
        const candidate = objc.send(objc.Id, windows, "objectAtIndex:", .{i});
        if (std.mem.eql(u8, "Zircon field regression", objc.fromString(objc.send(objc.Id, candidate, "title", .{})))) window = candidate;
    }
    if (window == null) return error.TestWindowNotFound;
    inline for (.{ zircon.Command.project_search, zircon.Command.palette, zircon.Command.open_path, zircon.Command.find, zircon.Command.replace }) |action| {
        try command(&app, owner, action);
        _ = try app.step(4);
        try nativeKey(window, 0, "a", 0);
        _ = try app.step(4);
        try nativeKey(window, 1, "s", 0);
        _ = try app.step(4);
        if (action == .palette) try (try app.window(h)).snapshot("/tmp/zircon-command-menu.png");
        try t.expectEqualStrings("as", (try app.window(h)).frames.committed.text_input.?.text);
        const view = objc.send(objc.Id, window, "contentView", .{});
        const NativeRange = extern struct { location: usize, length: usize };
        objc.send(void, view, "insertText:replacementRange:", .{ objc.string("é🌍"), NativeRange{ .location = @as(usize, std.math.maxInt(isize)), .length = 0 } });
        _ = try app.step(4);
        try t.expectEqualStrings("asé🌍", (try app.window(h)).frames.committed.text_input.?.text);
        try app.dispatch(h, .{ .key_down = .{ .key = .escape } });
        _ = try app.step(4);
    }
    try command(&app, owner, .split_down);
    _ = try app.step(4);
    try (try app.window(h)).snapshot("/tmp/zircon-split-down.png");
    try command(&app, owner, .split_menu);
    _ = try app.step(4);
    try (try app.window(h)).snapshot("/tmp/zircon-split-menu.png");
    const Theme = struct {
        fn apply(self: *zircon.Shell, cx: *ui.Context(zircon.Shell), id: []const u8) !void {
            try cx.update(self.settings.?, zircon.Settings.apply, .{zircon.SettingsPatch{ .theme = id }});
        }
        fn light(self: *const zircon.Shell) bool {
            return self.colors.document.r > 0.8;
        }
    };
    try app.update(owner, Theme.apply, .{"zircon.system"});
    const old_appearance = objc.retain(objc.send(objc.Id, nsapp, "appearance", .{}));
    defer {
        objc.send(void, nsapp, "setAppearance:", .{old_appearance});
        objc.release(old_appearance);
    }
    const aqua = objc.send(objc.Id, objc.class("NSAppearance"), "appearanceNamed:", .{objc.string("NSAppearanceNameAqua")});
    objc.send(void, nsapp, "setAppearance:", .{aqua});
    const view = objc.send(objc.Id, window, "contentView", .{});
    objc.send(void, view, "viewDidChangeEffectiveAppearance", .{});
    for (0..4) |_| try native.pump(0);
    _ = try app.step(4);
    try t.expect(try app.read(owner, Theme.light, .{}));
    try (try app.window(h)).snapshot("/tmp/zircon-split-menu-light.png");
    try app.update(owner, Theme.apply, .{"zircon.dark"});
    _ = try app.step(4);
    const appearance = objc.send(objc.Id, window, "appearance", .{});
    try t.expectEqualStrings("NSAppearanceNameDarkAqua", objc.fromString(objc.send(objc.Id, appearance, "name", .{})));
}

test "native Vim commands block insertion and switch native input with Insert and Visual modes" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "vim.txt", .data = "one two\nthree\n" });
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    var shell = try zircon.Shell.init(t.allocator, t.io, root, "vim.txt");
    shell.editor_options.vim_mode = true;
    shell.tabs.items[0].editor.setVim(true);
    const h = try app.openWindow(zircon.Shell, .{ .title = "Zircon Vim verification", .visible = false, .chrome = .integrated, .width = 1000, .height = 700 }, shell);
    const owner = try app.windowEntity(zircon.Shell, h);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "settings.json", .data = "{\"vim_mode\":true}" });
    const settings_path = try tmp.dir.realPathFileAlloc(t.io, "settings.json", t.allocator);
    defer t.allocator.free(settings_path);
    try app.update(owner, zircon.Shell.loadSettings, .{settings_path});
    try app.update(owner, zircon.Shell.bootstrap, .{h});
    _ = try app.step(0);
    try t.expect((try app.window(h)).frames.committed.text_input == null);
    const autorelease = objc.Pool.init();
    defer autorelease.deinit();
    const nsapp = objc.send(objc.Id, objc.class("NSApplication"), "sharedApplication", .{});
    const windows = objc.send(objc.Id, nsapp, "windows", .{});
    var window: objc.Id = null;
    for (0..objc.send(usize, windows, "count", .{})) |i| {
        const candidate = objc.send(objc.Id, windows, "objectAtIndex:", .{i});
        if (std.mem.eql(u8, objc.fromString(objc.send(objc.Id, candidate, "title", .{})), "Zircon Vim verification")) {
            window = candidate;
            break;
        }
    }
    try t.expect(window != null);
    _ = objc.send(bool, window, "makeFirstResponder:", .{objc.send(objc.Id, window, "contentView", .{})});
    try nativeKey(window, 2, "d", 0);
    _ = try app.step(0);
    try nativeKey(window, 13, "w", 0);
    _ = try app.step(0);
    try expectSource(&app, owner, "two\nthree\n");
    try nativeKey(window, 32, "u", 0);
    _ = try app.step(0);
    try nativeKey(window, 34, "i", 0);
    _ = try app.step(0);
    try t.expect((try app.window(h)).frames.committed.text_input != null);
    try nativeKey(window, 7, "X", 1 << 17);
    _ = try app.step(0);
    try nativeKey(window, 53, "\x1b", 0);
    _ = try app.step(0);
    try expectSource(&app, owner, "Xone two\nthree\n");
    try t.expect((try app.window(h)).frames.committed.text_input == null);
    try nativeKey(window, 9, "v", 0);
    _ = try app.step(0);
    try nativeKey(window, 37, "l", 0);
    _ = try app.step(0);
    const Read = struct {
        fn selected(self: *const zircon.Shell) usize {
            const range = self.tabs.items[0].editor.primary().range();
            return range.end - range.start;
        }
        fn fontCount(self: *const zircon.SettingsView) usize {
            return self.font_families.len;
        }
    };
    try t.expectEqual(@as(usize, 2), try app.read(owner, Read.selected, .{}));
    try (try app.window(h)).snapshot("/tmp/zircon-vim-visual.png");
    try nativeKey(window, 53, "\x1b", 0);
    _ = try app.step(0);
    try nativeKey(window, 0, "A", 1 << 17);
    _ = try app.step(0);
    try nativeKey(window, 51, "\x7f", 1 << 20);
    _ = try app.step(0);
    try expectSource(&app, owner, "\nthree\n");
    try nativeKey(window, 53, "\x1b", 0);
    _ = try app.step(0);
    try command(&app, owner, .settings);
    _ = try app.step(0);
    const Settings = struct {
        fn child(self: *const zircon.Shell) ui.WindowHandle {
            return self.settings_window.?;
        }
    };
    const child = try app.read(owner, Settings.child, .{});
    const settings_owner = try app.windowEntity(zircon.SettingsView, child);
    try t.expect(try app.read(settings_owner, Read.fontCount, .{}) > 10);
}

fn expectSource(app: *ui.App, owner: ui.Entity(zircon.Shell), expected: []const u8) !void {
    var actual: []u8 = undefined;
    try app.read(owner, bytes, .{ t.allocator, &actual });
    defer t.allocator.free(actual);
    try t.expectEqualStrings(expected, actual);
}
