const std = @import("std");
const zircon = @import("zircon");
const ui = @import("zircon_ui");
const t = std.testing;

const Ops = struct {
    fn seed(self: *zircon.Shell, cx: *ui.Context(zircon.Shell)) !void {
        for ([_][]const u8{ "main.zig", "other.zig" }, 0..) |path, file| {
            const id = try self.workspace.open(path);
            const record = try self.workspace.getConst(id);
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            const a = arena.allocator();
            const items = try a.alloc(zircon.language.Diagnostic, 300);
            for (items, 0..) |*item, index| item.* = .{
                .range = .{ .start = .{ .line = 0, .character = 1 }, .end = .{ .line = 0, .character = 2 } },
                .message = try std.fmt.allocPrint(a, "Issue {d}/{d}", .{ file, index }),
                .severity = if (index % 2 == 0) .error_value else .warning,
                .source = "fixture",
            };
            const uri = try zircon.language.fileUri(self.allocator, record.path.?);
            try self.language.documents.append(self.allocator, .{
                .id = id,
                .uri = uri,
                .path = try self.allocator.dupe(u8, record.path.?),
                .session = 0,
                .version = 0,
                .diagnostics = .{ .arena = arena, .data = .{ .diagnostics = .{ .uri = uri, .version = 0, .items = items } } },
            });
        }
        self.language.diagnostics_generation += 1;
        cx.notify();
    }
    fn overlappingIssues(self: *zircon.Shell, cx: *ui.Context(zircon.Shell)) !void {
        const tab = self.tabs.items[self.active];
        const record = try self.workspace.getConst(tab.document);
        var snapshot = record.doc.snapshot();
        defer snapshot.deinit();
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        const a = arena.allocator();
        const items = try a.alloc(zircon.language.Diagnostic, 2);
        items[0] = .{
            .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 5 } },
            .message = "broken name",
            .severity = .error_value,
            .source = "fixture",
        };
        items[1] = .{
            .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 2 } },
            .message = "narrower issue",
            .severity = .warning,
            .source = "fixture",
        };
        const uri = try zircon.language.fileUri(self.allocator, record.path.?);
        try self.language.documents.append(self.allocator, .{
            .id = tab.document,
            .uri = uri,
            .path = try self.allocator.dupe(u8, record.path.?),
            .session = 0,
            .version = snapshot.revision(),
            .diagnostics = .{ .arena = arena, .data = .{ .diagnostics = .{ .uri = uri, .version = snapshot.revision(), .items = items } } },
        });
        self.language.diagnostics_generation += 1;
        cx.notify();
    }
    fn republish(self: *zircon.Shell, cx: *ui.Context(zircon.Shell)) !void {
        const message = &self.language.documents.items[0].diagnostics.?;
        const items = try message.arena.allocator().dupe(zircon.language.Diagnostic, message.data.diagnostics.items);
        items[0].message = "updated diagnostic";
        message.data.diagnostics.items = items;
        self.language.diagnostics_generation += 1;
        cx.notify();
    }
    fn command(self: *zircon.Shell, cx: *ui.Context(zircon.Shell), which: zircon.Command) !void {
        var event: ui.Event(ui.Click) = .{ .data = .{} };
        try self.onCommand(&event, cx, which);
    }
    fn selectedOther(self: *const zircon.Shell) !void {
        try t.expectEqual(.editor, self.panel);
        const tab = self.tabs.items[self.active];
        const record = try self.workspace.getConst(tab.document);
        try t.expectEqualStrings("other.zig", std.fs.path.basename(record.path.?));
        try t.expectEqual(@as(usize, 1), tab.editor.primary().anchor);
        try t.expectEqual(@as(usize, 2), tab.editor.primary().head);
        try t.expect(self.tool_tabs.diagnostics);
    }
    fn stale(self: *zircon.Shell, cx: *ui.Context(zircon.Shell)) !void {
        const record = try self.workspace.get(self.language.documents.items[0].id);
        var change = try record.doc.apply(0, &.{.{ .range = .{ .start = 0, .end = 0 }, .text = "typed " }}, 0);
        change.deinit();
        self.showTool(.diagnostics);
        cx.notify();
    }
};
fn bounds(app: *ui.App, h: ui.WindowHandle, key: []const u8) !ui.Rect {
    const frame = &(try app.window(h)).frames.committed;
    for (frame.nodes.items, 0..) |node, index| if (node.key) |value| if (value == .string and std.mem.eql(u8, value.string, key)) return frame.bounds[index];
    return error.MissingElement;
}
fn click(app: *ui.App, h: ui.WindowHandle, label: []const u8) !void {
    const frame = &(try app.window(h)).frames.committed;
    var found: ?ui.Rect = null;
    for (frame.nodes.items, 0..) |node, index| {
        if (node.kind == .button and std.mem.eql(u8, node.kind.button.label, label)) found = frame.bounds[index];
    }
    const rect = found orelse return error.MissingButton;
    const point: ui.Point = .{ .x = rect.x + rect.width / 2, .y = rect.y + rect.height / 2 };
    try app.dispatch(h, .{ .pointer_down = .{ .position = point } });
    try app.dispatch(h, .{ .pointer_up = .{ .position = point } });
    _ = try app.step(0);
}

test "editor squiggles and diagnostic hover use the stored issue" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "main.zig", .data = "alpha\n" });
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const h = try app.openWindow(zircon.Shell, .{ .visible = false, .width = 1100, .height = 760 }, try zircon.Shell.init(t.allocator, t.io, root, "main.zig"));
    const owner = try app.windowEntity(zircon.Shell, h);
    try app.update(owner, zircon.Shell.bootstrap, .{h});
    try app.update(owner, Ops.overlappingIssues, .{});
    try app.update(owner, zircon.Shell.pollLanguage, .{});
    _ = try app.step(0);
    const tint = try app.read(owner, struct {
        fn deleted(self: *const zircon.Shell) ui.Color {
            return self.tabs.items[self.active].editor.theme.git_deleted;
        }
    }.deleted, .{});
    var waves: usize = 0;
    for ((try app.window(h)).frames.committed.scene.items) |item| if (item.kind == .rect and std.meta.eql(item.color, tint) and item.rect.height <= 2 and item.rect.width <= 4) {
        waves += 1;
    };
    try t.expect(waves >= 4);
    const editor_bounds = try bounds(&app, h, "primary-editor");
    const metrics = (try app.window(h)).surface.?.measurer();
    const at: ui.Point = .{ .x = editor_bounds.x + 76 + metrics.caret("alpha", .{ .size = 14, .mono = true }, 3), .y = editor_bounds.y + 11 };
    try app.dispatch(h, .{ .pointer_move = .{ .position = at } });
    _ = try app.step(0);
    var message = false;
    for ((try app.window(h)).frames.committed.scene.items) |item| if (item.kind == .text and std.mem.indexOf(u8, item.text, "broken name") != null) {
        message = true;
    };
    try t.expect(message);
    try app.update(owner, Ops.republish, .{});
    try app.update(owner, zircon.Shell.pollLanguage, .{});
    _ = try app.step(0);
    const note = try app.read(owner, struct {
        fn refreshed(self: *const zircon.Shell) bool {
            const note = self.symbol_hover.note orelse return false;
            return std.mem.eql(u8, note.message, "updated diagnostic");
        }
    }.refreshed, .{});
    try t.expect(note);
    try t.expect((try bounds(&app, h, "symbol-hover")).height >= 40);
}

test "diagnostics tab virtualizes issues filters severity and opens another source" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "main.zig", .data = "abc\n" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "other.zig", .data = "abc\n" });
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const h = try app.openWindow(zircon.Shell, .{ .visible = false, .width = 1100, .height = 760 }, try zircon.Shell.init(t.allocator, t.io, root, "main.zig"));
    const owner = try app.windowEntity(zircon.Shell, h);
    try app.update(owner, Ops.seed, .{});
    _ = try app.step(0);
    try t.expect((try bounds(&app, h, "primary-editor")).height > 500);
    try app.update(owner, Ops.command, .{.language_servers});
    _ = try app.step(0);
    for ((try app.window(h)).frames.committed.scene.items) |item| if (item.kind == .text) {
        try t.expect(!std.mem.startsWith(u8, item.text, "Issue "));
    };
    try app.dispatch(h, .{ .key_down = .{ .key = .escape } });
    _ = try app.step(0);
    try click(&app, h, "Diagnostics");
    _ = try app.step(0);
    if (comptime ui.testing.native != void) try (try app.window(h)).snapshot("/tmp/zircon-diagnostics-excerpts.png");
    var source_visible = false;
    for ((try app.window(h)).frames.committed.scene.items) |item| if (item.kind == .text and std.mem.eql(u8, item.text, "abc")) {
        source_visible = true;
    };
    try t.expect(source_visible);
    var visible: usize = 0;
    for ((try app.window(h)).frames.committed.nodes.items) |node| if (node.kind == .button and std.mem.startsWith(u8, node.kind.button.label, "Issue ")) {
        visible += 1;
    };
    try t.expect(visible > 0 and visible < 30);
    try click(&app, h, "Warnings (300)");
    const list = try bounds(&app, h, "diagnostics-list");
    try app.dispatch(h, .{ .scroll = .{ .position = .{ .x = list.x + 20, .y = list.y + 20 }, .x = 0, .y = -100000 } });
    _ = try app.step(0);
    try click(&app, h, "Issue 1/299");
    try app.read(owner, Ops.selectedOther, .{});
    try app.update(owner, Ops.stale, .{});
    _ = try app.step(0);
    try click(&app, h, "All issues (300)");
    try t.expect((try bounds(&app, h, "diagnostics-panel")).height > 500);
}
