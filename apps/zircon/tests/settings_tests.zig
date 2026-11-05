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
    try t.expectError(error.InvalidSettings, store.update(.{ .font_size = 0 }));
    try t.expectEqual(@as(f32, 18), store.values().font_size);
    var reopened = try zircon.SettingsStore.init(t.allocator, t.io, path);
    defer reopened.deinit();
    try t.expectEqual(@as(f32, 18), reopened.values().font_size);
    try t.expectEqualStrings("zircon.light", reopened.values().theme);
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
        try app.dispatch(h, .{ .pointer_down = .{ .position = point } });
        try app.dispatch(h, .{ .pointer_up = .{ .position = point } });
        return;
    };
    return error.ControlNotFound;
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
    try clickLabel(&app, child, "Light");
    _ = try app.step(2);
    try t.expect(try app.read(owner, Ops.light, .{}));
    try clickLabel(&app, child, "Editor");
    _ = try app.step(3);
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
