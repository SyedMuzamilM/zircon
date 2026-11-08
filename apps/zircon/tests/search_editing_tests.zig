const std = @import("std");
const zircon = @import("zircon");
const ui = @import("zircon_ui");
const t = std.testing;
const Ops = struct {
    fn command(self: *zircon.Shell, cx: *ui.Context(zircon.Shell), which: zircon.Command) !void {
        var event: ui.Event(ui.Click) = .{ .data = .{} };
        try self.onCommand(&event, cx, which);
    }
    fn query(self: *zircon.Shell, cx: *ui.Context(zircon.Shell)) !void {
        const Set = struct {
            fn call(input: *ui.controls.TextInput, context: *ui.Context(ui.controls.TextInput)) !void {
                try input.bytes.appendSlice(input.allocator, "needle");
                input.cursor = input.bytes.items.len;
                input.anchor = input.cursor;
                input.revision += 1;
                context.notify();
            }
        };
        try cx.update(self.fields.?.project_search.query, Set.call, .{});
        try command(self, cx, .run_project_search);
    }
    fn clear(self: *zircon.Shell, cx: *ui.Context(zircon.Shell)) !void {
        const Set = struct {
            fn call(input: *ui.controls.TextInput, context: *ui.Context(ui.controls.TextInput)) void {
                input.bytes.clearRetainingCapacity();
                input.cursor = 0;
                input.anchor = 0;
                input.revision += 1;
                context.notify();
            }
        };
        try cx.update(self.fields.?.project_search.query, Set.call, .{});
        try command(self, cx, .run_project_search);
    }
    fn loaded(self: *const zircon.Shell, expected: usize) !void {
        var total: usize = 0;
        for (self.workspace.slots.items) |slot| if (slot.record != null) {
            total += 1;
        };
        try t.expectEqual(expected, total);
    }
    fn results(self: *const zircon.Shell) !void {
        try t.expectEqual(.search, self.currentTool(0).?);
        try t.expectEqual(@as(usize, 2), self.search.results.?.groups.len);
    }
    fn saveConflict(self: *const zircon.Shell) !void {
        try t.expect(self.status_is_error);
        try t.expect(std.mem.indexOf(u8, self.status, "changed on disk") != null);
    }
    fn source(self: *const zircon.Shell, name: []const u8, expected: []const u8) !void {
        for (self.workspace.slots.items) |slot| if (slot.record) |record| {
            if (record.path == null or !std.mem.eql(u8, std.fs.path.basename(record.path.?), name)) continue;
            var snapshot = record.doc.snapshot();
            defer snapshot.deinit();
            const bytes = try snapshot.copy(t.allocator, .{ .start = 0, .end = snapshot.byteLen() });
            defer t.allocator.free(bytes);
            try t.expectEqualStrings(expected, bytes);
            return;
        };
        return error.SourceMissing;
    }
};
fn settle(app: *ui.App) !void {
    const deadline = std.Io.Clock.awake.now(t.io).addDuration(.fromSeconds(5));
    while (try app.tasksPending()) {
        _ = try app.step(0);
        if (std.Io.Clock.awake.now(t.io).compare(.gte, deadline)) return error.SearchTimeout;
        try std.Io.sleep(t.io, .fromMilliseconds(1), .awake);
    }
    _ = try app.step(0);
}
fn excerptBounds(app: *ui.App, handle: ui.WindowHandle, name: []const u8) !ui.Rect {
    const frame = &(try app.window(handle)).frames.committed;
    for (frame.nodes.items, 0..) |node, index| if (node.key) |key| if (key == .string and std.mem.eql(u8, key.string, name)) return frame.bounds[index];
    return error.EditableSearchExcerptMissing;
}

test "project search excerpts edit real files in place and save their buffers" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "one.zig", .data = "needle one\n" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "two.zig", .data = "needle two\n" });
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const handle = try app.openWindow(zircon.Shell, .{ .visible = false, .width = 1100, .height = 760 }, try zircon.Shell.init(t.allocator, t.io, root, "one.zig"));
    const owner = try app.windowEntity(zircon.Shell, handle);
    try app.update(owner, zircon.Shell.bootstrap, .{handle});
    try settle(&app);
    try app.update(owner, Ops.command, .{.project_search});
    try app.update(owner, Ops.query, .{});
    try settle(&app);
    try app.read(owner, Ops.results, .{});
    try app.read(owner, Ops.loaded, .{@as(usize, 2)});
    try app.update(owner, Ops.clear, .{});
    try settle(&app);
    try app.read(owner, Ops.loaded, .{@as(usize, 1)});
    try app.update(owner, Ops.query, .{});
    try settle(&app);
    const excerpt = try excerptBounds(&app, handle, "search-excerpt:0:0:0");
    const position: ui.Point = .{ .x = excerpt.x + 76, .y = excerpt.y + 10 };
    try app.dispatch(handle, .{ .pointer_down = .{ .position = position } });
    try app.dispatch(handle, .{ .pointer_up = .{ .position = position } });
    _ = try app.step(0);
    try app.dispatch(handle, .{ .text = "edited " });
    _ = try app.step(0);
    try app.read(owner, Ops.source, .{ "one.zig", "edited needle one\n" });
    try app.read(owner, Ops.results, .{});
    const disk = try tmp.dir.readFileAlloc(t.io, "one.zig", t.allocator, .limited(128));
    defer t.allocator.free(disk);
    try t.expectEqualStrings("needle one\n", disk);
    try app.dispatch(handle, .{ .key_down = .{ .key = .s, .modifiers = .{ .command = true } } });
    try settle(&app);
    const saved = try tmp.dir.readFileAlloc(t.io, "one.zig", t.allocator, .limited(128));
    defer t.allocator.free(saved);
    try t.expectEqualStrings("edited needle one\n", saved);
    try app.update(owner, Ops.command, .{.undo});
    _ = try app.step(0);
    try app.read(owner, Ops.source, .{ "one.zig", "needle one\n" });
    try app.update(owner, Ops.command, .{.redo});
    _ = try app.step(0);
    try app.read(owner, Ops.source, .{ "one.zig", "edited needle one\n" });
    const second = try excerptBounds(&app, handle, "search-excerpt:0:1:0");
    try app.dispatch(handle, .{ .key_down = .{ .key = .down, .modifiers = .{ .command = true } } });
    try app.dispatch(handle, .{ .key_down = .{ .key = .down } });
    _ = try app.step(0);
    try app.dispatch(handle, .{ .text = "new line\n" });
    _ = try app.step(0);
    try app.read(owner, Ops.source, .{ "two.zig", "new line\nneedle two\n" });
    try app.read(owner, Ops.results, .{});
    const expanded = try excerptBounds(&app, handle, "search-excerpt:0:1:0");
    try t.expect(expanded.height > second.height);
    try app.dispatch(handle, .{ .key_down = .{ .key = .s, .modifiers = .{ .command = true } } });
    try settle(&app);
    const other_saved = try tmp.dir.readFileAlloc(t.io, "two.zig", t.allocator, .limited(128));
    defer t.allocator.free(other_saved);
    try t.expectEqualStrings("new line\nneedle two\n", other_saved);
    if (comptime ui.testing.native != void) try (try app.window(handle)).snapshot("/tmp/zircon-editable-project-search.png");
    try app.dispatch(handle, .{ .text = "unsaved " });
    _ = try app.step(0);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "two.zig", .data = "external content\n" });
    try app.dispatch(handle, .{ .key_down = .{ .key = .s, .modifiers = .{ .command = true } } });
    try settle(&app);
    try app.read(owner, Ops.saveConflict, .{});
    const external = try tmp.dir.readFileAlloc(t.io, "two.zig", t.allocator, .limited(128));
    defer t.allocator.free(external);
    try t.expectEqualStrings("external content\n", external);
}

const ExcerptOps = struct {
    fn search(self: *zircon.Shell, cx: *ui.Context(zircon.Shell)) void {
        self.showTool(.search);
        cx.notify();
    }
    fn sourceEdit(self: *zircon.Shell, cx: *ui.Context(zircon.Shell)) !void {
        self.panel = .editor;
        self.active_pane = .primary;
        var event: ui.Event(ui.Click) = .{ .data = .{} };
        try self.onCommand(&event, cx, .back_to_editor);
    }
    fn count(self: *const zircon.Shell) !void {
        try t.expectEqual(@as(usize, 2), self.search.results.?.groups[0].excerpts.len);
    }
    fn origin(self: *const zircon.Shell) !void {
        try t.expect(self.search.editing.panes[1].active != null);
        try t.expectEqual(.secondary, self.active_pane);
    }
};
fn clickExcerpt(app: *ui.App, handle: ui.WindowHandle, name: []const u8) !void {
    const rect = try excerptBounds(app, handle, name);
    const position: ui.Point = .{ .x = rect.x + 76, .y = rect.y + 10 };
    try app.dispatch(handle, .{ .pointer_down = .{ .position = position } });
    try app.dispatch(handle, .{ .pointer_up = .{ .position = position } });
    _ = try app.step(0);
}

test "project search remaps separated excerpts after source edits and preserves split source identity" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const source = "needle first\n1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\nneedle last\n17\n";
    try tmp.dir.writeFile(t.io, .{ .sub_path = "one.zig", .data = source });
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const handle = try app.openWindow(zircon.Shell, .{ .visible = false, .width = 1200, .height = 850 }, try zircon.Shell.init(t.allocator, t.io, root, "one.zig"));
    const owner = try app.windowEntity(zircon.Shell, handle);
    try app.update(owner, zircon.Shell.bootstrap, .{handle});
    try settle(&app);
    try app.update(owner, Ops.command, .{.project_search});
    try app.update(owner, Ops.query, .{});
    try settle(&app);
    try app.read(owner, ExcerptOps.count, .{});
    try clickExcerpt(&app, handle, "search-excerpt:0:0:0");
    try app.dispatch(handle, .{ .text = "prefix\n" });
    _ = try app.step(0);
    try clickExcerpt(&app, handle, "search-excerpt:0:0:1");
    try app.dispatch(handle, .{ .text = "second " });
    _ = try app.step(0);
    const expected = "prefix\nneedle first\n1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\nsecond 14\n15\nneedle last\n17\n";
    try app.read(owner, Ops.source, .{ "one.zig", expected });
    try app.update(owner, Ops.command, .{.undo});
    _ = try app.step(0);
    const once = "prefix\nneedle first\n1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\nneedle last\n17\n";
    try app.read(owner, Ops.source, .{ "one.zig", once });
    try app.update(owner, ExcerptOps.sourceEdit, .{});
    _ = try app.step(0);
    try app.dispatch(handle, .{ .key_down = .{ .key = .up, .modifiers = .{ .command = true } } });
    try app.dispatch(handle, .{ .text = "from tab\n" });
    try app.update(owner, ExcerptOps.search, .{});
    _ = try app.step(0);
    _ = try excerptBounds(&app, handle, "search-excerpt:0:0:0");
    try app.update(owner, Ops.command, .{.split_right});
    try app.update(owner, ExcerptOps.search, .{});
    _ = try app.step(0);
    try clickExcerpt(&app, handle, "search-excerpt:1:0:0");
    try app.dispatch(handle, .{ .text = "split " });
    _ = try app.step(0);
    try app.read(owner, ExcerptOps.origin, .{});
    try app.dispatch(handle, .{ .key_down = .{ .key = .s, .modifiers = .{ .command = true } } });
    try settle(&app);
    const saved = try tmp.dir.readFileAlloc(t.io, "one.zig", t.allocator, .limited(512));
    defer t.allocator.free(saved);
    try t.expect(std.mem.startsWith(u8, saved, "split from tab\nprefix\nneedle first\n"));
}
