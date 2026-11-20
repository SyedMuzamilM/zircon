const std = @import("std");
const builtin = @import("builtin");
const zircon = @import("zircon");
const ui = @import("zircon_ui");
const lsp = zircon.language;
const t = std.testing;

const Identity = struct { client: usize, diagnostics: usize, generation: u64 };
const Ops = struct {
    fn seedCompletion(self: *zircon.Shell, cx: *ui.Context(zircon.Shell), additional: bool) !void {
        const tab = &self.tabs.items[self.active];
        var snapshot = try self.workspace.snapshot(tab.document);
        defer snapshot.deinit();
        const cursor = snapshot.byteLen();
        try tab.editor.setSelection(snapshot, .{ .start = cursor, .end = cursor });
        var arena = std.heap.ArenaAllocator.init(t.allocator);
        const a = arena.allocator();
        const items = try a.alloc(lsp.Completion, 1);
        items[0] = .{ .label = "print", .insert_text = "print" };
        if (additional) {
            const extra = try a.alloc(lsp.TextEdit, 1);
            extra[0] = .{ .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 0 } }, .new_text = "const std = @import(\"std\");\n" };
            items[0].text_edit = .{ .range = .{ .start = .{ .line = 0, .character = 10 }, .end = .{ .line = 0, .character = 13 } }, .new_text = "print" };
            items[0].additional_edits = extra;
        }
        self.language.pending = .{ .document = tab.document, .session = 0, .request = 1, .revision = snapshot.revision(), .cursor = cursor };
        self.language.completions = .{ .arena = arena, .data = .{ .completion = .{ .id = 1, .uri = "file:///main.zig", .version = snapshot.revision(), .items = items } } };
        var event: ui.Event(ui.Click) = .{ .data = .{} };
        try self.onCompletion(&event, cx, 0);
    }
    fn source(self: *const zircon.Shell, a: std.mem.Allocator, out: *[]u8) !void {
        var snapshot = try self.workspace.snapshot(self.tabs.items[self.active].document);
        defer snapshot.deinit();
        out.* = try snapshot.copy(a, .{ .start = 0, .end = snapshot.byteLen() });
    }
    fn selectionCount(self: *const zircon.Shell) usize {
        return self.tabs.items[self.active].editor.selections.items.items.len;
    }
    fn typingPosition(self: *zircon.Shell, cx: *ui.Context(zircon.Shell)) !void {
        const tab = &self.tabs.items[self.active];
        var snapshot = try self.workspace.snapshot(tab.document);
        defer snapshot.deinit();
        try tab.editor.setSelection(snapshot, .{ .start = 0, .end = 0 });
        cx.notify();
    }
    fn projectIssue(self: *const zircon.Shell) bool {
        for (self.language.documents.items) |doc| if (doc.diagnostics) |message| {
            for (message.data.diagnostics.items) |issue| if (std.mem.eql(u8, issue.message, "project issue")) return doc.version == null;
        };
        return false;
    }
    fn bothReady(self: *const zircon.Shell) bool {
        if (self.language.documents.items.len != 2) return false;
        for (self.language.documents.items) |doc| if (doc.version == null) return false;
        return true;
    }
    fn filtered(self: *const zircon.Shell) !void {
        const items = self.language.completions.?.data.completion.items;
        try t.expectEqual(@as(usize, 2), items.len);
        try t.expectEqualStrings("aaaAnswer", items[0].label);
    }
    fn completionVisible(self: *const zircon.Shell) bool {
        const pending_value = self.language.pending orelse return false;
        return self.language.completions != null and std.meta.eql(pending_value.document, self.tabs.items[self.active].document);
    }
    fn plantCompletion(self: *zircon.Shell, cx: *ui.Context(zircon.Shell)) !void {
        const tab = &self.tabs.items[self.active];
        var snapshot = try self.workspace.snapshot(tab.document);
        defer snapshot.deinit();
        const cursor = snapshot.byteLen();
        try tab.editor.setSelection(snapshot, .{ .start = cursor, .end = cursor });
        var arena = std.heap.ArenaAllocator.init(t.allocator);
        const a = arena.allocator();
        const items = try a.alloc(lsp.Completion, 2);
        items[0] = .{ .label = "alpha", .insert_text = "alpha" };
        items[1] = .{ .label = "beta", .insert_text = "beta", .detail = "fn () void" };
        self.language.pending = .{ .document = tab.document, .session = 0, .request = 1, .revision = snapshot.revision(), .cursor = cursor };
        self.language.completions = .{ .arena = arena, .data = .{ .completion = .{ .id = 1, .uri = "file:///main.zig", .version = snapshot.revision(), .items = items } } };
        self.language.completion_index = 1;
        cx.notify();
    }
    fn completionClosed(self: *const zircon.Shell) bool {
        return self.language.completions == null and self.language.pending == null;
    }
    fn completionCurrent(self: *const zircon.Shell) bool {
        const request = self.language.pending orelse return false;
        const displayed = self.language.completions orelse return false;
        return displayed.data.completion.id == request.request and displayed.data.completion.version == request.revision;
    }
    fn serverStopped(self: *const zircon.Shell) bool {
        return self.status_is_error and std.mem.indexOf(u8, self.status, " stopped.") != null;
    }
    fn definitionOther(self: *const zircon.Shell) !void {
        const record = try self.workspace.getConst(self.tabs.items[self.active].document);
        try t.expectEqualStrings("two.zig", std.fs.path.basename(record.path.?));
    }
    fn definitionSelected(self: *const zircon.Shell) bool {
        return self.language.definition_pending == null and self.tabs.items[self.active].editor.primary().head == 1;
    }
    fn hoverReady(self: *const zircon.Shell) bool {
        return self.language.documents.items.len > 0 and self.language.documents.items[0].version != null and self.language.sessions.items[self.language.documents.items[0].session].client.?.ready();
    }
    fn splitRevision(self: *const zircon.Shell, revision: u64) !bool {
        const tab = &self.tabs.items[self.active];
        const pane = self.secondary orelse return false;
        try t.expectEqual(tab.document, pane.document);
        if ((try self.workspace.getConst(tab.document)).doc.revision() != revision) return false;
        if (self.language.documents.items.len != 1) return false;
        const doc = self.language.documents.items[0];
        const diagnostics = doc.diagnostics orelse return false;
        return doc.version == revision and diagnostics.data.diagnostics.version == revision and
            tab.editor.diagnostics_revision == revision and pane.editor.diagnostics_revision == revision and
            tab.editor.diagnostics_generation == self.language.diagnostics_generation and pane.editor.diagnostics_generation == self.language.diagnostics_generation;
    }
    fn checkReload(self: *const zircon.Shell) !void {
        const id = self.tabs.items[self.active].document;
        const event = self.documentChangeSince(id, 0, 1) orelse return error.MissingExternalReload;
        try t.expectEqual(.external_reload, event.origin);
        try t.expectEqual((try self.workspace.getConst(id)).doc.stateId(), event.state);
        try t.expect(!(try self.workspace.dirty(id)));
        const doc = self.language.documents.items[0];
        try t.expectEqual(@as(u64, 1), self.language.sessions.items[doc.session].client.?.stats().document_changes);
    }
    fn saveConflict(self: *const zircon.Shell) bool {
        return self.status_is_error and std.mem.indexOf(u8, self.status, "changed on disk") != null;
    }
    fn definitionPending(self: *const zircon.Shell) bool {
        return self.language.definition_pending != null;
    }
    fn hoverVisible(self: *const zircon.Shell) bool {
        return self.symbol_hover.preview != null;
    }
    fn configure(self: *zircon.Shell, cx: *ui.Context(zircon.Shell), home: []const u8) !void {
        try self.loadExtensions(cx, home);
    }
    fn command(self: *zircon.Shell, cx: *ui.Context(zircon.Shell), which: zircon.Command) !void {
        var event: ui.Event(ui.Click) = .{ .data = .{} };
        try self.onCommand(&event, cx, which);
    }
    fn second(self: *zircon.Shell, cx: *ui.Context(zircon.Shell)) !void {
        try self.openPath("two.zig");
        cx.notify();
    }
    fn ready(self: *const zircon.Shell) bool {
        if (self.language.documents.items.len != 2) return false;
        for (self.language.documents.items) |doc| if (doc.diagnostics == null) return false;
        return true;
    }
    fn first(self: *const zircon.Shell) Identity {
        for (self.language.documents.items) |doc| if (std.meta.eql(doc.id, self.tabs.items[0].document)) return .{
            .client = @intFromPtr(self.language.sessions.items[doc.session].client.?),
            .diagnostics = @intFromPtr(doc.diagnostics.?.data.diagnostics.items.ptr),
            .generation = self.language.generation,
        };
        return .{ .client = 0, .diagnostics = 0, .generation = self.language.generation };
    }
    fn closePrimary(self: *zircon.Shell, cx: *ui.Context(zircon.Shell)) !void {
        self.active_pane = .primary;
        try command(self, cx, .close_tab);
        self.active_pane = .secondary;
    }
    fn split(self: *const zircon.Shell) bool {
        return self.secondary != null and self.tabs.items.len == 2 and !self.tabs.items[1].primary and self.tabs.items[1].secondary;
    }
    fn completion(self: *zircon.Shell, cx: *ui.Context(zircon.Shell)) !void {
        const id = if (self.active_pane == .secondary) self.secondary.?.document else self.tabs.items[self.active].document;
        const editor = if (self.active_pane == .secondary) &self.secondary.?.editor else &self.tabs.items[self.active].editor;
        var snapshot = try self.workspace.snapshot(id);
        defer snapshot.deinit();
        try editor.setSelection(snapshot, .{ .start = 5, .end = 5 });
        try command(self, cx, .complete);
    }
    fn pending(self: *const zircon.Shell) bool {
        return self.language.pending != null;
    }
    fn bounded(self: *const zircon.Shell) bool {
        return self.language.sessions.items.len == 2 and self.language.activeSessions() == 2 and self.language.pending == null;
    }
    fn targetSecondary(self: *zircon.Shell, cx: *ui.Context(zircon.Shell)) !void {
        var event: ui.Event(ui.Click) = .{ .data = .{} };
        try self.onTab(&event, cx, 0x80000001);
    }
    fn savedSecondary(self: *zircon.Shell, cx: *ui.Context(zircon.Shell)) !void {
        var event: ui.Event(ui.Click) = .{ .data = .{} };
        try self.onTab(&event, cx, 0x80000000);
        try self.onTab(&event, cx, 1);
        const tab = &self.tabs.items[1];
        tab.secondary_state.?.language = .json;
        tab.secondary_state.?.grammar_revision = 0;
        tab.secondary_state.?.syntax_cache.revision = 0;
    }
    fn savedSecondaryInvalidated(self: *const zircon.Shell) bool {
        const state = self.tabs.items[1].secondary_state orelse return false;
        return state.language == .rust and state.grammar_revision == null and state.syntax_cache.revision == null;
    }
    fn currentIsolated(self: *const zircon.Shell) bool {
        var primary_session: ?usize = null;
        var secondary_session: ?usize = null;
        for (self.language.documents.items) |doc| {
            if (std.meta.eql(doc.id, self.tabs.items[0].document)) primary_session = doc.session;
            if (std.meta.eql(doc.id, self.tabs.items[1].document)) {
                secondary_session = doc.session;
                const diagnostics = doc.diagnostics orelse return false;
                if (diagnostics.data.diagnostics.items.len != 1 or !std.mem.eql(u8, diagnostics.data.diagnostics.items[0].message, "emoji warning")) return false;
            }
        }
        return primary_session != null and secondary_session != null and primary_session.? != secondary_session.?;
    }
};

fn openLanguageFixture(root: []const u8, file: []const u8) !struct { app: ui.App, handle: ui.WindowHandle, owner: ui.Entity(zircon.Shell) } {
    var app = try ui.App.init(.{ .allocator = t.allocator });
    errdefer app.deinit();
    const handle = try app.openWindow(zircon.Shell, .{ .visible = false, .width = 1000, .height = 700 }, try zircon.Shell.init(t.allocator, t.io, root, file));
    const owner = try app.windowEntity(zircon.Shell, handle);
    try app.update(owner, zircon.Shell.bootstrap, .{handle});
    _ = try app.step(0);
    return .{ .app = app, .handle = handle, .owner = owner };
}

test "external file changes update two panes and their language server and protect unsaved edits" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "main.zig", .data = "// original bytes\n" });
    try tmp.dir.createDirPath(t.io, "extensions/org.zircon.reload");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "server.py", .data = @embedFile("language_fixture") });
    const server = try tmp.dir.realPathFileAlloc(t.io, "server.py", t.allocator);
    defer t.allocator.free(server);
    const manifest = try std.json.Stringify.valueAlloc(t.allocator, .{
        .schema_version = 1,
        .id = "org.zircon.reload",
        .name = "Reload fixture",
        .version = "1.0.0",
        .contributes = .{ .language_servers = .{.{ .id = "reload", .languages = .{"zig"}, .command = "python3", .args = .{ server, "incremental" } }} },
    }, .{});
    defer t.allocator.free(manifest);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "extensions/org.zircon.reload/extension.json", .data = manifest });
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const home = try std.fs.path.join(t.allocator, &.{ root, "extensions" });
    defer t.allocator.free(home);
    var fixture = try openLanguageFixture(root, "main.zig");
    defer fixture.app.deinit();
    const app = &fixture.app;
    const owner = fixture.owner;
    const handle = fixture.handle;
    try app.update(owner, Ops.configure, .{home});
    try app.update(owner, Ops.command, .{.split_right});
    try waitSplitRevision(app, owner, 0, 0);

    try tmp.dir.writeFile(t.io, .{ .sub_path = "main.zig", .data = "// new disk bytes 行\n" });
    try waitSplitRevision(app, owner, 1, 2);
    try app.read(owner, Ops.checkReload, .{});
    var reloaded: []u8 = undefined;
    try app.read(owner, Ops.source, .{ t.allocator, &reloaded });
    defer t.allocator.free(reloaded);
    try t.expectEqualStrings("// new disk bytes 行\n", reloaded);

    try app.dispatch(handle, .{ .text = " " });
    try waitSplitRevision(app, owner, 2, 2);
    var unsaved: []u8 = undefined;
    try app.read(owner, Ops.source, .{ t.allocator, &unsaved });
    defer t.allocator.free(unsaved);
    try t.expect(!std.mem.eql(u8, reloaded, unsaved));
    const external = "// conflicting disk bytes\n";
    try tmp.dir.writeFile(t.io, .{ .sub_path = "main.zig", .data = external });
    _ = try app.step(4);
    _ = try app.step(4);
    try t.expect(try app.read(owner, Ops.splitRevision, .{2}));
    const frame = &(try app.window(handle)).frames.committed;
    const conflict_visible = for (frame.nodes.items) |node| {
        if (node.kind == .text and std.mem.eql(u8, node.kind.text, "File changed on disk · Use Save As to keep both versions")) break true;
    } else false;
    try t.expect(conflict_visible);
    try app.update(owner, Ops.command, .{.save});
    try t.expect(try app.read(owner, Ops.saveConflict, .{}));
    var retained: []u8 = undefined;
    try app.read(owner, Ops.source, .{ t.allocator, &retained });
    defer t.allocator.free(retained);
    try t.expectEqualStrings(unsaved, retained);
    const disk = try tmp.dir.readFileAlloc(t.io, "main.zig", t.allocator, .limited(1024));
    defer t.allocator.free(disk);
    try t.expectEqualStrings(external, disk);
}

fn waitSplitRevision(app: *ui.App, owner: ui.Entity(zircon.Shell), revision: u64, now: f64) !void {
    const deadline = std.Io.Clock.awake.now(t.io).addDuration(.fromSeconds(5));
    while (!try app.read(owner, Ops.splitRevision, .{revision})) {
        _ = try app.step(now);
        if (std.Io.Clock.awake.now(t.io).compare(.gte, deadline)) return error.SplitRevisionTimeout;
        try std.Io.sleep(t.io, .fromMilliseconds(1), .awake);
    }
}

test "completion without textEdit replaces the current identifier" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "main.zig", .data = "pri" });
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    var fixture = try openLanguageFixture(root, "main.zig");
    defer fixture.app.deinit();
    try fixture.app.update(fixture.owner, Ops.seedCompletion, .{false});
    var source: []u8 = undefined;
    try fixture.app.read(fixture.owner, Ops.source, .{ t.allocator, &source });
    defer t.allocator.free(source);
    try t.expectEqualStrings("print", source);
    try t.expectEqual(@as(usize, 1), try fixture.app.read(fixture.owner, Ops.selectionCount, .{}));
}

test "completion menu closes when typing leaves the identifier" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "main.zig", .data = "alpha" });
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    var fixture = try openLanguageFixture(root, "main.zig");
    defer fixture.app.deinit();
    try fixture.app.update(fixture.owner, Ops.plantCompletion, .{});
    try t.expect(try fixture.app.read(fixture.owner, Ops.completionVisible, .{}));
    try fixture.app.dispatch(fixture.handle, .{ .text = " " });
    _ = try fixture.app.step(0);
    try t.expect(try fixture.app.read(fixture.owner, Ops.completionClosed, .{}));
    var source: []u8 = undefined;
    try fixture.app.read(fixture.owner, Ops.source, .{ t.allocator, &source });
    defer t.allocator.free(source);
    try t.expectEqualStrings("alpha ", source);
}

test "completion additional edits keep one caret at the primary edit" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "main.zig", .data = "const p = pri;\n" });
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    var fixture = try openLanguageFixture(root, "main.zig");
    defer fixture.app.deinit();
    try fixture.app.update(fixture.owner, Ops.seedCompletion, .{true});
    var source: []u8 = undefined;
    try fixture.app.read(fixture.owner, Ops.source, .{ t.allocator, &source });
    defer t.allocator.free(source);
    try t.expectEqualStrings("const std = @import(\"std\");\nconst p = print;\n", source);
    try t.expectEqual(@as(usize, 1), try fixture.app.read(fixture.owner, Ops.selectionCount, .{}));
}

const HoverCheck = enum { edit, leave_symbol, leave_below, leave_window, layout, layout_long, pinned, completion_typing, completion_filter, completion_exit, definition_click, definition_control, definition_import, project_diagnostics };
fn hoverJourney(comptime check: HoverCheck) !void {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    try tmp.dir.createDirPath(t.io, "extensions/org.zircon.hover");
    const fixture_source = try std.mem.replaceOwned(u8, t.allocator, @embedFile("language_fixture"), "Returns the answer.", if (check == .layout_long) "Returns the answer with details about ownership, parameters, memory allocation, error handling, and the lifetime of the returned value. This documentation ends here." else "Returns the answer.");
    defer t.allocator.free(fixture_source);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "server.py", .data = fixture_source });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "one.zig", .data = if (check == .definition_import) "const lib = @import(\"two.zig\");\n" else "const answer = 42;\n" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "two.zig", .data = "const other = 42;\n" });
    const server = try std.fs.path.join(t.allocator, &.{ root, "server.py" });
    defer t.allocator.free(server);
    const mode = switch (check) {
        .definition_import => "host-navigation",
        .completion_filter => "host-filter",
        .completion_exit => "host-completion-exit",
        .project_diagnostics => "project-diagnostics",
        else => "host",
    };
    const manifest = try std.json.Stringify.valueAlloc(t.allocator, .{ .schema_version = 1, .id = "org.zircon.hover", .name = "Hover", .version = "1.0.0", .contributes = .{ .language_servers = .{.{ .id = "hover", .languages = .{"zig"}, .command = "python3", .args = .{ server, mode } }} } }, .{});
    defer t.allocator.free(manifest);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "extensions/org.zircon.hover/extension.json", .data = manifest });
    const home = try std.fs.path.join(t.allocator, &.{ root, "extensions" });
    defer t.allocator.free(home);
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const h = try app.openWindow(zircon.Shell, .{ .visible = false, .width = 1000, .height = 700 }, try zircon.Shell.init(t.allocator, t.io, root, "one.zig"));
    const owner = try app.windowEntity(zircon.Shell, h);
    try app.update(owner, zircon.Shell.bootstrap, .{h});
    try app.update(owner, Ops.configure, .{home});
    const deadline = std.Io.Clock.awake.now(t.io).addDuration(.fromSeconds(5));
    while (!try app.read(owner, Ops.hoverReady, .{})) {
        _ = try app.step(0);
        if (std.Io.Clock.awake.now(t.io).compare(.gte, deadline)) return error.HoverReadinessTimeout;
        try std.Io.sleep(t.io, .fromMilliseconds(1), .awake);
    }
    const frame = &(try app.window(h)).frames.committed;
    const editor_bounds = for (frame.nodes.items, 0..) |node, index| {
        if (node.key) |key| if (key == .string and std.mem.eql(u8, key.string, "primary-editor")) break frame.bounds[index];
    } else return error.MissingEditor;
    if (check == .project_diagnostics) {
        while (!try app.read(owner, Ops.projectIssue, .{})) {
            _ = try app.step(0);
            if (std.Io.Clock.awake.now(t.io).compare(.gte, deadline)) return error.ProjectDiagnosticsTimeout;
            try std.Io.sleep(t.io, .fromMilliseconds(1), .awake);
        }
        try app.update(owner, Ops.command, .{.show_diagnostics});
        _ = try app.step(0);
        const rect = for (frame.nodes.items, 0..) |node, index| {
            if (node.kind == .button and std.mem.eql(u8, node.kind.button.label, "project issue")) break frame.bounds[index];
        } else return error.ProjectIssueMissing;
        const at: ui.Point = .{ .x = rect.x + rect.width / 2, .y = rect.y + rect.height / 2 };
        try app.dispatch(h, .{ .pointer_down = .{ .position = at } });
        try app.dispatch(h, .{ .pointer_up = .{ .position = at } });
        try app.read(owner, Ops.definitionOther, .{});
        return;
    }
    if (check == .completion_typing or check == .completion_filter or check == .completion_exit) {
        for (0..if (check == .completion_exit) @as(usize, 1) else 2) |file| {
            if (file == 1) {
                try app.update(owner, Ops.second, .{});
                while (!try app.read(owner, Ops.bothReady, .{})) {
                    _ = try app.step(0);
                    if (std.Io.Clock.awake.now(t.io).compare(.gte, deadline)) return error.CompletionReadinessTimeout;
                    try std.Io.sleep(t.io, .fromMilliseconds(1), .awake);
                }
            }
            try app.update(owner, Ops.typingPosition, .{});
            try app.dispatch(h, .{ .text = "ans" });
            try t.expect(try app.read(owner, Ops.pending, .{}));
            while (!try app.read(owner, Ops.completionVisible, .{})) {
                _ = try app.step(0);
                if (std.Io.Clock.awake.now(t.io).compare(.gte, deadline)) return error.CompletionTimeout;
                try std.Io.sleep(t.io, .fromMilliseconds(1), .awake);
            }
            if (check == .completion_filter) try app.read(owner, Ops.filtered, .{});
            if (check == .completion_exit) {
                try app.dispatch(h, .{ .text = "w" });
                while (!try app.read(owner, Ops.serverStopped, .{})) {
                    _ = try app.step(0);
                    if (std.Io.Clock.awake.now(t.io).compare(.gte, deadline)) return error.ServerExitTimeout;
                    try std.Io.sleep(t.io, .fromMilliseconds(1), .awake);
                }
                try t.expect(try app.read(owner, Ops.completionClosed, .{}));
                try app.dispatch(h, .{ .key_down = .{ .key = .enter } });
                var after: []u8 = undefined;
                try app.read(owner, Ops.source, .{ t.allocator, &after });
                defer t.allocator.free(after);
                try t.expect(std.mem.startsWith(u8, after, "answ\n"));
            }
            if (check == .completion_typing) {
                try app.dispatch(h, .{ .text = "w" });
                try t.expect(try app.read(owner, Ops.completionVisible, .{}));
                var before: []u8 = undefined;
                try app.read(owner, Ops.source, .{ t.allocator, &before });
                defer t.allocator.free(before);
                try app.dispatch(h, .{ .key_down = .{ .key = .enter } });
                var after: []u8 = undefined;
                try app.read(owner, Ops.source, .{ t.allocator, &after });
                defer t.allocator.free(after);
                try t.expectEqualStrings(before, after);
                while (!try app.read(owner, Ops.completionCurrent, .{})) {
                    _ = try app.step(0);
                    if (std.Io.Clock.awake.now(t.io).compare(.gte, deadline)) return error.CompletionRefreshTimeout;
                    try std.Io.sleep(t.io, .fromMilliseconds(1), .awake);
                }
                try app.dispatch(h, .{ .key_down = .{ .key = .enter } });
                var accepted: []u8 = undefined;
                try app.read(owner, Ops.source, .{ t.allocator, &accepted });
                defer t.allocator.free(accepted);
                try t.expect(std.mem.startsWith(u8, accepted, "answerconst "));
            }
        }
        return;
    }
    const metrics = (try app.window(h)).surface.?.measurer();
    const symbol: ui.Point = .{ .x = editor_bounds.x + if (check == .definition_import) 76 + metrics.caret("const lib = @import(\"two.zig\");", .{ .size = 14, .mono = true }, 22) else @as(f32, 140), .y = editor_bounds.y + 11 };
    if (check == .definition_click or check == .definition_control or check == .definition_import) {
        const modifiers: ui.Modifiers = if (check == .definition_control) .{ .control = true } else .{ .command = true };
        try app.dispatch(h, .{ .pointer_down = .{ .position = symbol, .modifiers = modifiers } });
        try t.expect(try app.read(owner, Ops.definitionPending, .{}));
        try app.dispatch(h, .{ .pointer_up = .{ .position = symbol, .modifiers = modifiers } });
        while (!try app.read(owner, Ops.definitionSelected, .{})) {
            _ = try app.step(0);
            if (std.Io.Clock.awake.now(t.io).compare(.gte, deadline)) return error.DefinitionTimeout;
            try std.Io.sleep(t.io, .fromMilliseconds(1), .awake);
        }
        if (check == .definition_import) try app.read(owner, Ops.definitionOther, .{});
        return;
    }
    if (check == .pinned) {
        try app.dispatch(h, .{ .pointer_down = .{ .position = symbol, .button = .secondary } });
        try app.dispatch(h, .{ .pointer_up = .{ .position = symbol, .button = .secondary } });
        _ = try app.step(0);
        const rect = for (frame.nodes.items, 0..) |node, index| {
            if (node.kind == .button and std.mem.eql(u8, node.kind.button.label, "Show Symbol Information")) break frame.bounds[index];
        } else return error.SymbolActionMissing;
        const at: ui.Point = .{ .x = rect.x + 20, .y = rect.y + rect.height / 2 };
        try app.dispatch(h, .{ .pointer_down = .{ .position = at } });
        try app.dispatch(h, .{ .pointer_up = .{ .position = at } });
    } else if (check == .edit) try app.update(owner, Ops.command, .{.show_symbol_info}) else {
        try app.dispatch(h, .{ .pointer_move = .{ .position = symbol } });
        _ = try app.step(0.4);
    }
    while (!try app.read(owner, Ops.hoverVisible, .{})) {
        _ = try app.step(0.4);
        if (std.Io.Clock.awake.now(t.io).compare(.gte, deadline)) return error.HoverPresentationTimeout;
        try std.Io.sleep(t.io, .fromMilliseconds(1), .awake);
    }
    _ = try app.step(0.4);
    var card = false;
    for ((try app.window(h)).frames.committed.nodes.items) |node| if (node.key) |key| if (key == .string and std.mem.eql(u8, key.string, "symbol-hover")) {
        card = true;
    };
    try t.expect(card);
    switch (check) {
        .completion_typing, .completion_filter, .completion_exit, .definition_click, .definition_control, .definition_import, .project_diagnostics => unreachable,
        .pinned => {
            try app.dispatch(h, .{ .pointer_move = .{ .position = symbol } });
            _ = try app.step(0.4);
            try t.expect(try app.read(owner, Ops.hoverVisible, .{}));
            return;
        },
        .edit => try app.dispatch(h, .{ .text = "x" }),
        .leave_symbol => try app.dispatch(h, .{ .pointer_move = .{ .position = .{ .x = editor_bounds.x + 450, .y = editor_bounds.y + 300 } } }),
        .leave_below => try app.dispatch(h, .{ .pointer_move = .{ .position = .{ .x = symbol.x, .y = editor_bounds.y + 300 } } }),
        .leave_window => try app.dispatch(h, .pointer_leave),
        .layout, .layout_long => {
            if (comptime ui.testing.native != void) try (try app.window(h)).snapshot("/tmp/zircon-symbol-hover-before.png");
            const popup = for (frame.nodes.items, 0..) |node, index| {
                if (node.key) |key| if (key == .string and std.mem.eql(u8, key.string, "symbol-hover")) break frame.bounds[index];
            } else return error.MissingHover;
            var description = false;
            for (frame.scene.items) |item| if (item.kind == .text and std.mem.eql(u8, item.text, if (check == .layout_long) "here." else "Returns")) {
                description = item.rect.y >= popup.y + 8 and item.rect.y + item.rect.height <= popup.y + popup.height - 8;
            };
            try t.expect(description);
            return;
        },
    }
    try t.expect(!try app.read(owner, Ops.hoverVisible, .{}));
}

test "symbol information renders language-server Markdown and dismisses on edit" {
    try hoverJourney(.edit);
}
test "symbol hover dismisses when the pointer leaves its source symbol" {
    try hoverJourney(.leave_symbol);
}
test "symbol hover dismisses when the pointer leaves the window" {
    try hoverJourney(.leave_window);
}
test "symbol hover fits the rendered signature and documentation" {
    try hoverJourney(.layout);
}

test "symbol hover sizes wrapped documentation from rendered content" {
    try hoverJourney(.layout_long);
}
fn waitReady(app: *ui.App, owner: ui.Entity(zircon.Shell)) !void {
    const deadline = std.Io.Clock.awake.now(t.io).addDuration(.fromSeconds(5));
    while (!try app.read(owner, Ops.ready, .{})) {
        _ = try app.step(0);
        if (std.Io.Clock.awake.now(t.io).compare(.gte, deadline)) return error.LanguageReadinessTimeout;
        try std.Io.sleep(t.io, .fromMilliseconds(1), .awake);
    }
}
fn choose(app: *ui.App, owner: ui.Entity(zircon.Shell), h: ui.WindowHandle, name: []const u8) !void {
    try app.update(owner, Ops.command, .{.language_picker});
    _ = try app.step(0);
    try app.dispatch(h, .{ .text = name });
    _ = try app.step(0);
    try app.dispatch(h, .{ .key_down = .{ .key = .enter } });
}

test "language picker preserves unrelated clients and isolates same revision secondary rebinding" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    try tmp.dir.createDirPath(t.io, "extensions/org.zircon.lifecycle");
    const late = try std.mem.replaceOwned(u8, t.allocator, @embedFile("language_fixture"), "opened.pop(params[\"textDocument\"][\"uri\"], None)", "opened.pop(params[\"textDocument\"][\"uri\"], None)\n        send({\"jsonrpc\": \"2.0\", \"method\": \"textDocument/publishDiagnostics\", \"params\": {\"uri\": params[\"textDocument\"][\"uri\"], \"diagnostics\": [{\"range\": {\"start\": {\"line\": 0, \"character\": 0}, \"end\": {\"line\": 0, \"character\": 1}}, \"message\": \"stale language\"}]}})");
    defer t.allocator.free(late);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "server.py", .data = late });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "one.zig", .data = "a🙂b" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "two.zig", .data = "a🙂b" });
    const server = try std.fs.path.join(t.allocator, &.{ root, "server.py" });
    defer t.allocator.free(server);
    const manifest = try std.json.Stringify.valueAlloc(t.allocator, .{ .schema_version = 1, .id = "org.zircon.lifecycle", .name = "Lifecycle", .version = "1.0.0", .contributes = .{ .language_servers = .{.{ .id = "fixture", .languages = .{ "zig", "rust" }, .command = "python3", .args = .{ server, "host" } }} } }, .{});
    defer t.allocator.free(manifest);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "extensions/org.zircon.lifecycle/extension.json", .data = manifest });
    const home = try std.fs.path.join(t.allocator, &.{ root, "extensions" });
    defer t.allocator.free(home);
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const h = try app.openWindow(zircon.Shell, .{ .visible = false, .width = 1000, .height = 700 }, try zircon.Shell.init(t.allocator, t.io, root, "one.zig"));
    const owner = try app.windowEntity(zircon.Shell, h);
    try app.update(owner, zircon.Shell.bootstrap, .{h});
    try app.update(owner, Ops.configure, .{home});
    try app.update(owner, Ops.second, .{});
    try waitReady(&app, owner);
    const before = try app.read(owner, Ops.first, .{});
    try t.expect(before.client != 0 and before.diagnostics != 0);
    try app.update(owner, Ops.command, .{.split_right});
    try app.update(owner, Ops.savedSecondary, .{});
    try app.update(owner, Ops.completion, .{});
    try t.expect(try app.read(owner, Ops.pending, .{}));
    try choose(&app, owner, h, "Rust");
    const after = try app.read(owner, Ops.first, .{});
    try t.expectEqual(before, after);
    try t.expect(try app.read(owner, Ops.savedSecondaryInvalidated, .{}));
    try waitReady(&app, owner);
    try t.expect(try app.read(owner, Ops.currentIsolated, .{}));
    try t.expectEqual(before, try app.read(owner, Ops.first, .{}));
    try app.update(owner, Ops.targetSecondary, .{});
    try app.update(owner, Ops.closePrimary, .{});
    try t.expect(try app.read(owner, Ops.split, .{}));
    for ([_][]const u8{ "Zig", "Rust", "Zig" }) |name| {
        try choose(&app, owner, h, name);
        try waitReady(&app, owner);
        try t.expect(try app.read(owner, Ops.bounded, .{}));
        try t.expectEqual(before, try app.read(owner, Ops.first, .{}));
    }
    try choose(&app, owner, h, "Plain Text");
    try app.update(owner, Ops.command, .{.extensions});
    _ = try app.step(0);
    var running = false;
    for ((try app.window(h)).frames.committed.scene.items) |item| {
        if (item.kind == .text and std.mem.eql(u8, item.text, "fixture · Running")) running = true;
        if (item.kind == .text) try t.expect(std.mem.indexOf(u8, item.text, "fixture · Unavailable") == null);
    }
    try t.expect(running);
}

const GrammarOps = struct {
    fn configure(self: *zircon.Shell, cx: *ui.Context(zircon.Shell), home: []const u8, executable: []const u8) !void {
        self.extension_host_path = executable;
        try self.loadExtensions(cx, home);
    }
    fn pending(self: *const zircon.Shell) bool {
        return !self.status_is_error and self.language.pending == null and self.language.syntax_documents.items.len == 1 and self.language.syntax_documents.items[0].pending and self.tabs.items[0].editor.grammar_revision == null;
    }
    fn detachedCompletion(self: *zircon.Shell, _: *ui.Context(zircon.Shell)) void {
        self.language.pending = .{ .document = self.tabs.items[0].document, .session = 0, .request = 1, .revision = 0, .cursor = 0 };
    }
    fn highlighted(self: *const zircon.Shell) bool {
        const editor = self.tabs.items[0].editor;
        return !self.status_is_error and editor.grammar_revision == 0 and editor.grammar_spans.len == 1 and editor.grammar_spans[0].kind == .keyword;
    }
};
fn waitFile(app: *ui.App, dir: std.Io.Dir, name: []const u8) !void {
    const deadline = std.Io.Clock.awake.now(t.io).addDuration(.fromSeconds(5));
    while (true) {
        if (dir.statFile(t.io, name, .{})) |_| return else |err| if (err != error.FileNotFound) return err;
        _ = try app.step(0);
        if (std.Io.Clock.awake.now(t.io).compare(.gte, deadline)) return error.WorkerMarkerTimeout;
        try std.Io.sleep(t.io, .fromMilliseconds(1), .awake);
    }
}
fn waitJobs(app: *ui.App, count: usize) !void {
    const deadline = std.Io.Clock.awake.now(t.io).addDuration(.fromSeconds(5));
    while (true) {
        _ = try app.step(0);
        var pending: usize = 0;
        for (app.state.jobs.queue.slots.items) |slot| if (slot.entry != null) {
            pending += 1;
        };
        if (pending == count) return;
        if (std.Io.Clock.awake.now(t.io).compare(.gte, deadline)) return error.WorkerDeliveryTimeout;
        try std.Io.sleep(t.io, .fromMilliseconds(1), .awake);
    }
}

test "same revision language changes reject delayed grammar failures and highlights" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    try tmp.dir.createDirPath(t.io, "extensions/org.zircon.grammar-lifecycle");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "main.first", .data = "abc" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "worker.py", .data =
        \\#!/usr/bin/env python3
        \\import json, pathlib, sys, time
        \\root = pathlib.Path(__file__).parent
        \\source = sys.stdin.buffer.read()
        \\name = sys.argv[3]
        \\counter = root / (name + '.count')
        \\number = int(counter.read_text()) + 1 if counter.exists() else 1
        \\counter.write_text(str(number))
        \\key = name + str(number)
        \\(root / (key + '.started')).touch()
        \\deadline = time.monotonic() + 8
        \\while not (root / (key + '.release')).exists():
        \\    if time.monotonic() > deadline: sys.exit(9)
        \\    time.sleep(.002)
        \\if key == 'first1':
        \\    sys.stderr.write('obsolete grammar failed')
        \\    sys.exit(7)
        \\kind = 'keyword' if key == 'first2' else 'string'
        \\print(json.dumps({'bytes': len(source), 'spans': [{'start': 0, 'end': 1, 'kind': kind}]}))
        \\
    });
    const worker_file = try tmp.dir.openFile(t.io, "worker.py", .{});
    defer worker_file.close(t.io);
    try worker_file.setPermissions(t.io, if (comptime builtin.os.tag == .windows) .default_file else .fromMode(0o755));
    try tmp.dir.writeFile(t.io, .{ .sub_path = "extensions/org.zircon.grammar-lifecycle/extension.json", .data =
        \\{"schema_version":1,"id":"org.zircon.grammar-lifecycle","name":"Grammar lifecycle","version":"1.0.0","contributes":{"languages":[{"id":"first","name":"First","extensions":["first"],"grammar":{"builtin":true,"name":"first","wasm":"","highlights":""}},{"id":"second","name":"Second","extensions":["second"],"grammar":{"builtin":true,"name":"second","wasm":"","highlights":""}}]}}
    });
    const home = try std.fs.path.join(t.allocator, &.{ root, "extensions" });
    defer t.allocator.free(home);
    const executable = try std.fs.path.join(t.allocator, &.{ root, "worker.py" });
    defer t.allocator.free(executable);
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    defer for ([_][]const u8{ "first1.release", "second1.release", "first2.release" }) |name| tmp.dir.writeFile(t.io, .{ .sub_path = name, .data = "" }) catch {};
    const h = try app.openWindow(zircon.Shell, .{ .visible = false, .width = 1000, .height = 700 }, try zircon.Shell.init(t.allocator, t.io, root, "main.first"));
    const owner = try app.windowEntity(zircon.Shell, h);
    try app.update(owner, zircon.Shell.bootstrap, .{h});
    try app.update(owner, GrammarOps.configure, .{ home, executable });
    try waitFile(&app, tmp.dir, "first1.started");
    try app.update(owner, GrammarOps.detachedCompletion, .{});
    try choose(&app, owner, h, "Second");
    try waitFile(&app, tmp.dir, "second1.started");
    try choose(&app, owner, h, "First");
    try waitFile(&app, tmp.dir, "first2.started");
    try t.expect(try app.read(owner, GrammarOps.pending, .{}));
    try tmp.dir.writeFile(t.io, .{ .sub_path = "first1.release", .data = "" });
    try waitJobs(&app, 2);
    try t.expect(try app.read(owner, GrammarOps.pending, .{}));
    try tmp.dir.writeFile(t.io, .{ .sub_path = "second1.release", .data = "" });
    try waitJobs(&app, 1);
    try t.expect(try app.read(owner, GrammarOps.pending, .{}));
    try tmp.dir.writeFile(t.io, .{ .sub_path = "first2.release", .data = "" });
    try waitJobs(&app, 0);
    try t.expect(try app.read(owner, GrammarOps.highlighted, .{}));
}

const ResolverOps = struct {
    fn pending(self: *const zircon.Shell) bool {
        if (self.status_is_error or self.language.sessions.items.len != 2) return false;
        return self.language.sessions.items[0].resolving and self.language.sessions.items[1].resolving;
    }
    fn sharedReady(self: *const zircon.Shell) bool {
        if (self.status_is_error or self.language.sessions.items.len != 2) return false;
        const first = self.language.sessions.items[0].client orelse return false;
        return first.ready() and self.language.sessions.items[1].resolving and self.language.sessions.items[1].client == null;
    }
    fn noErrors(self: *const zircon.Shell) bool {
        return !self.status_is_error and self.language.activeSessions() == 2;
    }
};
test "retired resolver callbacks cannot restart reused slots or strand another document" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    try tmp.dir.createDirPath(t.io, "extensions/org.zircon.resolver-lifecycle");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "one.zig", .data = "a🙂b" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "two.zig", .data = "a🙂b" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "server.py", .data = @embedFile("language_fixture") });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "worker.py", .data =
        \\#!/usr/bin/env python3
        \\import json, pathlib, sys, time
        \\root = pathlib.Path(__file__).parent
        \\counter = root / 'resolver.count'
        \\number = int(counter.read_text()) + 1 if counter.exists() else 1
        \\counter.write_text(str(number))
        \\key = 'resolver' + str(number)
        \\(root / (key + '.started')).touch()
        \\deadline = time.monotonic() + 8
        \\while not (root / (key + '.release')).exists():
        \\    if time.monotonic() > deadline: sys.exit(9)
        \\    time.sleep(.002)
        \\if number == 2:
        \\    sys.stderr.write('obsolete resolver failed')
        \\    sys.exit(7)
        \\print(json.dumps({'command':'python3','args':[str(root / 'server.py'),'host'],'cwd':str(root)}))
        \\
    });
    const worker_file = try tmp.dir.openFile(t.io, "worker.py", .{});
    defer worker_file.close(t.io);
    try worker_file.setPermissions(t.io, if (comptime builtin.os.tag == .windows) .default_file else .fromMode(0o755));
    try tmp.dir.writeFile(t.io, .{ .sub_path = "extensions/org.zircon.resolver-lifecycle/extension.json", .data =
        \\{"schema_version":1,"id":"org.zircon.resolver-lifecycle","name":"Resolver lifecycle","version":"1.0.0","contributes":{"language_servers":[{"id":"fixture","languages":["zig","rust"],"command":"@zircon-builtin","zed_server":"fixture"}]}}
    });
    const home = try std.fs.path.join(t.allocator, &.{ root, "extensions" });
    defer t.allocator.free(home);
    const executable = try std.fs.path.join(t.allocator, &.{ root, "worker.py" });
    defer t.allocator.free(executable);
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    defer for ([_][]const u8{ "resolver1.release", "resolver2.release", "resolver3.release" }) |name| tmp.dir.writeFile(t.io, .{ .sub_path = name, .data = "" }) catch {};
    const h = try app.openWindow(zircon.Shell, .{ .visible = false, .width = 1000, .height = 700 }, try zircon.Shell.init(t.allocator, t.io, root, "one.zig"));
    const owner = try app.windowEntity(zircon.Shell, h);
    try app.update(owner, zircon.Shell.bootstrap, .{h});
    try app.update(owner, GrammarOps.configure, .{ home, executable });
    try app.update(owner, Ops.second, .{});
    try waitFile(&app, tmp.dir, "resolver1.started");
    try choose(&app, owner, h, "Rust");
    try waitFile(&app, tmp.dir, "resolver2.started");
    try choose(&app, owner, h, "Zig");
    try waitFile(&app, tmp.dir, "resolver3.started");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "resolver2.release", .data = "" });
    try waitJobs(&app, 2);
    try t.expect(try app.read(owner, ResolverOps.pending, .{}));
    try tmp.dir.writeFile(t.io, .{ .sub_path = "resolver1.release", .data = "" });
    try waitJobs(&app, 1);
    const deadline = std.Io.Clock.awake.now(t.io).addDuration(.fromSeconds(5));
    while (!try app.read(owner, ResolverOps.sharedReady, .{})) {
        _ = try app.step(0);
        if (std.Io.Clock.awake.now(t.io).compare(.gte, deadline)) return error.SharedServerTimeout;
        try std.Io.sleep(t.io, .fromMilliseconds(1), .awake);
    }
    try tmp.dir.writeFile(t.io, .{ .sub_path = "resolver3.release", .data = "" });
    try waitJobs(&app, 0);
    try waitReady(&app, owner);
    try t.expect(try app.read(owner, ResolverOps.noErrors, .{}));
}

test "symbol hover does not remain over blank space below the last source line" {
    try hoverJourney(.leave_below);
}

test "symbol hover opened explicitly stays visible while moving over its source" {
    try hoverJourney(.pinned);
}
test "language completion requests suggestions while typing identifiers" {
    try hoverJourney(.completion_typing);
}
test "language completion closes when its server exits during a refresh" {
    try hoverJourney(.completion_exit);
}
test "language command click requests the definition under the pointer" {
    try hoverJourney(.definition_click);
}

test "language control click navigates to the definition" {
    try hoverJourney(.definition_control);
}
test "language command click follows an import into another file" {
    try hoverJourney(.definition_import);
}

test "language diagnostics include server reported project files without an open tab" {
    try hoverJourney(.project_diagnostics);
}

test "language completion filters and orders the server candidates for the typed prefix" {
    try hoverJourney(.completion_filter);
}
