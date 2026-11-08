const std = @import("std");
const zircon = @import("zircon");
const ui = @import("zircon_ui");
const t = std.testing;
const lsp = zircon.language;

const Scenario = enum { valid, stale_source, stale_target, invalid_target };

const Ops = struct {
    fn seedAction(self: *zircon.Shell, _: *ui.Context(zircon.Shell), scenario: Scenario) !void {
        const tab = &self.tabs.items[self.active];
        const record = try self.workspace.get(tab.document);
        var arena = std.heap.ArenaAllocator.init(t.allocator);
        const a = arena.allocator();
        const files = try a.alloc(lsp.FileEdits, 2);
        const edits = try a.alloc(lsp.TextEdit, 1);
        edits[0] = .{ .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 3 } }, .new_text = "fixed" };
        files[0] = .{ .uri = try lsp.fileUri(a, record.path.?), .edits = edits };
        const other_path = try std.fs.path.join(a, &.{ self.workspace.root_path, "other.zig" });
        const other_edits = try a.dupe(lsp.TextEdit, edits);
        if (scenario == .invalid_target) other_edits[0].range.end.character = 99;
        files[1] = .{ .uri = try lsp.fileUri(a, other_path), .edits = other_edits };
        const items = try a.alloc(lsp.CodeAction, 1);
        items[0] = .{ .title = "Fix answer", .files = files };
        self.language.code_actions = .{ .arena = arena, .data = .{ .code_actions = .{ .id = 1, .uri = files[0].uri, .version = record.doc.revision(), .items = items } } };
        self.language.code_actions_pending = .{ .document = tab.document, .session = 0, .request = 1, .revision = record.doc.revision() };
        try self.language.code_actions_pending.?.capture(&self.workspace, t.allocator);
        if (scenario == .stale_source) {
            var change = try record.doc.apply(record.doc.revision(), &.{.{ .range = .{ .start = 0, .end = 0 }, .text = "typed " }}, 0);
            change.deinit();
        }
        if (scenario == .stale_target) {
            try self.openPath("other.zig");
            const other = try self.workspace.get(self.tabs.items[self.active].document);
            var change = try other.doc.apply(other.doc.revision(), &.{.{ .range = .{ .start = 0, .end = 0 }, .text = "typed " }}, 0);
            change.deinit();
            self.active = 0;
        }
    }
    fn applyAction(self: *zircon.Shell, cx: *ui.Context(zircon.Shell)) !void {
        var event: ui.Event(ui.Click) = .{ .data = .{} };
        try self.onCodeAction(&event, cx, 0);
    }
    fn verifyAction(self: *const zircon.Shell, scenario: Scenario) !void {
        const valid = scenario == .valid;
        try t.expectEqual(!valid, self.status_is_error);
        const source_record = try self.workspace.getConst(self.tabs.items[0].document);
        try t.expectEqual(valid or scenario == .stale_source, source_record.dirty());
        if (valid) {
            try t.expectEqual(@as(usize, 2), self.tabs.items.len);
            try t.expect(try self.workspace.dirty(self.tabs.items[1].document));
            try t.expectEqual(@as(usize, 2), self.document_changes.len);
        }
    }
    fn source(self: *const zircon.Shell, expected: []const u8) !void {
        var snapshot = try self.workspace.snapshot(self.tabs.items[self.active].document);
        defer snapshot.deinit();
        const bytes = try snapshot.copy(t.allocator, .{ .start = 0, .end = snapshot.byteLen() });
        defer t.allocator.free(bytes);
        try t.expectEqualStrings(expected, bytes);
    }
};

fn runAction(scenario: Scenario) !void {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "main.zig", .data = "old\n" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "other.zig", .data = "old\n" });
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const h = try app.openWindow(zircon.Shell, .{ .visible = false, .width = 1100, .height = 760 }, try zircon.Shell.init(t.allocator, t.io, root, "main.zig"));
    const owner = try app.windowEntity(zircon.Shell, h);
    try app.update(owner, Ops.seedAction, .{scenario});
    try app.update(owner, Ops.applyAction, .{});
    const expected = switch (scenario) {
        .valid => "fixed\n",
        .stale_source => "typed old\n",
        else => "old\n",
    };
    try app.read(owner, Ops.source, .{expected});
    try app.read(owner, Ops.verifyAction, .{scenario});
    const disk = try tmp.dir.readFileAlloc(t.io, "main.zig", t.allocator, .limited(128));
    defer t.allocator.free(disk);
    try t.expectEqualStrings("old\n", disk);
}

test "language action refuses a stale source without editing it" {
    try runAction(.stale_source);
}
test "language action refuses edits after another target was changed" {
    try runAction(.stale_target);
}
test "language action validates the last target before editing the first" {
    try runAction(.invalid_target);
}
test "language action opens normal dirty tabs without writing disk" {
    try runAction(.valid);
}

const ServerOps = struct {
    fn configure(self: *zircon.Shell, cx: *ui.Context(zircon.Shell), home: []const u8) !void {
        try self.loadExtensions(cx, home);
    }
    fn ready(self: *const zircon.Shell) bool {
        if (self.language.documents.items.len != 1) return false;
        const doc = self.language.documents.items[0];
        return doc.version != null and self.language.sessions.items[doc.session].client.?.ready();
    }
    fn resultsTool(self: *const zircon.Shell) !void {
        try t.expectEqual(.language_results, self.currentTool(0).?);
        try t.expect(self.tool_tabs.language_results);
    }
    fn searchTool(self: *const zircon.Shell) !void {
        try t.expectEqual(.search, self.currentTool(0).?);
        try t.expect(self.language.code_actions != null);
        try t.expect(self.tool_tabs.language_results and self.tool_tabs.search);
    }
    fn actionReady(self: *const zircon.Shell) bool {
        return self.language.code_actions != null;
    }
    fn command(self: *zircon.Shell, cx: *ui.Context(zircon.Shell), command_value: zircon.Command) !void {
        var event: ui.Event(ui.Click) = .{ .data = .{} };
        try self.onCommand(&event, cx, command_value);
    }
    fn identity(self: *const zircon.Shell) usize {
        return @intFromPtr(self.language.sessions.items[0].client.?);
    }
    fn signatureReady(self: *const zircon.Shell) bool {
        return self.language.signature != null;
    }
};

fn waitFor(app: *ui.App, owner: ui.Entity(zircon.Shell), comptime predicate: anytype) !void {
    const deadline = std.Io.Clock.awake.now(t.io).addDuration(.fromSeconds(5));
    while (!try app.read(owner, predicate, .{})) {
        _ = try app.step(0);
        if (std.Io.Clock.awake.now(t.io).compare(.gte, deadline)) return error.LanguageActionTimeout;
        try std.Io.sleep(t.io, .fromMilliseconds(1), .awake);
    }
}

test "language action survives the full response path and keeps its server alive" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "main.zig", .data = "old\n" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "server.py", .data = @embedFile("language_fixture") });
    try tmp.dir.createDirPath(t.io, "extensions/org.zircon.actions");
    const server = try std.fs.path.join(t.allocator, &.{ root, "server.py" });
    defer t.allocator.free(server);
    const home = try std.fs.path.join(t.allocator, &.{ root, "extensions" });
    defer t.allocator.free(home);
    const manifest = try std.json.Stringify.valueAlloc(t.allocator, .{ .schema_version = 1, .id = "org.zircon.actions", .name = "Actions", .version = "1.0.0", .contributes = .{ .language_servers = .{.{ .id = "actions", .languages = .{"zig"}, .command = "python3", .args = .{ server, "host" } }} } }, .{});
    defer t.allocator.free(manifest);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "extensions/org.zircon.actions/extension.json", .data = manifest });
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const h = try app.openWindow(zircon.Shell, .{ .visible = false, .width = 1100, .height = 760 }, try zircon.Shell.init(t.allocator, t.io, root, "main.zig"));
    const owner = try app.windowEntity(zircon.Shell, h);
    try app.update(owner, zircon.Shell.bootstrap, .{h});
    try app.update(owner, ServerOps.configure, .{home});
    try waitFor(&app, owner, ServerOps.ready);
    const identity = try app.read(owner, ServerOps.identity, .{});
    try app.update(owner, ServerOps.command, .{.code_actions});
    try waitFor(&app, owner, ServerOps.actionReady);
    try app.read(owner, ServerOps.resultsTool, .{});
    try app.update(owner, ServerOps.command, .{.project_search});
    try app.read(owner, ServerOps.searchTool, .{});
    _ = try app.step(0);
    var query_visible = false;
    for ((try app.window(h)).frames.committed.nodes.items) |node| if (node.key) |key| if (key == .string and std.mem.eql(u8, key.string, "project-query")) {
        query_visible = true;
    };
    try t.expect(query_visible);
    try app.update(owner, Ops.applyAction, .{});
    try app.read(owner, Ops.source, .{"fixedld\n"});
    try t.expectEqual(identity, try app.read(owner, ServerOps.identity, .{}));
    try app.update(owner, ServerOps.command, .{.show_signature_help});
    try waitFor(&app, owner, ServerOps.signatureReady);
    try t.expectEqual(identity, try app.read(owner, ServerOps.identity, .{}));
    try app.update(owner, ServerOps.command, .{.save});
    const saved = try tmp.dir.readFileAlloc(t.io, "main.zig", t.allocator, .limited(128));
    defer t.allocator.free(saved);
    try t.expectEqualStrings("fixedld\n", saved);
}
