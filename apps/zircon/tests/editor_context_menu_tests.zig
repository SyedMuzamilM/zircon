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
    fn row(self: *const zircon.Shell, index: usize) !void {
        try t.expectEqual(index, self.editor_context_menu.?.selected);
        try t.expect(self.editor_context_menu.?.keyboard);
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
fn buttonBounds(app: *ui.App, h: ui.WindowHandle, label: []const u8) !ui.Rect {
    const frame = &(try app.window(h)).frames.committed;
    return for (frame.nodes.items, 0..) |node, index| {
        if (node.kind == .button and std.mem.eql(u8, node.kind.button.label, label)) break frame.bounds[index];
    } else error.MissingButton;
}
fn clickLabel(app: *ui.App, h: ui.WindowHandle, label: []const u8) !void {
    const rect = try buttonBounds(app, h, label);
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

fn menuPersistence() !void {
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
    _ = try app.step(0);
    const at = try point(&app, h, 0, 3);
    try app.dispatch(h, .{ .pointer_down = .{ .position = at, .button = .secondary } });
    _ = try app.step(0);
    try t.expect(!try app.read(owner, Ops.closed, .{}));
    try app.dispatch(h, .{ .pointer_up = .{ .position = at, .button = .secondary } });
    _ = try app.step(0.01);
    try app.dispatch(h, .{ .pointer_move = .{ .position = .{ .x = at.x + 20, .y = at.y + 25 } } });
    _ = try app.step(0.1);
    try t.expect(!try app.read(owner, Ops.closed, .{}));
    _ = try bounds(&app, h, "editor-context-menu");
}

test "editor context menu ignores the gutter and follows the pointer across enabled rows" {
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
    try app.update(owner, Ops.select, .{ @as(usize, 2), @as(usize, 7) });
    _ = try app.step(0);
    const editor_bounds = try bounds(&app, h, "primary-editor");
    try click(&app, h, .{ .x = editor_bounds.x + 8, .y = editor_bounds.y + 11 }, .secondary);
    try t.expect(try app.read(owner, Ops.closed, .{}));
    try app.read(owner, Ops.selection, .{ @as(usize, 2), @as(usize, 7), @as(u8, 0) });
    try click(&app, h, try point(&app, h, 0, 3), .secondary);
    try t.expect(!try app.read(owner, Ops.closed, .{}));
    const copy = try buttonBounds(&app, h, "Copy");
    try app.dispatch(h, .{ .pointer_move = .{ .position = .{ .x = copy.x + copy.width / 2, .y = copy.y + copy.height / 2 } } });
    _ = try app.step(0);
    try app.read(owner, Ops.row, .{@as(usize, 7)});
    const definition = try buttonBounds(&app, h, "Go to Definition");
    try app.dispatch(h, .{ .pointer_move = .{ .position = .{ .x = definition.x + 12, .y = definition.y + definition.height / 2 } } });
    _ = try app.step(0);
    try app.read(owner, Ops.row, .{@as(usize, 7)});
    try t.expect(!try app.read(owner, Ops.closed, .{}));
}

test "editor context menu stays open across press release movement and redraw" {
    try menuPersistence();
}

test "editor context menu survives AppKit right mouse events and idle frames" {
    if (comptime ui.testing.native == void) return error.SkipZigTest;
    const native = ui.testing.native;
    const objc = native.objc;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "main.zig", .data = "  alpha beta\nsecond line\n" });
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const title = "Zircon right mouse persistence";
    const h = try app.openWindow(zircon.Shell, .{ .title = title, .visible = false, .width = 1100, .height = 760 }, try zircon.Shell.init(t.allocator, t.io, root, "main.zig"));
    const owner = try app.windowEntity(zircon.Shell, h);
    try app.update(owner, zircon.Shell.bootstrap, .{h});
    _ = try app.step(0);
    const nsapp = objc.send(objc.Id, objc.class("NSApplication"), "sharedApplication", .{});
    const windows = objc.send(objc.Id, nsapp, "windows", .{});
    const window = for (0..objc.send(usize, windows, "count", .{})) |index| {
        const candidate = objc.send(objc.Id, windows, "objectAtIndex:", .{index});
        if (std.mem.eql(u8, title, objc.fromString(objc.send(objc.Id, candidate, "title", .{})))) break candidate;
    } else return error.NativeWindowMissing;
    const view = objc.send(objc.Id, window, "contentView", .{});
    const at = try point(&app, h, 0, 3);
    const location = objc.send(objc.CGPoint, view, "convertPoint:toView:", .{ objc.CGPoint{ .x = at.x, .y = at.y }, @as(objc.Id, null) });
    for ([_]usize{ 3, 4, 5 }) |kind| {
        const event = objc.send(objc.Id, objc.class("NSEvent"), "mouseEventWithType:location:modifierFlags:timestamp:windowNumber:context:eventNumber:clickCount:pressure:", .{ kind, location, @as(usize, 0), native.now(), objc.send(isize, window, "windowNumber", .{}), @as(objc.Id, null), @as(isize, 0), @as(isize, 1), @as(f32, 1) });
        objc.send(void, view, if (kind == 3) "rightMouseDown:" else if (kind == 4) "rightMouseUp:" else "mouseMoved:", .{event});
        try native.pump(0);
        _ = try app.step(0);
        try t.expect(!try app.read(owner, Ops.closed, .{}));
    }
    for (0..5) |index| {
        _ = try app.step(@as(f64, @floatFromInt(index + 1)));
        try t.expect(!try app.read(owner, Ops.closed, .{}));
    }
}

test "editor context menu stays open through residual trackpad scrolling" {
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
    _ = try app.step(0);
    const at = try point(&app, h, 0, 3);
    try click(&app, h, at, .secondary);
    try app.dispatch(h, .{ .scroll = .{ .position = at, .x = 0, .y = 0.01 } });
    _ = try app.step(0.1);
    try t.expect(!try app.read(owner, Ops.closed, .{}));
}
