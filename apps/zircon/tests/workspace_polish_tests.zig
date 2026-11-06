const std = @import("std");
const ui = @import("zircon_ui");
const zircon = @import("zircon");
const t = std.testing;

fn open(app: *ui.App, settings_path: ?[]const u8) !ui.WindowHandle {
    const shell = try zircon.Shell.init(t.allocator, t.io, ".", null);
    const h = try app.openWindow(zircon.Shell, .{ .visible = false, .width = 1000, .height = 700 }, shell);
    const owner = try app.windowEntity(zircon.Shell, h);
    if (settings_path != null) try app.update(owner, zircon.Shell.loadSettings, .{settings_path});
    try app.update(owner, zircon.Shell.bootstrap, .{h});
    _ = try app.step(0);
    return h;
}
const Ops = struct {
    fn command(self: *zircon.Shell, cx: *ui.Context(zircon.Shell), action: zircon.Command) !void {
        var e: ui.Event(ui.Click) = .{ .data = .{} };
        try self.onCommand(&e, cx, action);
    }
    fn theme(self: *zircon.Shell, cx: *ui.Context(zircon.Shell), id: []const u8) !void {
        try cx.update(self.settings.?, zircon.Settings.apply, .{zircon.SettingsPatch{ .theme = id }});
    }
    fn light(self: *const zircon.Shell) bool {
        return self.colors.document.r > 0.8 and self.editor_options.theme.background.r > 0.8;
    }
    fn inputsLight(self: *zircon.Shell, cx: *ui.Context(zircon.Shell)) !bool {
        const Read = struct {
            fn light(input: *const ui.controls.TextInput) bool {
                return input.appearance.background.r > 0.8;
            }
        };
        return cx.read(self.fields.?.project_query, Read.light, .{});
    }
};
fn bounds(app: *ui.App, h: ui.WindowHandle, key: []const u8) !ui.Rect {
    const frame = &(try app.window(h)).frames.committed;
    for (frame.nodes.items, 0..) |node, i| if (node.key) |value| if (value == .string and std.mem.eql(u8, value.string, key)) return frame.bounds[i];
    return error.MissingElement;
}
fn drag(app: *ui.App, h: ui.WindowHandle, key: []const u8, destination: ui.Point) !void {
    const rect = try bounds(app, h, key);
    try app.dispatch(h, .{ .pointer_down = .{ .position = .{ .x = rect.x + rect.width / 2, .y = rect.y + rect.height / 2 } } });
    try app.dispatch(h, .{ .pointer_move = .{ .position = destination } });
    _ = try app.step(1);
    try app.dispatch(h, .{ .pointer_up = .{ .position = destination } });
    _ = try app.step(1);
}
test "all directional splits arrange the new pane in the requested direction and resize" {
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const h = try open(&app, null);
    const owner = try app.windowEntity(zircon.Shell, h);
    inline for (.{ zircon.Command.split_left, zircon.Command.split_right, zircon.Command.split_up, zircon.Command.split_down }) |action| {
        try app.update(owner, Ops.command, .{action});
        _ = try app.step(1);
        const primary = try bounds(&app, h, "primary-editor");
        const secondary = try bounds(&app, h, "secondary-editor");
        const panes = try bounds(&app, h, "panes");
        try t.expect(primary.y + primary.height <= panes.y + panes.height + 0.1);
        try t.expect(secondary.y + secondary.height <= panes.y + panes.height + 0.1);
        switch (action) {
            .split_left => try t.expect(secondary.x < primary.x and secondary.width > 300),
            .split_right => try t.expect(secondary.x > primary.x and primary.width > 300),
            .split_up => try t.expect(secondary.y < primary.y and secondary.height > 200),
            .split_down => try t.expect(secondary.y > primary.y and primary.height > 200),
            else => unreachable,
        }
    }
    try drag(&app, h, "pane-divider", .{ .x = 700, .y = 500 });
    try t.expect((try bounds(&app, h, "primary-editor")).height > (try bounds(&app, h, "secondary-editor")).height);
    try app.update(owner, Ops.command, .{.close_split});
    _ = try app.step(1);
    try t.expectError(error.MissingElement, bounds(&app, h, "secondary-editor"));
}
test "sidebar can shrink to 120 pixels while Git retains its own width" {
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const h = try open(&app, null);
    const owner = try app.windowEntity(zircon.Shell, h);
    try drag(&app, h, "sidebar-divider", .{ .x = 120, .y = 200 });
    try t.expectApproxEqAbs(@as(f32, 120), (try bounds(&app, h, "sidebar")).width, 0.1);
    try app.update(owner, Ops.command, .{.git_changes});
    _ = try app.step(1);
    try drag(&app, h, "sidebar-divider", .{ .x = 210, .y = 200 });
    try app.update(owner, Ops.command, .{.project_files});
    _ = try app.step(1);
    try t.expectApproxEqAbs(@as(f32, 120), (try bounds(&app, h, "sidebar")).width, 0.1);
}
test "system appearance updates fields and canvases while explicit themes ignore it" {
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const h = try open(&app, null);
    const owner = try app.windowEntity(zircon.Shell, h);
    try app.update(owner, Ops.theme, .{"zircon.system"});
    try app.dispatch(h, .{ .appearance = false });
    _ = try app.step(1);
    try t.expect(try app.read(owner, Ops.light, .{}));
    try t.expect(try app.update(owner, Ops.inputsLight, .{}));
    try app.dispatch(h, .{ .appearance = true });
    _ = try app.step(1);
    try t.expect(!try app.read(owner, Ops.light, .{}));
    try app.update(owner, Ops.theme, .{"zircon.light"});
    try app.dispatch(h, .{ .appearance = true });
    _ = try app.step(1);
    try t.expect(try app.read(owner, Ops.light, .{}));
}
test "persisted shortcut overrides drive splits and menus show their effective binding" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "settings.json", .data =
        \\{"key_bindings":{"cmd-ctrl-r":"split_down","cmd-alt-right":null}}
    });
    const path = try tmp.dir.realPathFileAlloc(t.io, "settings.json", t.allocator);
    defer t.allocator.free(path);
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const h = try open(&app, path);
    try app.dispatch(h, .{ .key_down = .{ .key = .right, .modifiers = .{ .command = true, .alt = true } } });
    _ = try app.step(1);
    try t.expectError(error.MissingElement, bounds(&app, h, "secondary-editor"));
    try app.dispatch(h, .{ .key_down = .{ .key = .r, .modifiers = .{ .command = true, .control = true } } });
    _ = try app.step(1);
    try t.expect((try bounds(&app, h, "secondary-editor")).y > (try bounds(&app, h, "primary-editor")).y);
    const owner = try app.windowEntity(zircon.Shell, h);
    try app.update(owner, Ops.command, .{.split_menu});
    _ = try app.step(1);
    var effective = false;
    for ((try app.window(h)).frames.committed.nodes.items) |node| if (node.kind == .text and std.mem.eql(u8, node.kind.text, "⌃⌘R")) {
        effective = true;
    };
    try t.expect(effective);
}

test "settings reject unsafe unknown and ambiguous shortcut configuration" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(path);
    const file = try std.fs.path.join(t.allocator, &.{ path, "settings.json" });
    defer t.allocator.free(file);
    inline for (.{
        .{ "{\"key_bindings\":{\"a\":\"split_left\"}}", error.InvalidKeyBindings },
        .{ "{\"key_bindings\":{\"cmd-r\":\"submit_project\"}}", error.InvalidKeyBindings },
        .{ "{\"key_bindings\":{\"cmd-r\":\"nonexistent\"}}", error.InvalidKeyBindings },
        .{ "{\"key_bindings\":{\"cmd-ctrl-r\":\"split_left\",\"ctrl-cmd-r\":\"split_right\"}}", error.DuplicateKeyBinding },
    }) |item| {
        try tmp.dir.writeFile(t.io, .{ .sub_path = "settings.json", .data = item[0] });
        try t.expectError(item[1], zircon.SettingsStore.init(t.allocator, t.io, file));
    }
}

test "split popover anchors to the clicked pane control and clamps inside a narrow window" {
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const h = try open(&app, null);
    const owner = try app.windowEntity(zircon.Shell, h);
    try app.update(owner, Ops.command, .{.split_down});
    _ = try app.step(0);
    var anchor: ui.Rect = .{};
    const frame = &(try app.window(h)).frames.committed;
    for (frame.nodes.items, 0..) |node, i| if (node.kind == .button and std.mem.eql(u8, node.kind.button.label, "Split editor") and frame.bounds[i].y > anchor.y) {
        anchor = frame.bounds[i];
    };
    try t.expect(anchor.y > 200);
    const point: ui.Point = .{ .x = anchor.x + anchor.width / 2, .y = anchor.y + anchor.height / 2 };
    try app.dispatch(h, .{ .pointer_down = .{ .position = point } });
    try app.dispatch(h, .{ .pointer_up = .{ .position = point } });
    _ = try app.step(0);
    var popup = try bounds(&app, h, "split-menu");
    try t.expectApproxEqAbs(anchor.y + anchor.height + 4, popup.y, 0.1);
    try t.expect(popup.x >= 6 and popup.x + popup.width <= 994);
    try app.dispatch(h, .{ .resize = .{ .width = 480, .height = 340 } });
    _ = try app.step(0);
    popup = try bounds(&app, h, "split-menu");
    try t.expect(popup.x >= 6 and popup.x + popup.width <= 474);
    try t.expect(popup.y >= 6 and popup.y + popup.height <= 334);
}

test "Vim slash search uses the focused find field and returns to Normal" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "settings.json", .data = "{\"vim_mode\":true}" });
    const path = try tmp.dir.realPathFileAlloc(t.io, "settings.json", t.allocator);
    defer t.allocator.free(path);
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const h = try open(&app, path);
    // Type a source buffer through Insert mode.
    try app.dispatch(h, .{ .text = "i" });
    try app.dispatch(h, .{ .text = "one two one" });
    try app.dispatch(h, .{ .key_down = .{ .key = .escape } });
    try app.dispatch(h, .{ .text = "0" });
    try app.dispatch(h, .{ .text = "/" });
    _ = try app.step(0);
    try app.dispatch(h, .{ .text = "two" });
    try app.dispatch(h, .{ .key_down = .{ .key = .enter } });
    _ = try app.step(0);
    const Read = struct {
        fn matched(self: *const zircon.Shell) bool {
            return self.overlay == .none and !self.find.visible and self.tabs.items[0].editor.vim.mode == .normal and self.tabs.items[0].editor.primary().head == 4;
        }
    };
    const owner = try app.windowEntity(zircon.Shell, h);
    const deadline = std.Io.Clock.awake.now(t.io).addDuration(.fromSeconds(5));
    while (!try app.read(owner, Read.matched, .{})) {
        _ = try app.step(0);
        if (std.Io.Clock.awake.now(t.io).compare(.gte, deadline)) return error.FindTimeout;
        try std.Io.sleep(t.io, .fromMilliseconds(1), .awake);
    }
    try t.expect(try app.read(owner, Read.matched, .{}));
}

test "compact command palette preserves query height, source visibility and outside dismissal" {
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const h = try open(&app, null);
    const owner = try app.windowEntity(zircon.Shell, h);
    try app.update(owner, Ops.command, .{.palette});
    _ = try app.step(0);
    const query = try bounds(&app, h, "query");
    try t.expectApproxEqAbs(@as(f32, 38), query.height, 0.01);
    const dialog = try bounds(&app, h, "dialog");
    try t.expect(dialog.width <= 560 and dialog.height < 500);
    for ((try app.window(h)).frames.committed.scene.items) |item| if (item.kind == .rect and item.rect.width >= 1000 and item.rect.height >= 700) try t.expect(item.color.a == 1 or item.color.a == 0);
    try app.dispatch(h, .{ .pointer_down = .{ .position = .{ .x = 15, .y = 600 } } });
    _ = try app.step(0);
    try t.expectError(error.MissingElement, bounds(&app, h, "dialog"));
}
test "opened nested source reveals only its project ancestors" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(t.io, "src/nested");
    try tmp.dir.createDirPath(t.io, "unrelated");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "src/nested/main.zig", .data = "const n = 1;\n" });
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    var shell = try zircon.Shell.init(t.allocator, t.io, root, "src/nested/main.zig");
    defer shell.deinit(t.allocator);
    var source_visible = false;
    for (shell.tree.items) |row| {
        if (std.mem.eql(u8, row.name, "main.zig")) source_visible = true;
        if (std.mem.eql(u8, row.name, "unrelated")) try t.expect(!row.expanded);
    }
    try t.expect(source_visible);
}

test "breadcrumb returns focus to the pane that supplied its document" {
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const h = try open(&app, null);
    const owner = try app.windowEntity(zircon.Shell, h);
    try app.update(owner, Ops.command, .{.split_right});
    const Call = struct {
        fn primary(self: *zircon.Shell, cx: *ui.Context(zircon.Shell)) !void {
            self.active_pane = .secondary;
            var event: ui.Event(ui.Click) = .{ .data = .{} };
            try self.onBreadcrumb(&event, cx, .{ .document = self.tabs.items[0].document, .prefix = 0, .pane = 0 });
        }
        fn focused(self: *const zircon.Shell) bool {
            return self.active_pane == .primary;
        }
    };
    try app.update(owner, Call.primary, .{});
    try t.expect(try app.read(owner, Call.focused, .{}));
}

test "language install suggestions translate suffixes and exact filenames into catalog terms" {
    try t.expectEqualStrings("elixir", zircon.languageSuggestion("src/router.ex"));
    try t.expectEqualStrings("terraform", zircon.languageSuggestion("infra/main.tf"));
    try t.expectEqualStrings("csharp", zircon.languageSuggestion("src/App.CS"));
    try t.expectEqualStrings("dockerfile", zircon.languageSuggestion("project/Dockerfile"));
    try t.expectEqualStrings("ruby", zircon.languageSuggestion("project/Gemfile"));
    try t.expectEqualStrings("zig", zircon.languageSuggestion("build.zig.zon"));
    try t.expectEqualStrings("yaml", zircon.languageSuggestion(".github/workflows/build.yml"));
    try t.expectEqualStrings("unknownlanguage", zircon.languageSuggestion("file.unknownlanguage"));
    try t.expectEqualStrings("customfilename", zircon.languageSuggestion("customfilename"));
}

test "small windows keep editor canvases above the status bar" {
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const h = try open(&app, null);
    const owner = try app.windowEntity(zircon.Shell, h);
    try app.update(owner, Ops.command, .{.new_file});
    for ([_]ui.Size{ .{ .width = 700, .height = 650 }, .{ .width = 700, .height = 400 } }) |size| {
        try app.dispatch(h, .{ .resize = size });
        _ = try app.step(0);
        const status = try bounds(&app, h, "status");
        const primary = try bounds(&app, h, "primary-editor");
        try t.expect(primary.y + primary.height <= status.y + 0.1);
    }
}

test "narrow command palette gives long commands room and stays within the window" {
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const h = try open(&app, null);
    const owner = try app.windowEntity(zircon.Shell, h);
    try app.dispatch(h, .{ .resize = .{ .width = 700, .height = 650 } });
    try app.update(owner, Ops.command, .{.palette});
    _ = try app.step(0);
    try app.dispatch(h, .{ .text = "Extensions: install language support" });
    _ = try app.step(0);
    const dialog = try bounds(&app, h, "dialog");
    try t.expect(dialog.x >= 24 and dialog.x + dialog.width <= 676);
    var found = false;
    for ((try app.window(h)).frames.committed.scene.items) |item| if (item.kind == .text and std.mem.startsWith(u8, item.text, "Extensions: install language support")) {
        found = true;
        try t.expect(item.rect.x + item.rect.width < dialog.x + dialog.width - 10);
    };
    try t.expect(found);
}

test "only the focused split paints the active line and focus moves with a click" {
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const h = try open(&app, null);
    const owner = try app.windowEntity(zircon.Shell, h);
    try app.update(owner, Ops.command, .{.new_file});
    try app.update(owner, Ops.command, .{.split_right});
    _ = try app.step(0);
    const Read = struct {
        fn activeLine(self: *const zircon.Shell) ui.Color {
            return self.editor_options.theme.active_line;
        }
    };
    const color = try app.read(owner, Read.activeLine, .{});
    const primary = try bounds(&app, h, "primary-editor");
    const secondary = try bounds(&app, h, "secondary-editor");
    for ([_]ui.Rect{ secondary, primary }) |focused| {
        const p: ui.Point = .{ .x = focused.x + focused.width / 2, .y = focused.y + 10 };
        try app.dispatch(h, .{ .pointer_down = .{ .position = p } });
        try app.dispatch(h, .{ .pointer_up = .{ .position = p } });
        _ = try app.step(0);
        var found = false;
        for ((try app.window(h)).frames.committed.scene.items) |item| if (item.kind == .rect and item.rect.x >= primary.x and item.rect.y >= primary.y and item.rect.width > 100 and item.rect.height < 30 and std.meta.eql(item.color, color)) {
            found = true;
            try t.expect(item.rect.x >= focused.x and item.rect.x + item.rect.width <= focused.x + focused.width + 0.1);
        };
        try t.expect(found);
    }
}
