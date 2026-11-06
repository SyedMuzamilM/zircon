const std = @import("std");
const ui = @import("zircon_ui");
const zircon = @import("zircon");
const t = std.testing;
test "settings update persists atomically retains unknown keys and refuses invalid values" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "settings.json", .data = "{\"schema_version\":1,\"future_option\":\"keep\"}" });
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const path = try std.fs.path.join(t.allocator, &.{ root, "settings.json" });
    defer t.allocator.free(path);
    var store = try zircon.SettingsStore.init(t.allocator, t.io, path);
    defer store.deinit();
    try store.update(.{ .font_size = 18 });
    try store.update(.{ .theme = "zircon.light" });
    try store.update(.{ .font_family = .menlo });
    try store.update(.{ .ui_font_family = .system });
    try store.update(.{ .ui_font_size = 15 });
    try store.update(.{ .line_height = 1.8 });
    try store.update(.{ .font_ligatures = true });
    try t.expectError(error.InvalidSettings, store.update(.{ .font_size = 0 }));
    try t.expectEqual(@as(f32, 18), store.values().font_size);
    var reopened = try zircon.SettingsStore.init(t.allocator, t.io, path);
    defer reopened.deinit();
    try t.expectEqual(@as(f32, 18), reopened.values().font_size);
    try t.expectEqualStrings("zircon.light", reopened.values().theme);
    try t.expectEqual(ui.typography.CodeFont.menlo, reopened.values().font_family);
    try t.expectEqual(ui.typography.UiFont.system, reopened.values().ui_font_family);
    try t.expectEqual(@as(f32, 15), reopened.values().ui_font_size);
    try t.expectEqual(@as(f32, 1.8), reopened.values().line_height);
    try t.expect(reopened.values().font_ligatures);
    const output = try tmp.dir.readFileAlloc(t.io, "settings.json", t.allocator, .limited(4096));
    defer t.allocator.free(output);
    try t.expect(std.mem.indexOf(u8, output, "future_option") != null);
}
const Ops = struct {
    fn open(self: *zircon.Shell, cx: *ui.Context(zircon.Shell)) !void {
        var e: ui.Event(ui.Click) = .{ .data = .{} };
        try self.onCommand(&e, cx, .settings);
    }
    fn child(self: *const zircon.Shell) ui.WindowHandle {
        return self.settings_window.?;
    }
    fn font(self: *const zircon.Shell) f32 {
        return self.tabs.items[0].editor.font_size;
    }
    fn light(self: *const zircon.Shell) bool {
        return self.colors.document.r > 0.8;
    }
    fn newAndSplit(self: *zircon.Shell, cx: *ui.Context(zircon.Shell)) !void {
        try self.newFile();
        var e: ui.Event(ui.Click) = .{ .data = .{} };
        try self.onCommand(&e, cx, .split);
    }
    fn inherited(self: *const zircon.Shell) bool {
        const tab = self.tabs.items[self.active].editor;
        return tab.font_size == 15 and tab.theme.background.r > 0.8 and self.secondary != null and self.secondary.?.editor.font_size == 15 and self.secondary.?.editor.theme.background.r > 0.8;
    }
};
fn clickLabel(app: *ui.App, h: ui.WindowHandle, label: []const u8) !void {
    const frame = &(try app.window(h)).frames.committed;
    for (frame.nodes.items, 0..) |node, i| if (node.kind == .button and std.mem.eql(u8, node.kind.button.label, label)) {
        const rect = frame.bounds[i];
        const point: ui.Point = .{ .x = rect.x + rect.width / 2, .y = rect.y + rect.height / 2 };
        const size = (try app.window(h)).dimensions;
        if (point.y < 0 or point.y >= size.height or point.x < 0 or point.x >= size.width) return error.ControlOutsideWindow;
        try app.dispatch(h, .{ .pointer_down = .{ .position = point } });
        try app.dispatch(h, .{ .pointer_up = .{ .position = point } });
        return;
    };
    return error.ControlNotFound;
}
fn keyBounds(app: *ui.App, h: ui.WindowHandle, key: []const u8) !ui.Rect {
    const frame = &(try app.window(h)).frames.committed;
    for (frame.nodes.items, 0..) |node, i| if (node.key) |value| {
        if (value == .string and std.mem.eql(u8, value.string, key)) return frame.bounds[i];
    };
    return error.KeyNotFound;
}
fn hasText(app: *ui.App, h: ui.WindowHandle, bytes: []const u8) !bool {
    for ((try app.window(h)).frames.committed.nodes.items) |node| {
        if (node.kind == .text and std.mem.eql(u8, node.kind.text, bytes)) return true;
    }
    return false;
}
test "settings search scroll hit geometry and JSON editing persist real user changes" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const path = try std.fs.path.join(t.allocator, &.{ root, "settings.json" });
    defer t.allocator.free(path);
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    var shell = try zircon.Shell.init(t.allocator, t.io, root, null);
    const main = app.openWindow(zircon.Shell, .{ .visible = false, .width = 1000, .height = 700 }, shell) catch |err| {
        shell.deinit(t.allocator);
        return err;
    };
    const owner = try app.windowEntity(zircon.Shell, main);
    try app.update(owner, zircon.Shell.loadSettings, .{path});
    try app.update(owner, zircon.Shell.bootstrap, .{main});
    _ = try app.step(0);
    try app.update(owner, Ops.open, .{});
    const child = try app.read(owner, Ops.child, .{});
    _ = try app.step(1);
    // Search receives text through its focused input, not a model setter.
    try app.dispatch(child, .{ .text = "font" });
    _ = try app.step(2);
    try t.expect(try hasText(&app, child, "Font size"));
    try t.expect(!try hasText(&app, child, "Line numbers"));
    try clickLabel(&app, child, "+");
    _ = try app.step(3);
    const search = try keyBounds(&app, child, "settings-search");
    const point: ui.Point = .{ .x = search.x + 10, .y = search.y + 10 };
    try app.dispatch(child, .{ .pointer_down = .{ .position = point } });
    try app.dispatch(child, .{ .pointer_up = .{ .position = point } });
    try app.dispatch(child, .{ .key_down = .{ .key = .a, .modifiers = .{ .command = true } } });
    try app.dispatch(child, .{ .key_down = .{ .key = .backspace } });
    try app.dispatch(child, .{ .resize = .{ .width = 960, .height = 460 } });
    _ = try app.step(4);
    const before = try keyBounds(&app, child, "motion");
    try t.expect(before.y > 460);
    try app.dispatch(child, .{ .scroll = .{ .position = .{ .x = 800, .y = 350 }, .x = 0, .y = -10000 } });
    _ = try app.step(5);
    const after = try keyBounds(&app, child, "motion");
    try t.expect(after.y < 400 and after.y > 60);
    try clickLabel(&app, child, "Reduced motion");
    _ = try app.step(6);
    try app.closeWindow(child);
    _ = try app.step(7);
    var reopened = try zircon.SettingsStore.init(t.allocator, t.io, path);
    defer reopened.deinit();
    try t.expectEqual(@as(f32, 15), reopened.values().font_size);
    try t.expect(reopened.values().reduced_motion);
    try app.update(owner, Ops.open, .{});
    const next = try app.read(owner, Ops.child, .{});
    _ = try app.step(8);
    try clickLabel(&app, next, "Edit in settings.json");
    _ = try app.step(9);
    try t.expectError(error.WindowNotFound, app.window(next));
    const Opened = struct {
        fn pathIsOpen(self: *const zircon.Shell, expected: []const u8) bool {
            const document = self.workspace.getConst(self.tabs.items[self.active].document) catch return false;
            return if (document.path) |value| std.mem.eql(u8, value, expected) else false;
        }
    };
    try t.expect(try app.read(owner, Opened.pathIsOpen, .{path}));
}
test "separate settings child changes shared editor appearance and closes independently" {
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    var shell = try zircon.Shell.init(t.allocator, t.io, ".", null);
    const main = app.openWindow(zircon.Shell, .{ .visible = false, .width = 1000, .height = 700 }, shell) catch |err| {
        shell.deinit(t.allocator);
        return err;
    };
    const owner = try app.windowEntity(zircon.Shell, main);
    try app.update(owner, zircon.Shell.bootstrap, .{main});
    _ = try app.step(0);
    try app.update(owner, Ops.open, .{});
    const child = try app.read(owner, Ops.child, .{});
    _ = try app.step(1);
    try t.expectEqual(main, (try app.window(child)).parent.?);
    try clickLabel(&app, child, "One Dark");
    _ = try app.step(1.5);
    try clickLabel(&app, child, "One Light");
    _ = try app.step(2);
    try t.expect(try app.read(owner, Ops.light, .{}));
    try clickLabel(&app, child, "Editor");
    _ = try app.step(3);
    try clickLabel(&app, child, "Lilex");
    _ = try app.step(3.1);
    try clickLabel(&app, child, "Menlo");
    _ = try app.step(3.2);
    try clickLabel(&app, child, "+");
    _ = try app.step(4);
    try t.expectEqual(@as(f32, 15), try app.read(owner, Ops.font, .{}));
    try app.update(owner, Ops.newAndSplit, .{});
    _ = try app.step(4.5);
    try t.expect(try app.read(owner, Ops.inherited, .{}));
    try app.closeWindow(child);
    _ = try app.step(5);
    _ = try app.window(main);
    try t.expectError(error.WindowNotFound, app.window(child));
    try app.update(owner, Ops.open, .{});
    const reopened = try app.read(owner, Ops.child, .{});
    _ = try app.step(6);
    try app.closeWindow(main);
    _ = try app.step(7);
    try t.expectError(error.WindowNotFound, app.window(reopened));
}

test "settings choice search filters independently and commits only with Enter" {
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const shell = try zircon.Shell.init(t.allocator, t.io, ".", null);
    const main = try app.openWindow(zircon.Shell, .{ .visible = false }, shell);
    const owner = try app.windowEntity(zircon.Shell, main);
    try app.update(owner, zircon.Shell.bootstrap, .{main});
    _ = try app.step(0);
    try app.update(owner, Ops.open, .{});
    const child = try app.read(owner, Ops.child, .{});
    _ = try app.step(1);
    try clickLabel(&app, child, "One Dark");
    _ = try app.step(1);
    try app.dispatch(child, .{ .text = "light" });
    _ = try app.step(1);
    try t.expect(try hasText(&app, child, "One Light"));
    try t.expect(!try app.read(owner, Ops.light, .{}));
    try app.dispatch(child, .{ .key_down = .{ .key = .enter } });
    _ = try app.step(1);
    try t.expect(try app.read(owner, Ops.light, .{}));
    try clickLabel(&app, child, "One Light");
    _ = try app.step(1);
    try app.dispatch(child, .{ .text = "unknown choice" });
    _ = try app.step(1);
    try t.expect(try hasText(&app, child, "No matching choices"));
    try app.dispatch(child, .{ .key_down = .{ .key = .enter } });
    _ = try app.step(1);
    try t.expect(try app.read(owner, Ops.light, .{}));
    try app.dispatch(child, .{ .key_down = .{ .key = .escape } });
    _ = try app.step(1);
    try clickLabel(&app, child, "Editor");
    _ = try app.step(1);
    try clickLabel(&app, child, "Lilex");
    _ = try app.step(1);
    try app.dispatch(child, .{ .text = "men" });
    _ = try app.step(1);
    try app.dispatch(child, .{ .key_down = .{ .key = .down } });
    try app.dispatch(child, .{ .key_down = .{ .key = .enter } });
    _ = try app.step(1);
    const Check = struct {
        fn settings(self: *const zircon.Shell) ui.Entity(zircon.Settings) {
            return self.settings.?;
        }
        fn menlo(self: *const zircon.Settings) bool {
            return self.store.values().font_family == .menlo;
        }
    };
    const preferences = try app.read(owner, Check.settings, .{});
    try t.expect(try app.read(preferences, Check.menlo, .{}));
}

test "installed font identities and Vim bindings persist without borrowed settings bytes" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "settings.json", .data = "{\"vim_mode\":true,\"vim_bindings\":{\"H\":\"0\",\"L\":\"$\"},\"font_family\":\"Courier New\",\"ui_font_family\":\"Helvetica Neue\"}" });
    const path = try tmp.dir.realPathFileAlloc(t.io, "settings.json", t.allocator);
    defer t.allocator.free(path);
    var store = try zircon.SettingsStore.init(t.allocator, t.io, path);
    defer store.deinit();
    var values = store.values();
    try t.expect(values.vim_mode);
    try t.expectEqual(@as(u8, '$'), values.vim_bindings.resolve('L'));
    try t.expectEqualStrings("Courier New", values.editor_font_name.slice());
    try store.update(.{ .vim_mode = false });
    try store.update(.{ .editor_font_name = try ui.typography.FontName.init("Menlo") });
    var reopened = try zircon.SettingsStore.init(t.allocator, t.io, path);
    defer reopened.deinit();
    values = reopened.values();
    try t.expect(!values.vim_mode);
    try t.expectEqualStrings("Menlo", values.editor_font_name.slice());
    try t.expectEqualStrings("Helvetica Neue", values.interface_font_name.slice());
    try store.update(.{ .font_family = .lilex });
    try t.expectEqual(@as(u16, 0), store.values().editor_font_name.len);
}

test "opening Light settings styles search fields before reading the borrowed workspace" {
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    var shell = try zircon.Shell.init(t.allocator, t.io, ".", null);
    const h = app.openWindow(zircon.Shell, .{ .visible = false, .width = 1000, .height = 700 }, shell) catch |err| {
        shell.deinit(t.allocator);
        return err;
    };
    const owner = try app.windowEntity(zircon.Shell, h);
    try app.update(owner, zircon.Shell.bootstrap, .{h});
    const Call = struct {
        fn light(self: *zircon.Shell, cx: *ui.Context(zircon.Shell)) !void {
            try cx.update(self.settings.?, zircon.Settings.apply, .{zircon.SettingsPatch{ .theme = "zircon.light" }});
        }
        fn status(self: *const zircon.Shell) bool {
            return self.status_is_error;
        }
    };
    try app.update(owner, Call.light, .{});
    _ = try app.step(0);
    try app.update(owner, Ops.open, .{});
    _ = try app.step(0);
    try t.expect(!try app.read(owner, Call.status, .{}));
    const child = try app.read(owner, Ops.child, .{});
    const frame = &(try app.window(child)).frames.committed;
    const search = try keyBounds(&app, child, "settings-search");
    var light_background = false;
    for (frame.scene.items) |item| if (item.kind == .rect and item.rect.x >= search.x and item.rect.y >= search.y and item.rect.width >= search.width - 2 and item.rect.height >= 28 and item.rect.height <= 31 and item.color.r > 0.8) {
        light_background = true;
    };
    try t.expect(light_background);
}
