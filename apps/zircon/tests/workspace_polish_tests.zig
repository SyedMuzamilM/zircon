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
