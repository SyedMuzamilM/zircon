//! Native and portable journeys for buffer controls, icons and hover behavior.
const std = @import("std");
const ui = @import("zircon_ui");
const zircon = @import("zircon");
const t = std.testing;
fn settle(app: *ui.App) !void {
    const deadline = std.Io.Clock.awake.now(t.io).addDuration(.fromSeconds(5));
    while (try app.tasksPending()) {
        _ = try app.step(0);
        if (std.Io.Clock.awake.now(t.io).compare(.gte, deadline)) return error.JourneyTimeout;
        std.Io.sleep(t.io, .fromMilliseconds(1), .awake) catch {};
    }
    _ = try app.step(0);
}
const Ops = struct {
    fn execute(self: *zircon.Shell, cx: *ui.Context(zircon.Shell), which: zircon.Command) !void {
        var event: ui.Event(ui.Click) = .{ .data = .{} };
        try self.onCommand(&event, cx, which);
        if (self.status_is_error) return error.CommandFailed;
    }
    fn configure(self: *zircon.Shell, cx: *ui.Context(zircon.Shell), home: []const u8) !void {
        try self.loadExtensions(cx, home);
    }
    fn open(self: *zircon.Shell, cx: *ui.Context(zircon.Shell), path: []const u8) !void {
        try self.openPath(path);
        cx.notify();
    }
    fn source(self: *const zircon.Shell, a: std.mem.Allocator, output: *[]u8) !void {
        var snapshot = try self.workspace.snapshot(self.tabs.items[self.active].document);
        defer snapshot.deinit();
        output.* = try snapshot.copy(a, .{ .start = 0, .end = snapshot.byteLen() });
    }
};
fn open(app: *ui.App, root: []const u8, file: []const u8) !ui.WindowHandle {
    var shell = try zircon.Shell.init(t.allocator, t.io, root, file);
    const h = app.openWindow(zircon.Shell, .{ .visible = false, .width = 1200, .height = 760 }, shell) catch |err| {
        shell.deinit(t.allocator);
        return err;
    };
    try app.update(try app.windowEntity(zircon.Shell, h), zircon.Shell.bootstrap, .{h});
    try settle(app);
    return h;
}
fn send(app: *ui.App, h: ui.WindowHandle, which: zircon.Command) !void {
    try app.update(try app.windowEntity(zircon.Shell, h), Ops.execute, .{which});
    _ = try app.step(0);
}
fn click(app: *ui.App, h: ui.WindowHandle, label: []const u8) !void {
    const frame = &(try app.window(h)).frames.committed;
    for (frame.nodes.items, 0..) |node, index| if (node.kind == .button and std.mem.eql(u8, node.kind.button.label, label)) {
        const bounds = frame.bounds[index];
        const point: ui.Point = .{ .x = bounds.x + bounds.width / 2, .y = bounds.y + bounds.height / 2 };
        try app.dispatch(h, .{ .pointer_down = .{ .position = point } });
        try app.dispatch(h, .{ .pointer_up = .{ .position = point } });
        _ = try app.step(0);
        return;
    };
    return error.ControlNotFound;
}
fn elementBounds(app: *ui.App, h: ui.WindowHandle, name: []const u8) !ui.Rect {
    const frame = &(try app.window(h)).frames.committed;
    for (frame.nodes.items, 0..) |node, index| if (node.key) |key| if (key == .string and std.mem.eql(u8, key.string, name)) return frame.bounds[index];
    return error.ElementNotFound;
}
test "icon theme decodes filename-stem assets as well as extension assets" {
    if (comptime ui.testing.native == void) return error.SkipZigTest;
    var shell = try zircon.Shell.init(t.allocator, t.io, ".", null);
    defer shell.deinit(t.allocator);
    var cache = try @TypeOf(shell.icons).init(t.allocator, &.{ .id = "stem-theme", .name = "Stem theme", .files = &.{}, .extensions = &.{}, .folders = &.{}, .stems = &.{.{ .key = "Dockerfile", .icon = .{ .png = .{ .path = "stem.png", .bytes = @embedFile("image_fixture") } } }}, .default_file = .{ .symbol = "F" }, .default_folder = .{ .symbol = "D" } });
    defer cache.deinit(t.allocator);
    try t.expect(cache.find("stem.png") != null);
}

fn waitBufferFind(app: *ui.App, h: ui.WindowHandle) !void {
    const Read = struct {
        fn pending(self: *const zircon.Shell) bool {
            return self.find.waiting or self.find.busy;
        }
    };
    const owner = try app.windowEntity(zircon.Shell, h);
    const deadline = std.Io.Clock.awake.now(t.io).addDuration(.fromSeconds(5));
    while (try app.read(owner, Read.pending, .{})) {
        _ = try app.step(0);
        if (std.Io.Clock.awake.now(t.io).compare(.gte, deadline)) return error.FindTimeout;
        try std.Io.sleep(t.io, .fromMilliseconds(1), .awake);
    }
    _ = try app.step(0);
}
fn enterField(app: *ui.App, h: ui.WindowHandle, name: []const u8, value: []const u8) !void {
    const rect = try elementBounds(app, h, name);
    const point: ui.Point = .{ .x = rect.x + 10, .y = rect.y + rect.height / 2 };
    try app.dispatch(h, .{ .pointer_down = .{ .position = point } });
    try app.dispatch(h, .{ .pointer_up = .{ .position = point } });
    try app.dispatch(h, .{ .key_down = .{ .key = .a, .modifiers = .{ .command = true } } });
    try app.dispatch(h, .{ .text = value });
    _ = try app.step(0);
}
fn sceneText(app: *ui.App, h: ui.WindowHandle, value: []const u8) !usize {
    var count: usize = 0;
    for ((try app.window(h)).frames.committed.scene.items) |item| if (item.kind == .text and std.mem.eql(u8, item.text, value)) {
        count += 1;
    };
    return count;
}
test "settings icon picker updates the project and tab immediately and persists the choice" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "sample.py", .data = "def hello():\n    return True\n" });
    const home = try std.fs.path.join(t.allocator, &.{ root, "extensions" });
    defer t.allocator.free(home);
    const path = try std.fs.path.join(t.allocator, &.{ root, "settings.json" });
    defer t.allocator.free(path);
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const shell = try zircon.Shell.init(t.allocator, t.io, root, "sample.py");
    const h = try app.openWindow(zircon.Shell, .{ .visible = false, .width = 1200, .height = 760 }, shell);
    const owner = try app.windowEntity(zircon.Shell, h);
    try app.update(owner, zircon.Shell.loadSettings, .{path});
    try app.update(owner, zircon.Shell.bootstrap, .{h});
    try settle(&app);
    try app.update(owner, Ops.configure, .{home});
    try send(&app, h, .extensions);
    try click(&app, h, "Install Oxide");
    try send(&app, h, .back_to_editor);
    try send(&app, h, .settings);
    const Read = struct {
        fn child(self: *const zircon.Shell) ui.WindowHandle {
            return self.settings_window.?;
        }
    };
    const child = try app.read(owner, Read.child, .{});
    try click(&app, child, "Appearance");
    try click(&app, child, "Zircon icons");
    try click(&app, child, "Oxide symbols");
    try t.expectEqual(@as(usize, 2), try sceneText(&app, h, "Py"));
    if (comptime ui.testing.native != void) try (try app.window(h)).snapshot("/tmp/zircon-icon-theme-switched.png");
    try click(&app, child, "Oxide symbols");
    try click(&app, child, "Zircon icons");
    try t.expectEqual(@as(usize, 0), try sceneText(&app, h, "Py"));
    try click(&app, child, "Zircon icons");
    try click(&app, child, "Oxide symbols");
    try app.closeWindow(child);
    var store = try zircon.SettingsStore.init(t.allocator, t.io, path);
    defer store.deinit();
    try t.expectEqualStrings("oxide-symbols", store.values().icon_theme);
}
test "inline buffer search navigates queued results and applies Unicode regex replacements with undo" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const source = "foo FOO food foo_bar\nid=42 id=7\n日\n";
    try tmp.dir.writeFile(t.io, .{ .sub_path = "sample.zig", .data = source });
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const h = try open(&app, root, "sample.zig");
    const owner = try app.windowEntity(zircon.Shell, h);
    try app.dispatch(h, .{ .key_down = .{ .key = .f, .modifiers = .{ .command = true } } });
    _ = try app.step(0);
    const header = try elementBounds(&app, h, "file-toolbar");
    const bar = try elementBounds(&app, h, "buffer-find");
    try t.expect(bar.y >= header.y + header.height);
    try t.expect((try elementBounds(&app, h, "primary-editor")).y >= bar.y + bar.height);
    try app.dispatch(h, .{ .text = "foo" });
    try app.dispatch(h, .{ .key_down = .{ .key = .enter } });
    try waitBufferFind(&app, h);
    const Read = struct {
        fn count(self: *const zircon.Shell) usize {
            return if (self.find.result) |result| result.value.matches.len else 0;
        }
        fn selected(self: *const zircon.Shell) bool {
            return self.tabs.items[self.active].editor.primary().range().end == 3;
        }
        fn invalid(self: *const zircon.Shell) bool {
            return self.find.error_text.len > 0;
        }
    };
    try t.expectEqual(@as(usize, 4), try app.read(owner, Read.count, .{}));
    try t.expect(try app.read(owner, Read.selected, .{}));
    try click(&app, h, "Match case");
    try waitBufferFind(&app, h);
    try t.expectEqual(@as(usize, 3), try app.read(owner, Read.count, .{}));
    try click(&app, h, "Whole word");
    try waitBufferFind(&app, h);
    try t.expectEqual(@as(usize, 1), try app.read(owner, Read.count, .{}));
    try click(&app, h, "Whole word");
    try click(&app, h, "Regular expression");
    try click(&app, h, "Toggle replace");
    try enterField(&app, h, "buffer-query", "id=(\\d+)");
    try app.dispatch(h, .{ .key_down = .{ .key = .tab } });
    _ = try app.step(0);
    try app.dispatch(h, .{ .text = "値:${1}" });
    try send(&app, h, .replace_all);
    try waitBufferFind(&app, h);
    var actual: []u8 = undefined;
    try app.read(owner, Ops.source, .{ t.allocator, &actual });
    defer t.allocator.free(actual);
    try t.expectEqualStrings("foo FOO food foo_bar\n値:42 値:7\n日\n", actual);
    try send(&app, h, .undo);
    var undone: []u8 = undefined;
    try app.read(owner, Ops.source, .{ t.allocator, &undone });
    defer t.allocator.free(undone);
    try t.expectEqualStrings(source, undone);
    try enterField(&app, h, "buffer-query", "[");
    try waitBufferFind(&app, h);
    try t.expect(try app.read(owner, Read.invalid, .{}));
    try enterField(&app, h, "buffer-query", "日");
    try waitBufferFind(&app, h);
    try t.expect(!try app.read(owner, Read.invalid, .{}));
    try t.expectEqual(@as(usize, 1), try app.read(owner, Read.count, .{}));
    if (comptime ui.testing.native != void) try (try app.window(h)).snapshot("/tmp/zircon-buffer-find.png");
    try click(&app, h, "Close buffer search");
    try t.expectError(error.ElementNotFound, elementBounds(&app, h, "buffer-find"));
    try app.dispatch(h, .{ .key_down = .{ .key = .g, .modifiers = .{ .command = true } } });
    _ = try app.step(0);
    try app.dispatch(h, .{ .text = "日日" });
    _ = try app.step(0);
    try app.dispatch(h, .{ .key_down = .{ .key = .g, .modifiers = .{ .command = true } } });
    try waitBufferFind(&app, h);
    try t.expectEqual(@as(usize, 2), try app.read(owner, Read.count, .{}));
    try t.expectError(error.ElementNotFound, elementBounds(&app, h, "buffer-find"));
    try tmp.dir.writeFile(t.io, .{ .sub_path = "other.zig", .data = "日日日\n" });
    try app.update(owner, Ops.open, .{"other.zig"});
    _ = try app.step(0);
    try app.dispatch(h, .{ .key_down = .{ .key = .g, .modifiers = .{ .command = true } } });
    try waitBufferFind(&app, h);
    try t.expectEqual(@as(usize, 3), try app.read(owner, Read.count, .{}));
    try send(&app, h, .find);
    try waitBufferFind(&app, h);
    try app.update(owner, Ops.open, .{"sample.zig"});
    _ = try app.step(0);
    try waitBufferFind(&app, h);
    try t.expectEqual(@as(usize, 2), try app.read(owner, Read.count, .{}));
}
test "icon tooltips wait then clamp to the window and disappear when the pointer leaves" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "file.zig", .data = "const a = 1;\n" });
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const h = try open(&app, root, "file.zig");
    const frame = &(try app.window(h)).frames.committed;
    var point: ?ui.Point = null;
    for (frame.nodes.items, 0..) |node, i| if (node.kind == .button and std.mem.eql(u8, node.kind.button.label, "Split editor")) {
        point = .{ .x = frame.bounds[i].x + 10, .y = frame.bounds[i].y + 10 };
        break;
    };
    try app.dispatch(h, .{ .pointer_move = .{ .position = point orelse return error.ControlNotFound } });
    _ = try app.step(0.1);
    try t.expectEqual(@as(usize, 0), try sceneText(&app, h, "Split editor"));
    _ = try app.step(0.41);
    try t.expectEqual(@as(usize, 1), try sceneText(&app, h, "Split editor"));
    for ((try app.window(h)).frames.committed.scene.items) |item| if (item.kind == .text and std.mem.eql(u8, item.text, "Split editor")) {
        try t.expect(item.rect.x >= 6 and item.rect.x + item.rect.width <= 1194);
        try t.expect(item.rect.y >= 6 and item.rect.y + item.rect.height <= 754);
    };
    if (comptime ui.testing.native != void) try (try app.window(h)).snapshot("/tmp/zircon-icon-tooltip.png");
    try app.dispatch(h, .pointer_leave);
    _ = try app.step(0.5);
    try t.expectEqual(@as(usize, 0), try sceneText(&app, h, "Split editor"));
}
test "gutter fold clicks hide source rows and buffer search reveals a match inside the fold" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "main.zig", .data = "fn main() {\n    one();\n    two();\n}\nnext();\n" });
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const h = try open(&app, root, "main.zig");
    const owner = try app.windowEntity(zircon.Shell, h);
    const canvas = try elementBounds(&app, h, "primary-editor");
    const point: ui.Point = .{ .x = canvas.x + 58, .y = canvas.y + 11 };
    try app.dispatch(h, .{ .pointer_move = .{ .position = point } });
    _ = try app.step(0);
    if (comptime ui.testing.native != void) try (try app.window(h)).snapshot("/tmp/zircon-gutter-hover.png");
    try app.dispatch(h, .{ .pointer_down = .{ .position = point } });
    try app.dispatch(h, .{ .pointer_up = .{ .position = point } });
    _ = try app.step(0);
    const Read = struct {
        fn folded(self: *const zircon.Shell) bool {
            const state = &self.tabs.items[self.active].editor;
            return state.wrap_cache.folding.collapsed.items.len == 1 and state.wrap_cache.rows.items.len == 3;
        }
        fn revealed(self: *const zircon.Shell) !bool {
            const tab = &self.tabs.items[self.active];
            var s = try self.workspace.snapshot(tab.document);
            defer s.deinit();
            return tab.editor.wrap_cache.folding.collapsed.items.len == 0 and (try s.pointAt(tab.editor.primary().head)).line == 2;
        }
    };
    try t.expect(try app.read(owner, Read.folded, .{}));
    if (comptime ui.testing.native != void) try (try app.window(h)).snapshot("/tmp/zircon-gutter-folded.png");
    try send(&app, h, .find);
    try app.dispatch(h, .{ .text = "two" });
    try app.dispatch(h, .{ .key_down = .{ .key = .enter } });
    try waitBufferFind(&app, h);
    try t.expect(try app.read(owner, Read.revealed, .{}));
}
test "light buffer search stays inside a native narrow window with bordered inputs" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "main.zig", .data = "fn main() {\n    const value = 42;\n}\n" });
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const shell = try zircon.Shell.init(t.allocator, t.io, root, "main.zig");
    const h = try app.openWindow(zircon.Shell, .{ .visible = false, .width = 760, .height = 500 }, shell);
    const owner = try app.windowEntity(zircon.Shell, h);
    try app.update(owner, zircon.Shell.bootstrap, .{h});
    const Call = struct {
        fn light(self: *zircon.Shell, cx: *ui.Context(zircon.Shell)) !void {
            try cx.update(self.settings.?, zircon.Settings.apply, .{zircon.SettingsPatch{ .theme = "zircon.light" }});
        }
    };
    try app.update(owner, Call.light, .{});
    _ = try app.step(0);
    try send(&app, h, .replace);
    try app.dispatch(h, .{ .text = "value" });
    try waitBufferFind(&app, h);
    const bar = try elementBounds(&app, h, "buffer-find");
    const query = try elementBounds(&app, h, "buffer-query");
    try t.expect(bar.x >= 250 and bar.x + bar.width <= 760);
    try t.expect(query.width >= 60 and query.x + query.width <= 760);
    var border = false;
    for ((try app.window(h)).frames.committed.scene.items) |item| if (item.kind == .rect and @abs(item.rect.x - query.x) < 0.1 and @abs(item.rect.width - query.width) < 0.1 and item.color.b > item.color.r) {
        border = true;
    };
    try t.expect(border);
    if (comptime ui.testing.native != void) try (try app.window(h)).snapshot("/tmp/zircon-buffer-find-light-narrow.png");
}
