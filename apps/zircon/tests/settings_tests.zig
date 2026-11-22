const std = @import("std");
const zircon = @import("zircon");
const ui = @import("zircon_ui");
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
    try store.update(.{ .indent_guides = false });
    try store.update(.{ .active_line = false });
    try store.update(.{ .fold_controls = false });
    try store.update(.{ .project_file_icons = false });
    try store.update(.{ .project_folder_icons = false });
    try store.update(.{ .project_panel_width = 300 });
    try store.update(.{ .project_entry_spacing = 28 });
    try store.update(.{ .tooltips = false });
    try store.update(.{ .tooltip_delay = 700 });
    try store.update(.{ .search_case_sensitive = true });
    try store.update(.{ .search_whole_word = true });
    try store.update(.{ .agent_editor = false });
    try t.expectError(error.InvalidSettings, store.update(.{ .project_entry_spacing = 4 }));
    try t.expectError(error.InvalidSettings, store.update(.{ .tooltip_delay = 10000 }));
    try t.expectError(error.InvalidSettings, store.update(.{ .project_panel_width = 10 }));
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
    const values = reopened.values();
    try t.expect(!values.indent_guides and !values.active_line and !values.fold_controls);
    try t.expect(!values.project_file_icons and !values.project_folder_icons);
    try t.expectEqual(@as(f32, 300), values.project_panel_width);
    try t.expectEqual(@as(f32, 28), values.project_entry_spacing);
    try t.expect(!values.tooltips and values.tooltip_delay == 700);
    try t.expect(values.search_case_sensitive and values.search_whole_word and !values.agent_editor);
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
test "nested settings sections collapse independently and gutter controls update the editor live" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const path = try std.fs.path.join(t.allocator, &.{ root, "settings.json" });
    defer t.allocator.free(path);
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const shell = try zircon.Shell.init(t.allocator, t.io, root, null);
    const h = try app.openWindow(zircon.Shell, .{ .visible = false, .width = 1000, .height = 700 }, shell);
    const owner = try app.windowEntity(zircon.Shell, h);
    try app.update(owner, zircon.Shell.loadSettings, .{path});
    try app.update(owner, zircon.Shell.bootstrap, .{h});
    _ = try app.step(0);
    try app.update(owner, Ops.open, .{});
    _ = try app.step(0);
    const child = try app.read(owner, Ops.child, .{});
    try t.expect(try hasText(&app, child, "Gutter and folding"));
    try clickLabel(&app, child, "Editor");
    _ = try app.step(0);
    try t.expect(!try hasText(&app, child, "Gutter and folding"));
    try t.expect(try hasText(&app, child, "Typography"));
    try clickLabel(&app, child, "Editor");
    _ = try app.step(0);
    try clickLabel(&app, child, "Gutter and folding");
    _ = try app.step(0);
    try clickLabel(&app, child, "Folding controls");
    _ = try app.step(0);
    const Read = struct {
        fn hidden(self: *const zircon.Shell) bool {
            return !self.tabs.items[0].editor.show_fold_controls;
        }
        fn light(self: *zircon.Shell, cx: *ui.Context(zircon.Shell)) !void {
            try cx.update(self.settings.?, zircon.Settings.apply, .{zircon.SettingsPatch{ .theme = "zircon.light" }});
        }
    };
    try t.expect(try app.read(owner, Read.hidden, .{}));
    if (comptime ui.testing.native != void) try (try app.window(child)).snapshot("/tmp/zircon-settings-gutter-dark.png");
    try app.update(owner, Read.light, .{});
    _ = try app.step(0);
    if (comptime ui.testing.native != void) try (try app.window(child)).snapshot("/tmp/zircon-settings-gutter-light.png");
    try app.closeWindow(child);
    var store = try zircon.SettingsStore.init(t.allocator, t.io, path);
    defer store.deinit();
    try t.expect(!store.values().fold_controls);
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
    try app.dispatch(child, .{ .text = "cursor" });
    _ = try app.step(1);
    try clickLabel(&app, child, "Underline");
    try clickLabel(&app, child, "Cursor blinking");
    try clickLabel(&app, child, "Smooth cursor");
    _ = try app.step(1);
    const Cursor = struct {
        fn matches(self: *const zircon.Shell, smooth: bool) bool {
            const config = self.tabs.items[self.active].editor.cursor_config;
            return config.shape == .underline and !config.blink and config.smooth == smooth;
        }
    };
    try t.expect(try app.read(owner, Cursor.matches, .{true}));
    const search = try keyBounds(&app, child, "settings-search");
    const point: ui.Point = .{ .x = search.x + 10, .y = search.y + 10 };
    try app.dispatch(child, .{ .pointer_down = .{ .position = point } });
    try app.dispatch(child, .{ .pointer_up = .{ .position = point } });
    try app.dispatch(child, .{ .key_down = .{ .key = .a, .modifiers = .{ .command = true } } });
    // Search receives text through its focused input, not a model setter.
    try app.dispatch(child, .{ .text = "font" });
    _ = try app.step(2);
    try t.expect(try hasText(&app, child, "Font size"));
    try t.expect(!try hasText(&app, child, "Line numbers"));
    try clickLabel(&app, child, "+");
    _ = try app.step(3);
    try app.dispatch(child, .{ .pointer_down = .{ .position = point } });
    try app.dispatch(child, .{ .pointer_up = .{ .position = point } });
    try app.dispatch(child, .{ .key_down = .{ .key = .a, .modifiers = .{ .command = true } } });
    try app.dispatch(child, .{ .key_down = .{ .key = .backspace } });
    try app.dispatch(child, .{ .resize = .{ .width = 960, .height = 460 } });
    _ = try app.step(4);
    const before = try keyBounds(&app, child, "motion");
    try t.expect(before.y > 460);
    try app.dispatch(child, .{ .scroll = .{ .position = .{ .x = 800, .y = 350 }, .x = 0, .y = -(before.y - 180) } });
    _ = try app.step(5);
    const after = try keyBounds(&app, child, "motion");
    try t.expect(after.y < 400 and after.y > 60);
    try clickLabel(&app, child, "Reduced motion");
    _ = try app.step(6);
    try t.expect(try app.read(owner, Cursor.matches, .{false}));
    try app.closeWindow(child);
    _ = try app.step(7);
    var reopened = try zircon.SettingsStore.init(t.allocator, t.io, path);
    defer reopened.deinit();
    try t.expectEqual(@as(f32, 15), reopened.values().font_size);
    try t.expect(reopened.values().reduced_motion);
    try t.expect(reopened.values().cursor_shape == .underline);
    try t.expect(!reopened.values().cursor_blink);
    try t.expect(reopened.values().smooth_cursor);
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
    const search = try keyBounds(&app, child, "settings-search");
    const search_point: ui.Point = .{ .x = search.x + search.width / 2, .y = search.y + search.height / 2 };
    try app.dispatch(child, .{ .pointer_down = .{ .position = search_point } });
    try app.dispatch(child, .{ .pointer_up = .{ .position = search_point } });
    try app.dispatch(child, .{ .text = "Font size editor" });
    _ = try app.step(3.3);
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
    try app.dispatch(child, .{ .key_down = .{ .key = .up } });
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

fn expectFile(dir: std.Io.Dir, path: []const u8, expected: []const u8) !void {
    const actual = try dir.readFileAlloc(t.io, path, t.allocator, .limited(4096));
    defer t.allocator.free(actual);
    try t.expectEqualStrings(expected, actual);
}

test "settings JSONC preserves strings and rejects invalid syntax" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const path = try std.fs.path.join(t.allocator, &.{ root, "settings.json" });
    defer t.allocator.free(path);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "settings.json", .data = "\xef\xbb\xbf" ++
        \\// Example configuration
        \\{
        \\    "theme": "https://example.test/a/*b*/",
        \\    /* Nested data
        \\       retains strings and allows a trailing comma. */
        \\    "future": [{"quote": "\"//",},], // trailing comma
        \\}
    });
    var store = try zircon.SettingsStore.init(t.allocator, t.io, path);
    defer store.deinit();
    try t.expectEqualStrings("https://example.test/a/*b*/", store.values().theme);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "settings.json", .data = "{/*" });
    try t.expectError(error.UnterminatedComment, store.reload());
    for ([_][]const u8{ "{\"future\":[,]}", "{\"future\":[1,,]}", "{\"tab_width\":1/*x*/2}" }) |bad| {
        try tmp.dir.writeFile(t.io, .{ .sub_path = "settings.json", .data = bad });
        try t.expectError(error.SyntaxError, store.reload());
    }
    const opens: [256]u8 = @splat('[');
    const closes: [256]u8 = @splat(']');
    try tmp.dir.writeFile(t.io, .{ .sub_path = "settings.json", .data = "{\"future\":" ++ opens ++ "0" ++ closes ++ "}" });
    try t.expectError(error.SettingsTooDeep, store.reload());
    try t.expectEqualStrings("https://example.test/a/*b*/", store.values().theme);
}

test "settings project layer resolves exact precedence and excludes restricted keys" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const path = try std.fs.path.join(t.allocator, &.{ root, "settings.json" });
    defer t.allocator.free(path);
    var store = try zircon.SettingsStore.init(t.allocator, t.io, path);
    defer store.deinit();
    try t.expectEqual(4, store.bufferSettings("zig", "Zig").tab_width);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "settings.json", .data =
        \\{"tab_width": 3, "languages": {
        \\  "Zig": {"tab_width": 6, "line_height": 2},
        \\  "Markdown": {"tab_width": 8}
        \\}}
    });
    try store.reload();
    try t.expectEqual(3, store.values().tab_width);
    try t.expectEqual(6, store.bufferSettings("zig", "compiler source").tab_width);
    try tmp.dir.createDirPath(t.io, ".zircon");
    try tmp.dir.writeFile(t.io, .{ .sub_path = ".zircon/settings.json", .data =
        \\{"tab_width": 2, "key_bindings": false, "vim_mode": true,
        \\ "theme": "other", "font_family": "other"}
    });
    try store.setProjectRoot(root);
    try t.expectEqual(4, store.ignored_project_keys);
    try t.expectEqual(2, store.values().tab_width);
    try t.expect(!store.values().vim_mode);
    try t.expectEqualStrings("zircon.dark", store.values().theme);
    try t.expectEqual(6, store.bufferSettings("zig", "Zig").tab_width);
    try t.expectEqual(8, store.bufferSettings("md", "mArKdOwN").tab_width);
    try t.expectError(error.DisallowedProjectSetting, store.updateScope(.project, .{ .vim_mode = true }));
    try tmp.dir.writeFile(t.io, .{ .sub_path = ".zircon/settings.json", .data =
        \\{"tab_width": 2, "languages": {"zIG": {
        \\  "tab_width": 7, "line_height": "invalid", "vim_mode": true, "future": false,
        \\}}}
    });
    try store.reload();
    try t.expectEqual(3, store.ignored_project_keys);
    try t.expectEqual(7, store.bufferSettings("ZiG", "Zig").tab_width);
    try t.expectEqual(2.0, store.bufferSettings("zig", "Zig").line_height);
    try store.updateScope(.project, .{ .tab_width = 5 });
    try t.expect(store.hasProjectOverride("tab_width"));
    try t.expectEqual(5, store.values().tab_width);
    try t.expectError(error.InvalidSettings, store.updateScope(.project, .{ .autosave_delay_ms = 100 }));
    try store.clearProjectKey("tab_width");
    try t.expect(!store.hasProjectOverride("tab_width"));
    try t.expectEqual(3, store.values().tab_width);
    try t.expectEqual(7, store.bufferSettings("zig", "Zig").tab_width);
}

const SaveOps = struct {
    fn command(self: *zircon.Shell, cx: *ui.Context(zircon.Shell), which: zircon.Command) !void {
        var click: ui.Event(ui.Click) = .{ .data = .{} };
        try self.onCommand(&click, cx, which);
    }

    fn select(self: *zircon.Shell, cx: *ui.Context(zircon.Shell), index: u32) !void {
        var click: ui.Event(ui.Click) = .{ .data = .{} };
        try self.onTab(&click, cx, index);
    }

    fn replace(self: *zircon.Shell, cx: *ui.Context(zircon.Shell), bytes: []const u8) !void {
        try command(self, cx, .select_all);
        var input: ui.Event(ui.Input) = .{ .data = .{ .text = bytes } };
        try self.onEditor(&input, cx, 0);
    }

    fn width(self: *const zircon.Shell, index: usize) usize {
        return self.tabs.items[index].editor.tab_width;
    }

    fn statusError(self: *const zircon.Shell) bool {
        return self.status_is_error;
    }

    fn shareSettings(self: *const zircon.Shell) ui.Entity(zircon.Settings) {
        return self.settings.?;
    }

    fn useSettings(self: *zircon.Shell, _: *ui.Context(zircon.Shell), entity: ui.Entity(zircon.Settings)) void {
        self.settings = entity;
    }
};

test "settings save hooks preserve LF CRLF Markdown and empty buffers and reload JSONC" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(t.io, ".zircon");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "settings.json", .data =
        \\{"tab_width": 5, "ensure_final_newline_on_save": true,
        \\ "languages": {
        \\   "Zig": {"remove_trailing_whitespace_on_save": true},
        \\   "Markdown": {"remove_trailing_whitespace_on_save": false}
        \\ }}
    });
    try tmp.dir.writeFile(t.io, .{ .sub_path = ".zircon/settings.json", .data =
        \\{"tab_width": 2, "remove_trailing_whitespace_on_save": true}
    });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "a.zig", .data = "foo \t\nbar\t" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "b.zig", .data = "foo \t\r\nbar\t" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "c.md", .data = "foo  \nbar\t" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "empty.zig", .data = "" });
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const path = try tmp.dir.realPathFileAlloc(t.io, "settings.json", t.allocator);
    defer t.allocator.free(path);
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const h = try app.openWindow(zircon.Shell, .{ .visible = false }, try zircon.Shell.init(t.allocator, t.io, root, "a.zig"));
    const owner = try app.windowEntity(zircon.Shell, h);
    try app.update(owner, zircon.Shell.loadSettings, .{path});
    try app.update(owner, zircon.Shell.bootstrap, .{h});
    try t.expectEqual(2, try app.read(owner, SaveOps.width, .{0}));
    for ([_][]const u8{ "a.zig", "b.zig", "c.md", "empty.zig" }) |file| {
        try app.update(owner, struct {
            fn open(self: *zircon.Shell, _: *ui.Context(zircon.Shell), name: []const u8) !void {
                try self.openPath(name);
            }
        }.open, .{file});
        try app.update(owner, SaveOps.command, .{.save});
    }
    try expectFile(tmp.dir, "a.zig", "foo\nbar\n");
    try expectFile(tmp.dir, "b.zig", "foo\r\nbar\r\n");
    try expectFile(tmp.dir, "c.md", "foo  \nbar\t\n");
    try expectFile(tmp.dir, "empty.zig", "");
    const Open = struct {
        fn run(self: *zircon.Shell, _: *ui.Context(zircon.Shell), name: []const u8) !void {
            try self.openPath(name);
        }
    };
    try app.update(owner, Open.run, .{".zircon/settings.json"});
    try app.update(owner, SaveOps.replace, .{"{/* live */ \"tab_width\": 9,}"});
    try app.update(owner, SaveOps.command, .{.save});
    try t.expectEqual(9, try app.read(owner, SaveOps.width, .{0}));
    try app.update(owner, SaveOps.replace, .{"{/* invalid"});
    try app.update(owner, SaveOps.command, .{.save});
    try t.expect(try app.read(owner, SaveOps.statusError, .{}));
    try t.expectEqual(9, try app.read(owner, SaveOps.width, .{0}));
    try app.update(owner, Open.run, .{"settings.json"});
    try app.update(owner, SaveOps.replace, .{"{\"languages\":{\"ZiG\":{\"tab_width\": 12,}},}"});
    try app.update(owner, SaveOps.command, .{.save});
    try t.expect(!try app.read(owner, SaveOps.statusError, .{}));
    try t.expectEqual(12, try app.read(owner, SaveOps.width, .{0}));
}

test "settings project controls reset overrides and isolate workspace windows" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(t.io, "one/.zircon");
    try tmp.dir.createDirPath(t.io, "two/.zircon");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "one/.zircon/settings.json", .data = "{\"tab_width\": 8}" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "two/.zircon/settings.json", .data = "{\"tab_width\": 2}" });
    const one = try tmp.dir.realPathFileAlloc(t.io, "one", t.allocator);
    defer t.allocator.free(one);
    const two = try tmp.dir.realPathFileAlloc(t.io, "two", t.allocator);
    defer t.allocator.free(two);
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const h = try app.openWindow(zircon.Shell, .{ .visible = false, .width = 1000, .height = 700 }, try zircon.Shell.init(t.allocator, t.io, one, null));
    const first = try app.windowEntity(zircon.Shell, h);
    try app.update(first, zircon.Shell.bootstrap, .{h});
    const h2 = try app.openWindow(zircon.Shell, .{ .visible = false }, try zircon.Shell.init(t.allocator, t.io, two, null));
    const second = try app.windowEntity(zircon.Shell, h2);
    try app.update(second, SaveOps.useSettings, .{try app.read(first, SaveOps.shareSettings, .{})});
    try app.update(second, zircon.Shell.bootstrap, .{h2});
    try t.expectEqual(8, try app.read(first, SaveOps.width, .{0}));
    try t.expectEqual(2, try app.read(second, SaveOps.width, .{0}));
    try app.update(first, Ops.open, .{});
    _ = try app.step(0);
    const prefs = try app.read(first, Ops.child, .{});
    try clickLabel(&app, prefs, "Project");
    _ = try app.step(0);
    try t.expect(!try hasText(&app, prefs, "Color theme"));
    try t.expect(try hasText(&app, prefs, "Format on save"));
    try clickLabel(&app, prefs, "Reset");
    try t.expectEqual(4, try app.read(first, SaveOps.width, .{0}));
    try t.expectEqual(2, try app.read(second, SaveOps.width, .{0}));
}

test "settings autosave keeps per-document deadlines and honors focus window and disk changes" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(t.io, ".zircon");
    try tmp.dir.writeFile(t.io, .{ .sub_path = ".zircon/settings.json", .data =
        \\{"languages": {
        \\  "zig": {"autosave": "after_delay", "autosave_delay_ms": 200},
        \\  "rust": {"autosave": "after_delay", "autosave_delay_ms": 500},
        \\  "Markdown": {"autosave": "on_focus_change"},
        \\  "json": {"autosave": "on_window_change"}
        \\}}
    });
    for ([_][]const u8{ "a.zig", "b.rs", "c.md", "d.json", "conflict.zig" }) |path| {
        try tmp.dir.writeFile(t.io, .{ .sub_path = path, .data = "old\n" });
    }
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const h = try app.openWindow(zircon.Shell, .{ .visible = false }, try zircon.Shell.init(t.allocator, t.io, root, "a.zig"));
    const owner = try app.windowEntity(zircon.Shell, h);
    try app.update(owner, zircon.Shell.bootstrap, .{h});
    const Open = struct {
        fn run(self: *zircon.Shell, _: *ui.Context(zircon.Shell), path: []const u8) !void {
            try self.openPath(path);
        }
    };
    for ([_][]const u8{ "b.rs", "c.md", "d.json", "conflict.zig" }) |path| try app.update(owner, Open.run, .{path});
    _ = try app.step(1);
    try app.update(owner, SaveOps.select, .{@as(u32, 0)});
    try app.update(owner, SaveOps.replace, .{"first"});
    try app.update(owner, SaveOps.select, .{@as(u32, 1)});
    try app.update(owner, SaveOps.replace, .{"second"});
    _ = try app.step(1.21);
    try expectFile(tmp.dir, "a.zig", "first");
    try expectFile(tmp.dir, "b.rs", "old\n");
    _ = try app.step(1.51);
    try expectFile(tmp.dir, "b.rs", "second");

    try app.update(owner, SaveOps.select, .{@as(u32, 2)});
    try app.update(owner, SaveOps.replace, .{"focus"});
    try expectFile(tmp.dir, "c.md", "old\n");
    try app.update(owner, SaveOps.select, .{@as(u32, 3)});
    try expectFile(tmp.dir, "c.md", "focus");
    try app.update(owner, SaveOps.replace, .{"window"});
    try app.update(owner, SaveOps.select, .{@as(u32, 4)});
    try expectFile(tmp.dir, "d.json", "old\n");
    try app.dispatch(h, .{ .focus = false });
    try expectFile(tmp.dir, "d.json", "window");

    try app.update(owner, SaveOps.replace, .{"local"});
    try tmp.dir.writeFile(t.io, .{ .sub_path = "conflict.zig", .data = "external" });
    _ = try app.step(2);
    try expectFile(tmp.dir, "conflict.zig", "external");
}

test "settings format on save waits for two documents and falls back after a server error" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    try tmp.dir.createDirPath(t.io, ".zircon");
    try tmp.dir.writeFile(t.io, .{ .sub_path = ".zircon/settings.json", .data = "{\"tab_width\":2,\"format_on_save\":\"on\",\"ensure_final_newline_on_save\":true,\"remove_trailing_whitespace_on_save\":true}" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "main.zig", .data = "old \t" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "error.zig", .data = "failed \t" });
    const fixture = try std.mem.replaceOwned(u8, t.allocator, @embedFile("language_fixture"), "    elif method == \"textDocument/formatting\":",
        \\    elif method == "textDocument/formatting":
        \\        assert params["options"]["tabSize"] == 2
        \\        if params["textDocument"]["uri"].endswith("/error.zig"):
        \\            send({"jsonrpc": "2.0", "id": message["id"], "error": {"code": -32603, "message": "formatting failed"}})
        \\            continue
    );
    defer t.allocator.free(fixture);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "server.py", .data = fixture });
    try tmp.dir.createDirPath(t.io, "extensions/org.zircon.save");
    const server = try std.fs.path.join(t.allocator, &.{ root, "server.py" });
    defer t.allocator.free(server);
    const home = try std.fs.path.join(t.allocator, &.{ root, "extensions" });
    defer t.allocator.free(home);
    const manifest = try std.json.Stringify.valueAlloc(t.allocator, .{
        .schema_version = 1,
        .id = "org.zircon.save",
        .name = "Save Formatting",
        .version = "1.0.0",
        .contributes = .{ .language_servers = .{.{ .id = "save", .languages = .{"zig"}, .command = "python3", .args = .{ server, "host" } }} },
    }, .{});
    defer t.allocator.free(manifest);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "extensions/org.zircon.save/extension.json", .data = manifest });
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const h = try app.openWindow(zircon.Shell, .{ .visible = false }, try zircon.Shell.init(t.allocator, t.io, root, "main.zig"));
    const owner = try app.windowEntity(zircon.Shell, h);
    try app.update(owner, zircon.Shell.bootstrap, .{h});
    const Lsp = struct {
        fn configure(self: *zircon.Shell, cx: *ui.Context(zircon.Shell), extensions_home: []const u8) !void {
            try self.openPath("error.zig");
            try self.loadExtensions(cx, extensions_home);
        }
        fn ready(self: *const zircon.Shell) bool {
            if (self.language.documents.items.len != 2) return false;
            for (self.language.documents.items) |doc| {
                const client = self.language.sessions.items[doc.session].client orelse return false;
                if (doc.version == null or !client.ready()) return false;
            }
            return true;
        }
        fn pending(self: *const zircon.Shell) usize {
            return self.language.formatting.items.len;
        }
    };
    try app.update(owner, Lsp.configure, .{home});
    const deadline = std.Io.Clock.awake.now(t.io).addDuration(.fromSeconds(5));
    while (!try app.read(owner, Lsp.ready, .{})) {
        if (std.Io.Clock.awake.now(t.io).compare(.gte, deadline)) return error.FormatterReadinessTimeout;
        _ = try app.step(0);
        try std.Io.sleep(t.io, .fromMilliseconds(1), .awake);
    }
    try app.update(owner, SaveOps.command, .{.save});
    try app.update(owner, SaveOps.select, .{@as(u32, 0)});
    try app.update(owner, SaveOps.command, .{.save});
    while (try app.read(owner, Lsp.pending, .{}) != 0) {
        if (std.Io.Clock.awake.now(t.io).compare(.gte, deadline)) return error.FormatterReplyTimeout;
        _ = try app.step(0);
        try std.Io.sleep(t.io, .fromMilliseconds(1), .awake);
    }
    try expectFile(tmp.dir, "main.zig", "Fld\n");
    try expectFile(tmp.dir, "error.zig", "failed\n");
}

test "settings project scope cannot follow links outside the workspace" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(t.io, "project");
    try tmp.dir.createDirPath(t.io, "outside");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "outside/settings.json", .data = "{\"tab_width\": 11}" });
    try tmp.dir.symLink(t.io, "../outside", "project/.zircon", .{ .is_directory = true });
    const root = try tmp.dir.realPathFileAlloc(t.io, "project", t.allocator);
    defer t.allocator.free(root);
    var store = try zircon.SettingsStore.init(t.allocator, t.io, null);
    defer store.deinit();
    if (store.setProjectRoot(root)) |_| return error.ProjectDirectoryLinkWasFollowed else |_| {}
    if (store.updateScope(.project, .{ .tab_width = 2 })) |_| return error.ProjectDirectoryLinkWasWritten else |_| {}
    try expectFile(tmp.dir, "outside/settings.json", "{\"tab_width\": 11}");
    try tmp.dir.deleteFile(t.io, "project/.zircon");
    try tmp.dir.createDirPath(t.io, "project/.zircon");
    try tmp.dir.symLink(t.io, "../../outside/settings.json", "project/.zircon/settings.json", .{});
    try t.expectError(error.NotRegularFile, store.reload());
    try t.expectError(error.NotRegularFile, store.ensureScopeFile(.project));
    try t.expectEqual(4, store.values().tab_width);
}

test "terminal settings persist in User scope and reject project overrides" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(t.io, ".zircon");
    try tmp.dir.writeFile(t.io, .{ .sub_path = ".zircon/settings.json", .data = "{\"terminal_shell\":\"/other/sh\",\"terminal_option_as_meta\":true}" });
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const path = try std.fs.path.resolve(t.allocator, &.{ root, "settings.json" });
    defer t.allocator.free(path);
    var store = try zircon.SettingsStore.init(t.allocator, t.io, path);
    defer store.deinit();
    try store.setProjectRoot(root);
    try t.expectEqual(2, store.ignored_project_keys);
    try t.expect(!store.values().terminal_option_as_meta);
    try t.expectError(error.DisallowedProjectSetting, store.updateScope(.project, .{ .terminal_font_size = 13 }));
    try t.expectError(error.InvalidSettings, store.update(.{ .terminal_font_size = 9 }));
    try t.expectError(error.InvalidSettings, store.update(.{ .terminal_max_scroll_history = 100_001 }));
    try t.expectError(error.InvalidSettings, store.update(.{ .terminal_shell = "/bin/sh\x00ignored" }));
    try store.update(.{ .terminal_shell = "/bin/sh" });
    try store.update(.{ .terminal_font_size = 18 });
    try store.update(.{ .terminal_max_scroll_history = 0 });
    try store.update(.{ .terminal_copy_on_select = true });
    try store.reload();
    const values = store.values();
    try t.expectEqualStrings("/bin/sh", values.terminal_shell);
    try t.expectEqual(@as(f32, 18), values.terminal_font_size);
    try t.expectEqual(0, values.terminal_max_scroll_history);
    try t.expect(values.terminal_copy_on_select);
}
