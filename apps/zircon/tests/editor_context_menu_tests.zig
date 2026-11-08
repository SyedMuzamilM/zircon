const std = @import("std");
const zircon = @import("zircon");
const ui = @import("zircon_ui");
const t = std.testing;
const Geometry = struct { font: f32, line: f32 };
const Ops = struct {
    fn select(self: *zircon.Shell, cx: *ui.Context(zircon.Shell), start: usize, end: usize) void {
        self.tabs.items[self.active].editor.selections.single(.{ .anchor = start, .head = end });
        cx.notify();
    }
    fn selection(self: *const zircon.Shell, start: usize, end: usize, pane: u8) !void {
        const state = if (pane == 1) &self.secondary.?.editor else &self.tabs.items[self.active].editor;
        try t.expectEqual(start, state.primary().anchor);
        try t.expectEqual(end, state.primary().head);
    }
    fn geometry(self: *const zircon.Shell) Geometry {
        const state = &self.tabs.items[self.active].editor;
        return .{ .font = state.font_size, .line = state.line_height };
    }
    fn closed(self: *const zircon.Shell) bool {
        return self.editor_context_menu == null;
    }
    fn command(self: *zircon.Shell, cx: *ui.Context(zircon.Shell), which: zircon.Command) !void {
        var event: ui.Event(ui.Click) = .{ .data = .{} };
        try self.onCommand(&event, cx, which);
    }
};
fn bounds(app: *ui.App, h: ui.WindowHandle, key: []const u8) !ui.Rect {
    const frame = &(try app.window(h)).frames.committed;
    for (frame.nodes.items, 0..) |node, index| if (node.key) |value| if (value == .string and std.mem.eql(u8, value.string, key)) return frame.bounds[index];
    return error.MissingElement;
}
fn clickLabel(app: *ui.App, h: ui.WindowHandle, label: []const u8) !void {
    const frame = &(try app.window(h)).frames.committed;
    const rect = for (frame.nodes.items, 0..) |node, index| {
        if (node.kind == .button and std.mem.eql(u8, node.kind.button.label, label)) break frame.bounds[index];
    } else return error.MissingButton;
    try click(app, h, .{ .x = rect.x + rect.width / 2, .y = rect.y + rect.height / 2 }, .primary);
}
fn click(app: *ui.App, h: ui.WindowHandle, position: ui.Point, button: anytype) !void {
    try app.dispatch(h, .{ .pointer_down = .{ .position = position, .button = button } });
    try app.dispatch(h, .{ .pointer_up = .{ .position = position, .button = button } });
    _ = try app.step(0);
}
fn point(app: *ui.App, h: ui.WindowHandle, pane: u8, column: usize) !ui.Point {
    const owner = try app.windowEntity(zircon.Shell, h);
    const geometry = try app.read(owner, Ops.geometry, .{});
    const rect = try bounds(app, h, if (pane == 1) "secondary-editor" else "primary-editor");
    const metrics = (try app.window(h)).surface.?.measurer();
    return .{ .x = rect.x + 76 + metrics.caret("  alpha beta", .{ .size = geometry.font, .mono = true }, column), .y = rect.y + geometry.line / 2 };
}

test "editor context menu preserves selected code copies trimmed text and targets split panes" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "main.zig", .data = "  alpha beta\nsecond line\n" });
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const h = try app.openWindow(zircon.Shell, .{ .visible = false, .width = 1100, .height = 760 }, try zircon.Shell.init(t.allocator, t.io, root, "main.zig"));
    const owner = try app.windowEntity(zircon.Shell, h);
    try app.update(owner, zircon.Shell.bootstrap, .{h});
    try app.update(owner, Ops.select, .{ @as(usize, 0), @as(usize, 7) });
    _ = try app.step(0);
    try click(&app, h, try point(&app, h, 0, 3), .secondary);
    try app.read(owner, Ops.selection, .{ @as(usize, 0), @as(usize, 7), @as(u8, 0) });
    const menu = try bounds(&app, h, "editor-context-menu");
    try t.expect(menu.x >= 0 and menu.y >= 0 and menu.x + menu.width <= 1100 and menu.y + menu.height <= 760);
    var definition_disabled = false;
    for ((try app.window(h)).frames.committed.nodes.items) |node| if (node.kind == .button and std.mem.eql(u8, node.kind.button.label, "Go to Definition")) {
        definition_disabled = node.kind.button.on_click == null;
    };
    try t.expect(definition_disabled);
    if (comptime ui.testing.native != void) try (try app.window(h)).snapshot("/tmp/zircon-editor-context-menu.png");
    try clickLabel(&app, h, "Copy and Trim");
    try t.expect(try app.read(owner, Ops.closed, .{}));
    const surface = (try app.window(h)).surface.?;
    const copied = try surface.ops.clipboard_read(surface.context, t.allocator);
    defer t.allocator.free(copied);
    try t.expectEqualStrings("alpha", copied);
    try click(&app, h, try point(&app, h, 0, 10), .secondary);
    try app.read(owner, Ops.selection, .{ @as(usize, 10), @as(usize, 10), @as(u8, 0) });
    try app.dispatch(h, .{ .key_down = .{ .key = .escape } });
    _ = try app.step(0);
    try t.expect(try app.read(owner, Ops.closed, .{}));
    try click(&app, h, try point(&app, h, 0, 3), .secondary);
    _ = try bounds(&app, h, "editor-context-menu");
    try click(&app, h, .{ .x = 20, .y = 200 }, .primary);
    try t.expect(try app.read(owner, Ops.closed, .{}));
    try app.update(owner, Ops.command, .{.split_right});
    _ = try app.step(0);
    try click(&app, h, try point(&app, h, 1, 4), .secondary);
    try app.read(owner, Ops.selection, .{ @as(usize, 4), @as(usize, 4), @as(u8, 1) });
    try app.read(owner, Ops.selection, .{ @as(usize, 3), @as(usize, 3), @as(u8, 0) });
    try app.dispatch(h, .{ .key_down = .{ .key = .enter } });
    try t.expect(try app.read(owner, Ops.closed, .{}));
    try app.read(owner, Ops.selection, .{ @as(usize, 9), @as(usize, 9), @as(u8, 1) });
}
