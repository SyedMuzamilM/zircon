//! App-level journeys use temporary repositories, manifests and real documents.
//! Native rendering has a separate suite; these tests share its event routing.
const std = @import("std");
const builtin = @import("builtin");
const zircon = @import("zircon");
const ui = @import("zircon_ui");
const t = std.testing;
test "completion identity includes server session and document URI" {
    var shell = try zircon.Shell.init(t.allocator, t.io, ".", null);
    defer shell.deinit(t.allocator);
    const id = shell.tabs.items[0].document;
    const uri = try t.allocator.dupe(u8, "file:///current.zig");
    const path = t.allocator.dupe(u8, "/current.zig") catch |err| {
        t.allocator.free(uri);
        return err;
    };
    shell.language.documents.append(t.allocator, .{ .id = id, .uri = uri, .path = path, .session = 1 }) catch |err| {
        t.allocator.free(uri);
        t.allocator.free(path);
        return err;
    };
    shell.language.pending = .{ .document = id, .session = 1, .request = 2, .revision = 0, .cursor = 0 };
    try t.expect(!shell.language.expects(0, uri, 2, 0));
    try t.expect(!shell.language.expects(1, "file:///previous.zig", 2, 0));
    try t.expect(!shell.language.expects(1, uri, 2, 1));
    try t.expect(shell.language.expects(1, uri, 2, 0));
}
fn git(root: []const u8, args: []const []const u8) ![]u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(t.allocator);
    try argv.appendSlice(t.allocator, &.{ "git", "-C", root });
    try argv.appendSlice(t.allocator, args);
    const result = try std.process.run(t.allocator, t.io, .{ .argv = argv.items });
    defer t.allocator.free(result.stderr);
    errdefer t.allocator.free(result.stdout);
    if (result.term != .exited or result.term.exited != 0) return error.FixtureGitFailed;
    return result.stdout;
}
fn command(root: []const u8, args: []const []const u8) !void {
    t.allocator.free(try git(root, args));
}
fn settle(app: *ui.App) !void {
    try settleAt(app, 0);
}
fn settleAt(app: *ui.App, time: f64) !void {
    const deadline = std.Io.Clock.awake.now(t.io).addDuration(.fromSeconds(5));
    while (try app.tasksPending()) {
        _ = try app.step(time);
        if (std.Io.Clock.awake.now(t.io).compare(.gte, deadline)) return error.JourneyTimeout;
        std.Io.sleep(t.io, .fromMilliseconds(1), .awake) catch {};
    }
    _ = try app.step(time);
}
const Ops = struct {
    fn setProjectQuery(self: *zircon.Shell, cx: *ui.Context(zircon.Shell), bytes: []const u8) !void {
        const Set = struct {
            fn call(input: *ui.controls.TextInput, context: *ui.Context(ui.controls.TextInput), value: []const u8) !void {
                input.bytes.clearRetainingCapacity();
                try input.bytes.appendSlice(input.allocator, value);
                input.cursor = value.len;
                input.anchor = value.len;
                input.revision +%= 1;
                context.notify();
            }
        };
        try cx.update(self.fields.?.project_search.query, Set.call, .{bytes});
    }
    fn execute(self: *zircon.Shell, cx: *ui.Context(zircon.Shell), which: zircon.Command) !void {
        var event: ui.Event(ui.Click) = .{ .data = .{} };
        try self.onCommand(&event, cx, which);
        if (self.status_is_error) {
            std.debug.print("Journey: {s}\n", .{self.status});
            return error.CommandFailed;
        }
    }
    fn open(self: *zircon.Shell, cx: *ui.Context(zircon.Shell), path: []const u8) !void {
        try self.openPath(path);
        cx.notify();
    }
    fn openKeepActive(self: *zircon.Shell, cx: *ui.Context(zircon.Shell), path: []const u8) !void {
        const old_active = self.active;
        try self.openPath(path);
        self.active = old_active;
        cx.notify();
    }
    fn configure(self: *zircon.Shell, cx: *ui.Context(zircon.Shell), home: []const u8) !void {
        try self.loadExtensions(cx, home);
    }
    fn gitFile(self: *zircon.Shell, cx: *ui.Context(zircon.Shell)) !void {
        var event: ui.Event(ui.Click) = .{ .data = .{} };
        try self.onGitFile(&event, cx, 0);
    }
    fn gitCommit(self: *zircon.Shell, cx: *ui.Context(zircon.Shell), index: u32) !void {
        var event: ui.Event(ui.Click) = .{ .data = .{} };
        try self.onGitCommit(&event, cx, index);
    }
    fn gitGeneration(self: *const zircon.Shell) u64 {
        return self.git.generation;
    }
    fn editableGitSource(self: *const zircon.Shell) bool {
        return if (self.git.editable) |projection| projection.sources.items.len > 0 else false;
    }
    fn editableGitSources(self: *const zircon.Shell) usize {
        return if (self.git.editable) |projection| projection.sources.items.len else 0;
    }
    fn historyTabs(self: *const zircon.Shell) usize {
        return self.git.history_tabs.items.len;
    }
    fn sourceBySuffix(self: *const zircon.Shell, suffix: []const u8, a: std.mem.Allocator, out: *[]u8) !void {
        for (self.workspace.slots.items) |slot| {
            const record = slot.record orelse continue;
            if (record.path) |path| if (std.mem.endsWith(u8, path, suffix)) {
                var snapshot = record.doc.snapshot();
                defer snapshot.deinit();
                out.* = try snapshot.copy(a, .{ .start = 0, .end = snapshot.byteLen() });
                return;
            };
        }
        return error.DocumentNotFound;
    }
    fn previewImage(self: *const zircon.Shell) ?u64 {
        return self.preview.?.view.imageIdentity("image.png");
    }
    fn previewLayouts(self: *const zircon.Shell) usize {
        return self.preview.?.view.layoutBuilds();
    }
    fn staged(self: *const zircon.Shell) bool {
        return self.git.status != null and self.git.status.?.entries.len > 0 and self.git.status.?.entries[0].staged;
    }
    fn markers(self: *const zircon.Shell) usize {
        return self.tabs.items[self.active].editor.git_changes.len;
    }
    fn blame(self: *const zircon.Shell) bool {
        return self.tabs.items[self.active].editor.inline_blame != null;
    }
    fn extension(self: *const zircon.Shell) bool {
        return self.extension_snapshot != null and self.extension_snapshot.?.installed().len == 1;
    }
    fn custom(self: *const zircon.Shell) bool {
        return self.tabs.items[self.active].editor.language == .custom;
    }
    fn split(self: *const zircon.Shell) bool {
        return self.secondary != null;
    }
    fn active(self: *const zircon.Shell) usize {
        return self.active;
    }
    fn count(self: *const zircon.Shell) usize {
        return self.tabs.items.len;
    }
    fn firstIsTwo(self: *const zircon.Shell) bool {
        const record = self.workspace.getConst(self.tabs.items[0].document) catch return false;
        return std.mem.eql(u8, record.title(), "two.zig");
    }
    fn previewCurrent(self: *const zircon.Shell) bool {
        return self.preview != null and self.preview.?.view.revision() == (self.workspace.getConst(self.preview.?.document) catch return false).doc.revision();
    }
    fn diagnostics(self: *const zircon.Shell) bool {
        for (self.language.documents.items) |doc| if (doc.diagnostics) |message| if (message.data.diagnostics.items.len == 1) return true;
        return false;
    }
    fn completion(self: *const zircon.Shell) bool {
        return self.language.completions != null;
    }
    fn stopped(self: *const zircon.Shell) bool {
        return self.language.sessions.items.len == 0 and self.language.documents.items.len == 0;
    }
    fn expandCompletion(self: *zircon.Shell, cx: *ui.Context(zircon.Shell)) !void {
        const message = &self.language.completions.?;
        const first = message.data.completion.items[0];
        const items = try message.arena.allocator().alloc(@TypeOf(first), 2);
        items[0] = first;
        items[1] = first;
        items[1].label = "other";
        items[1].insert_text = "other";
        if (items[1].text_edit) |*edit| edit.new_text = "other";
        message.data.completion.items = items;
        cx.notify();
    }
    fn completionIndex(self: *const zircon.Shell) usize {
        return self.language.completion_index;
    }
    fn cursor(self: *zircon.Shell, cx: *ui.Context(zircon.Shell)) !void {
        const tab = &self.tabs.items[self.active];
        var snapshot = try self.workspace.snapshot(tab.document);
        defer snapshot.deinit();
        try tab.editor.setSelection(snapshot, .{ .start = 5, .end = 5 });
        cx.notify();
    }
    fn matches(self: *const zircon.Shell) usize {
        return if (self.search.results) |results| results.total_matches else 0;
    }
    fn source(self: *const zircon.Shell, a: std.mem.Allocator, output: *[]u8) !void {
        var snapshot = try self.workspace.snapshot(self.tabs.items[self.active].document);
        defer snapshot.deinit();
        output.* = try snapshot.copy(a, .{ .start = 0, .end = snapshot.byteLen() });
    }
};
fn open(app: *ui.App, root: []const u8, file: []const u8) !ui.WindowHandle {
    return openNamed(app, root, file, "Zircon");
}
fn openNamed(app: *ui.App, root: []const u8, file: []const u8, title: []const u8) !ui.WindowHandle {
    var shell = try zircon.Shell.init(t.allocator, t.io, root, file);
    const h = app.openWindow(zircon.Shell, .{ .title = title, .visible = false, .menus = &zircon.menus.groups, .width = 1200, .height = 760 }, shell) catch |err| {
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
fn buttonPoint(app: *ui.App, h: ui.WindowHandle, name: []const u8) !ui.Point {
    const frame = &(try app.window(h)).frames.committed;
    for (frame.nodes.items, 0..) |node, index| if (node.kind == .button and std.mem.eql(u8, node.kind.button.label, name) and insideTabs(frame, @intCast(index))) {
        const rect = frame.bounds[index];
        return .{ .x = rect.x + rect.width / 2, .y = rect.y + rect.height / 2 };
    };
    return error.ControlNotFound;
}
test "dragging reorders tabs and opens a different file in the split pane" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "one.zig", .data = "one\n" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "two.zig", .data = "two\n" });
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const h = try open(&app, root, "one.zig");
    const owner = try app.windowEntity(zircon.Shell, h);
    try app.update(owner, Ops.open, .{"two.zig"});
    _ = try app.step(0);
    const from = try buttonPoint(&app, h, "two.zig");
    const to = try buttonPoint(&app, h, "one.zig");
    try app.dispatch(h, .{ .pointer_down = .{ .position = from } });
    try app.dispatch(h, .{ .pointer_move = .{ .position = to } });
    _ = try app.step(0);
    try app.dispatch(h, .{ .pointer_up = .{ .position = to } });
    _ = try app.step(0);
    try t.expect(try app.read(owner, Ops.firstIsTwo, .{}));
    const one = try buttonPoint(&app, h, "one.zig");
    const right: ui.Point = .{ .x = 1100, .y = 220 };
    try app.dispatch(h, .{ .pointer_down = .{ .position = one } });
    try app.dispatch(h, .{ .pointer_move = .{ .position = right } });
    _ = try app.step(0);
    try app.dispatch(h, .{ .pointer_up = .{ .position = right } });
    _ = try app.step(0);
    try t.expect(try app.read(owner, Ops.split, .{}));
    try app.dispatch(h, .{ .text = "split " });
    _ = try app.step(0);
    var primary: []u8 = undefined;
    try app.read(owner, Ops.source, .{ t.allocator, &primary });
    defer t.allocator.free(primary);
    try t.expectEqualStrings("two\n", primary);
    const Left = struct {
        fn source(self: *const zircon.Shell, a: std.mem.Allocator, output: *[]u8) !void {
            var snapshot = try self.workspace.snapshot(self.secondary.?.document);
            defer snapshot.deinit();
            output.* = try snapshot.copy(a, .{ .start = 0, .end = snapshot.byteLen() });
        }
    };
    var secondary: []u8 = undefined;
    try app.read(owner, Left.source, .{ t.allocator, &secondary });
    defer t.allocator.free(secondary);
    try t.expectEqualStrings("split one\n", secondary);
}
test "Markdown preview shares the editable source revision and closes safely" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "note.md", .data = "# Title\n\n![tiny](image.png)\n\nText **bold** and [source](other.md).\n\n```zig\nconst n = 1;\n```\n\n| One | Two |\n| --- | --- |\n| a | b |\n" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "image.png", .data = @embedFile("image_fixture") });
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const h = try open(&app, root, "note.md");
    const owner = try app.windowEntity(zircon.Shell, h);
    try send(&app, h, .markdown_preview);
    const preview_bounds = try elementBounds(&app, h, "markdown-preview");
    const layouts = try app.read(owner, Ops.previewLayouts, .{});
    const point: ui.Point = .{ .x = preview_bounds.x + 30, .y = preview_bounds.y + 40 };
    try app.dispatch(h, .{ .scroll = .{ .position = point, .x = 0, .y = -30 } });
    _ = try app.step(0);
    try t.expectEqual(layouts, try app.read(owner, Ops.previewLayouts, .{}));
    try app.dispatch(h, .{ .resize = .{ .width = 920, .height = 650 } });
    _ = try app.step(0);
    try t.expectEqual(layouts + 1, try app.read(owner, Ops.previewLayouts, .{}));
    const image_identity = try app.read(owner, Ops.previewImage, .{});
    if (comptime ui.testing.native != void) try t.expect(image_identity != null);
    try t.expect(try app.read(owner, Ops.previewCurrent, .{}));
    try app.dispatch(h, .{ .text = "Updated " });
    _ = try app.step(0);
    try t.expect(try app.read(owner, Ops.previewCurrent, .{}));
    try t.expectEqual(image_identity, try app.read(owner, Ops.previewImage, .{}));
    if (comptime ui.testing.native != void) try (try app.window(h)).snapshot("/tmp/zircon-markdown.png");
    try send(&app, h, .close_tab);
    try send(&app, h, .discard_dirty);
    try t.expectEqual(@as(usize, 0), try app.read(owner, Ops.count, .{}));
}
test "installed server publishes diagnostics applies Unicode completion and stops on disable" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    try tmp.dir.createDir(t.io, "source", .default_dir);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "server.py", .data = @embedFile("language_fixture") });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "main.zig", .data = "a🙂b" });
    const server = try std.fs.path.join(t.allocator, &.{ root, "server.py" });
    defer t.allocator.free(server);
    const manifest = try std.json.Stringify.valueAlloc(t.allocator, .{ .schema_version = 1, .id = "org.zircon.fixture", .name = "Fixture", .version = "1.0.0", .contributes = .{ .language_servers = .{.{ .id = "fixture", .languages = .{"zig"}, .command = "python3", .args = .{ server, "host" } }} } }, .{});
    defer t.allocator.free(manifest);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "source/extension.json", .data = manifest });
    const home = try std.fs.path.join(t.allocator, &.{ root, "extensions" });
    defer t.allocator.free(home);
    const source = try std.fs.path.join(t.allocator, &.{ root, "source" });
    defer t.allocator.free(source);
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const h = try open(&app, root, "main.zig");
    const owner = try app.windowEntity(zircon.Shell, h);
    try app.update(owner, Ops.configure, .{home});
    try send(&app, h, .install_extension);
    try app.dispatch(h, .{ .text = source });
    try app.dispatch(h, .{ .key_down = .{ .key = .enter } });
    const deadline = std.Io.Clock.awake.now(t.io).addDuration(.fromSeconds(5));
    while (!try app.read(owner, Ops.diagnostics, .{})) {
        _ = try app.step(0);
        if (std.Io.Clock.awake.now(t.io).compare(.gte, deadline)) return error.DiagnosticsTimeout;
        std.Io.sleep(t.io, .fromMilliseconds(1), .awake) catch {};
    }
    try send(&app, h, .back_to_editor);
    try app.update(owner, Ops.cursor, .{});
    _ = try app.step(0);
    const completion_caret = (try app.window(h)).frames.committed.text_input.?.caret;
    try send(&app, h, .complete);
    while (!try app.read(owner, Ops.completion, .{})) {
        _ = try app.step(0);
        if (std.Io.Clock.awake.now(t.io).compare(.gte, deadline)) return error.CompletionTimeout;
        std.Io.sleep(t.io, .fromMilliseconds(1), .awake) catch {};
    }
    try app.update(owner, Ops.expandCompletion, .{});
    _ = try app.step(0);
    const completion_bounds = try elementBounds(&app, h, "completion-list");
    try t.expectApproxEqAbs(completion_caret.x, completion_bounds.x, 1);
    try t.expectApproxEqAbs(completion_caret.y + completion_caret.height + 4, completion_bounds.y, 1);
    try app.dispatch(h, .{ .key_down = .{ .key = .down } });
    try t.expectEqual(@as(usize, 1), try app.read(owner, Ops.completionIndex, .{}));
    try app.dispatch(h, .{ .key_down = .{ .key = .up } });
    try t.expectEqual(@as(usize, 0), try app.read(owner, Ops.completionIndex, .{}));
    if (comptime ui.testing.native != void) try (try app.window(h)).snapshot("/tmp/zircon-completion.png");
    try app.dispatch(h, .{ .key_down = .{ .key = .enter } });
    _ = try app.step(0);
    var actual: []u8 = undefined;
    try app.read(owner, Ops.source, .{ t.allocator, &actual });
    defer t.allocator.free(actual);
    try t.expectEqualStrings("a🙂answerb", actual);
    try send(&app, h, .undo);
    var undo: []u8 = undefined;
    try app.read(owner, Ops.source, .{ t.allocator, &undo });
    defer t.allocator.free(undo);
    try t.expectEqualStrings("a🙂b", undo);
    try send(&app, h, .extensions);
    try click(&app, h, "Disable");
    try t.expect(try app.read(owner, Ops.stopped, .{}));
}
test "native image viewer decodes a real file without creating a text document" {
    if (comptime ui.testing.native == void) return error.SkipZigTest;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "main.zig", .data = "const n = 1;\n" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "image.png", .data = @embedFile("image_fixture") });
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const h = try open(&app, root, "main.zig");
    const owner = try app.windowEntity(zircon.Shell, h);
    try app.update(owner, Ops.open, .{"image.png"});
    _ = try app.step(0);
    try t.expectEqual(@as(usize, 1), try app.read(owner, Ops.count, .{}));
    var image_drawn = false;
    for ((try app.window(h)).frames.committed.scene.items) |item| if (item.kind == .image) {
        image_drawn = true;
    };
    try t.expect(image_drawn);
    try (try app.window(h)).snapshot("/tmp/zircon-image.png");
    try send(&app, h, .back_to_editor);
    try app.dispatch(h, .{ .text = "// preserved\n" });
    _ = try app.step(0);
    var actual: []u8 = undefined;
    try app.read(owner, Ops.source, .{ t.allocator, &actual });
    defer t.allocator.free(actual);
    try t.expect(std.mem.startsWith(u8, actual, "// preserved\n"));
}
test "Git panel stages unstages commits and shows unsaved gutters and inline blame" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "main.zig", .data = "const value = 1;\n" });
    try tmp.dir.createDir(t.io, "src", .default_dir);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "src/helper.zig", .data = "pub const enabled = false;\n" });
    try command(root, &.{ "init", "-b", "main" });
    try command(root, &.{ "config", "user.email", "fixture@zircon.invalid" });
    try command(root, &.{ "config", "user.name", "Zircon fixture" });
    try command(root, &.{ "add", "main.zig", "src/helper.zig" });
    try command(root, &.{ "commit", "-m", "Initial" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "main.zig", .data = "const value = 2;\n" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "src/helper.zig", .data = "pub const enabled = true;\n" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "src/notes.md", .data = "# Work in progress\n" });
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const h = try open(&app, root, "main.zig");
    const owner = try app.windowEntity(zircon.Shell, h);
    try app.update(owner, Ops.openKeepActive, .{"src/helper.zig"});
    try send(&app, h, .git_changes);
    try settle(&app);
    try click(&app, h, "View diff");
    try settle(&app);
    const AllChanges = struct {
        fn visible(self: *const zircon.Shell) bool {
            return self.git.selected_path.len == 0 and self.git.diff != null and self.git.diff.?.hunks.len == 3;
        }
    };
    try t.expect(try app.read(owner, AllChanges.visible, .{}));
    var commit_disabled = false;
    for ((try app.window(h)).frames.committed.nodes.items) |node| if (node.kind == .button and std.mem.eql(u8, node.kind.button.label, "Commit tracked changes")) {
        commit_disabled = node.kind.button.on_click == null;
    };
    try t.expect(commit_disabled);
    var changed_word = false;
    for ((try app.window(h)).frames.committed.scene.items) |item| if (item.kind == .rect and item.color.a == 0.3 and item.rect.width > 0 and item.rect.width < 40) {
        changed_word = true;
    };
    try t.expect(changed_word);
    if (comptime ui.testing.native != void) try (try app.window(h)).snapshot("/tmp/zircon-git-all.png");
    const before_navigation = try app.read(owner, Ops.gitGeneration, .{});
    try app.update(owner, Ops.gitFile, .{});
    try t.expectEqual(before_navigation, try app.read(owner, Ops.gitGeneration, .{}));
    try settle(&app);
    try t.expect(try app.read(owner, Ops.editableGitSource, .{}));
    try t.expectEqual(@as(usize, 3), try app.read(owner, Ops.editableGitSources, .{}));
    var numbered = false;
    var addition = false;
    for ((try app.window(h)).frames.committed.nodes.items) |node| if (node.kind == .text) {
        if (std.mem.eql(u8, node.kind.text, "1")) numbered = true;

        try t.expect(!std.mem.eql(u8, node.kind.text, "+const value = 2;"));
    };
    for ((try app.window(h)).frames.committed.scene.items) |item| {
        if (item.kind == .text and std.mem.eql(u8, item.text, "2")) addition = true;
    }
    try t.expect(numbered and addition);
    if (comptime ui.testing.native != void) try (try app.window(h)).snapshot("/tmp/zircon-git-changes.png");
    try click(&app, h, "src");
    _ = try app.step(0);
    for ((try app.window(h)).frames.committed.nodes.items) |node| if (node.kind == .button) try t.expect(!std.mem.eql(u8, node.kind.button.label, "src/helper.zig"));
    try click(&app, h, "src");
    _ = try app.step(0);
    try click(&app, h, "Stage main.zig");
    try settle(&app);
    try t.expect(try app.read(owner, Ops.staged, .{}));
    const diff = try git(root, &.{ "diff", "--cached" });
    defer t.allocator.free(diff);
    try t.expect(std.mem.indexOf(u8, diff, "+const value = 2;") != null);
    const Updated = struct {
        fn empty(self: *const zircon.Shell) bool {
            return if (self.git.diff) |value| value.text.len == 0 else false;
        }
    };
    // The combined HEAD-to-worktree view keeps staged changes visible.
    try t.expect(!try app.read(owner, Updated.empty, .{}));
    try send(&app, h, .git_staged_diff);
    try settle(&app);
    try t.expect(!try app.read(owner, Updated.empty, .{}));
    try click(&app, h, "Unstage main.zig");
    try settle(&app);
    try t.expect(!try app.read(owner, Ops.staged, .{}));
    try click(&app, h, "Stage file");
    try settle(&app);
    const field = try elementBounds(&app, h, "commit-message");
    const p: ui.Point = .{ .x = field.x + 15, .y = field.y + 12 };
    try app.dispatch(h, .{ .pointer_down = .{ .position = p } });
    try app.dispatch(h, .{ .pointer_up = .{ .position = p } });
    try app.dispatch(h, .{ .text = "Change value" });
    _ = try app.step(0);
    try click(&app, h, "Commit staged changes");
    try settle(&app);
    const subject = try git(root, &.{ "log", "-1", "--format=%s" });
    defer t.allocator.free(subject);
    try t.expectEqualStrings("Change value\n", subject);
    try command(root, &.{ "commit", "--amend", "-m", "Change value", "-m", "Keep the fixture change documented in the commit body." });
    try send(&app, h, .git_history);
    try settle(&app);
    try app.update(owner, Ops.gitCommit, .{0});
    try settle(&app);
    try app.update(owner, Ops.gitCommit, .{1});
    try settle(&app);
    try t.expectEqual(@as(usize, 2), try app.read(owner, Ops.historyTabs, .{}));
    const History = struct {
        fn tabName(self: *const zircon.Shell, allocator: std.mem.Allocator, out: *[]u8) !void {
            const tab = self.git.history_tabs.items[0];
            out.* = try std.fmt.allocPrint(allocator, "{s} — {s}", .{ tab.oid[0..7], tab.subject });
        }
    };
    var tab_name: []u8 = undefined;
    try app.read(owner, History.tabName, .{ t.allocator, &tab_name });
    defer t.allocator.free(tab_name);
    try click(&app, h, tab_name);
    try settle(&app);
    const tabs_bounds = try elementBounds(&app, h, "tabs");
    var top_tab = false;
    for ((try app.window(h)).frames.committed.nodes.items, 0..) |node, index| if (node.kind == .button and std.mem.eql(u8, node.kind.button.label, tab_name)) {
        const rect = (try app.window(h)).frames.committed.bounds[index];
        top_tab = rect.y >= tabs_bounds.y and rect.y + rect.height <= tabs_bounds.y + tabs_bounds.height + 0.1;
    };
    try t.expect(top_tab);
    try t.expect((try elementBounds(&app, h, "commit-details")).height > 0);

    if (comptime ui.testing.native != void) try (try app.window(h)).snapshot("/tmp/zircon-git-history.png");
    try send(&app, h, .back_to_editor);
    try app.dispatch(h, .{ .text = "// unsaved\n" });
    try settle(&app);
    try t.expect(try app.read(owner, Ops.markers, .{}) > 0);
    const canvas = try elementBounds(&app, h, "primary-editor");
    if (comptime ui.testing.native != void) {
        const path = "/tmp/zircon-git-gutters.png";
        try (try app.window(h)).snapshot(path);
        const encoded = try std.Io.Dir.cwd().readFileAlloc(t.io, path, t.allocator, .limited(8 * 1024 * 1024));
        defer t.allocator.free(encoded);
        var image = try ui.graphics.images.Image.load(t.allocator, encoded);
        defer image.deinit();
        const pixels = image.view();
        const x: usize = @intFromFloat(canvas.x + 5);
        const y: usize = @intFromFloat(canvas.y + 8);
        const pixel = pixels.pixels[(y * pixels.width + x) * 4 ..][0..4];
        inline for (.{ @as(u8, 0x75), @as(u8, 0xb8), @as(u8, 0x8a) }, 0..) |expected, channel| try t.expect(@abs(@as(i16, pixel[channel]) - expected) <= 3);
    }
    const gutter: ui.Point = .{ .x = canvas.x + 6, .y = canvas.y + 28 };
    try app.dispatch(h, .{ .pointer_down = .{ .position = gutter } });
    try app.dispatch(h, .{ .pointer_up = .{ .position = gutter } });
    try settle(&app);
    try send(&app, h, .git_blame);
    try settle(&app);
    try t.expect(try app.read(owner, Ops.blame, .{}));
    if (comptime ui.testing.native != void) try (try app.window(h)).snapshot("/tmp/zircon-inline-blame.png");
    var copy_label = false;
    var author_label = false;
    var body_label = false;
    for ((try app.window(h)).frames.committed.scene.items) |item| if (item.kind == .text) {
        if (std.mem.eql(u8, item.text, "Copy SHA")) copy_label = true;
        if (std.mem.indexOf(u8, item.text, "Keep the fixture change") != null) body_label = true;
        if (std.mem.indexOf(u8, item.text, "fixture@zircon.invalid") != null) author_label = true;
    };
    try t.expect(copy_label and author_label and body_label);
    var copy_rect: ?ui.Rect = null;
    for ((try app.window(h)).frames.committed.scene.items) |item| if (item.kind == .text and std.mem.eql(u8, item.text, "Copy SHA")) {
        copy_rect = item.rect;
    };
    const copy_bounds = copy_rect orelse return error.CopyControlMissing;
    const copy_point: ui.Point = .{ .x = copy_bounds.x + 8, .y = copy_bounds.y + 8 };
    try app.dispatch(h, .{ .pointer_down = .{ .position = copy_point } });
    try app.dispatch(h, .{ .pointer_up = .{ .position = copy_point } });
    var clipboard: ui.Event(ui.Input) = .{ .data = .{ .key_down = .{ .key = .c } }, ._surface = (try app.window(h)).surface };
    const copied = try clipboard.readClipboard(t.allocator);
    defer t.allocator.free(copied);
    const oid = try git(root, &.{ "rev-parse", "HEAD" });
    defer t.allocator.free(oid);
    try t.expectEqualStrings(std.mem.trim(u8, oid, "\n"), copied);
    try app.dispatch(h, .{ .key_down = .{ .key = .escape } });
    _ = try app.step(0);
    try t.expect(!try app.read(owner, Ops.blame, .{}));
    const unsaved: ui.Point = .{ .x = canvas.x + 80, .y = canvas.y + 6 };
    try app.dispatch(h, .{ .pointer_down = .{ .position = unsaved } });
    try app.dispatch(h, .{ .pointer_up = .{ .position = unsaved } });
    try send(&app, h, .git_blame);
    try settle(&app);
    var uncommitted = false;
    for ((try app.window(h)).frames.committed.scene.items) |item| if (item.kind == .text) {
        if (std.mem.eql(u8, item.text, "Uncommitted changes")) uncommitted = true;
        try t.expect(!std.mem.eql(u8, item.text, "Copy SHA"));
    };
    try t.expect(uncommitted);
}
test "extension controls activate real themes icons and syntax" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "sample.py", .data = "def hello():\n    return True\n" });
    const home = try std.fs.path.join(t.allocator, &.{ root, "extensions" });
    defer t.allocator.free(home);
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const h = try open(&app, root, "sample.py");
    const owner = try app.windowEntity(zircon.Shell, h);
    try app.update(owner, Ops.configure, .{home});
    try send(&app, h, .extensions);
    try click(&app, h, "Install Oxide");
    try t.expect(try app.read(owner, Ops.extension, .{}));
    try t.expect(try app.read(owner, Ops.custom, .{}));
    try click(&app, h, "Use Oxide night");
    try click(&app, h, "Use Oxide symbols");
    if (comptime ui.testing.native != void) try (try app.window(h)).snapshot("/tmp/zircon-extensions.png");
    var icon_found = false;
    for ((try app.window(h)).frames.committed.nodes.items) |node| if (node.kind == .button and std.mem.eql(u8, node.kind.button.label, "Py sample.py")) {
        icon_found = true;
    };
    try t.expect(icon_found);
    try click(&app, h, "Disable");
    try t.expect(!try app.read(owner, Ops.custom, .{}));
    try click(&app, h, "Enable");
    try t.expect(try app.read(owner, Ops.custom, .{}));
    try click(&app, h, "Remove");
    try t.expect(!try app.read(owner, Ops.custom, .{}));
}
test "project search captures unsaved buffers and opens the real source selection" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "one.zig", .data = "disk only\n" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "two.zig", .data = "needle two\n" });
    try command(root, &.{"init"});
    try tmp.dir.writeFile(t.io, .{ .sub_path = ".gitignore", .data = "generated.zig\n" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "generated.zig", .data = "needle ignored\n" });
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const h = try open(&app, root, "one.zig");
    const owner = try app.windowEntity(zircon.Shell, h);
    try app.dispatch(h, .{ .text = "needle unsaved\n" });
    try send(&app, h, .project_search);
    try app.dispatch(h, .{ .text = "needle" });
    try app.dispatch(h, .{ .key_down = .{ .key = .enter } });
    try settle(&app);
    try t.expectEqual(@as(usize, 2), try app.read(owner, Ops.matches, .{}));
    if (comptime ui.testing.native != void) try (try app.window(h)).snapshot("/tmp/zircon-project-search.png");
    var opened = false;
    const frame = &(try app.window(h)).frames.committed;
    for (frame.nodes.items) |node| if (node.kind == .button and std.mem.indexOf(u8, node.kind.button.label, "one.zig    1 matches") != null) {
        const label = try t.allocator.dupe(u8, node.kind.button.label);
        defer t.allocator.free(label);
        try click(&app, h, label);
        opened = true;
        break;
    };
    try t.expect(opened);
    // Navigating to a match keeps the search tab and its query/results alive.
    try click(&app, h, "Project search");
    _ = try app.step(0);
    try t.expectEqual(@as(usize, 2), try app.read(owner, Ops.matches, .{}));
    const restored = &(try app.window(h)).frames.committed;
    var match_label: ?[]u8 = null;
    for (restored.nodes.items) |node| if (node.kind == .button and std.mem.indexOf(u8, node.kind.button.label, "one.zig    1 matches") != null) {
        match_label = try t.allocator.dupe(u8, node.kind.button.label);
        break;
    };
    try t.expect(match_label != null);
    defer t.allocator.free(match_label.?);
    try click(&app, h, match_label.?);
    try app.dispatch(h, .{ .text = "edited" });
    _ = try app.step(0);
    var source: []u8 = undefined;
    try app.read(owner, Ops.source, .{ t.allocator, &source });
    defer t.allocator.free(source);
    try t.expectEqualStrings("edited unsaved\ndisk only\n", source);
    try app.update(owner, Ops.setProjectQuery, .{""});
    try send(&app, h, .run_project_search);
    try settle(&app);
    try t.expectEqual(@as(usize, 0), try app.read(owner, Ops.matches, .{}));
}

fn insideTabs(frame: anytype, start: u32) bool {
    var current: ?u32 = start;
    while (current) |index| : (current = frame.nodes.items[index].parent) {
        if (frame.nodes.items[index].key) |key| if (key == .string and std.mem.eql(u8, key.string, "tabs")) return true;
    }
    return false;
}

test "automatic blame waits for the current line and keeps source geometry unchanged" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    try command(root, &.{ "init", "-q" });
    try command(root, &.{ "config", "user.name", "Blame author" });
    try command(root, &.{ "config", "user.email", "author@zircon.invalid" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "main.zig", .data = "const value = 1;\n" });
    try command(root, &.{ "add", "." });
    try command(root, &.{ "commit", "-m", "Initial author" });
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const h = try open(&app, root, "main.zig");
    const owner = try app.windowEntity(zircon.Shell, h);
    try settle(&app);
    _ = try app.step(0.1);
    try t.expect(!try app.read(owner, Ops.blame, .{}));
    _ = try app.step(0.5);
    _ = try app.step(1);
    const deadline = std.Io.Clock.awake.now(t.io).addDuration(.fromSeconds(5));
    while (try app.tasksPending()) {
        _ = try app.step(1);
        if (std.Io.Clock.awake.now(t.io).compare(.gte, deadline)) return error.JourneyTimeout;
        std.Io.sleep(t.io, .fromMilliseconds(1), .awake) catch {};
    }
    _ = try app.step(1);
    const Check = struct {
        fn compact(self: *const zircon.Shell) bool {
            const state = &self.tabs.items[self.active].editor;
            const blame = state.inline_blame orelse return false;
            return !blame.expanded and std.mem.eql(u8, blame.author, "Blame author") and state.rowY(1, blame.revision) == state.line_height;
        }
    };
    try t.expect(try app.read(owner, Check.compact, .{}));
    var annotation = false;
    for ((try app.window(h)).frames.committed.scene.items) |item| if (item.kind == .text and std.mem.indexOf(u8, item.text, "Blame author ·") != null) {
        annotation = true;
    };
    try t.expect(annotation);
    var target: ?ui.Rect = null;
    for ((try app.window(h)).frames.committed.scene.items) |item| if (item.kind == .text and std.mem.indexOf(u8, item.text, "Blame author ·") != null) {
        target = item.rect;
    };
    const rect = target orelse return error.AnnotationNotFound;
    const source_bounds = try elementBounds(&app, h, "primary-editor");
    try t.expectApproxEqAbs(source_bounds.y + 11.2, rect.y + rect.height / 2, 0.01);
    try app.dispatch(h, .{ .pointer_move = .{ .position = .{ .x = rect.x + 10, .y = rect.y + 8 } } });
    const hover_deadline = std.Io.Clock.awake.now(t.io).addDuration(.fromSeconds(5));
    while (try app.tasksPending()) {
        _ = try app.step(1);
        if (std.Io.Clock.awake.now(t.io).compare(.gte, hover_deadline)) return error.JourneyTimeout;
        std.Io.sleep(t.io, .fromMilliseconds(1), .awake) catch {};
    }
    _ = try app.step(1);
    var details = false;
    for ((try app.window(h)).frames.committed.scene.items) |item| if (item.kind == .text and std.mem.eql(u8, item.text, "Copy SHA")) {
        details = true;
    };
    try t.expect(details);
    if (comptime ui.testing.native != void) try (try app.window(h)).snapshot("/tmp/zircon-blame-hover.png");
    try app.dispatch(h, .pointer_leave);
    _ = try app.step(1);
    var remaining_card = false;
    for ((try app.window(h)).frames.committed.scene.items) |item| if (item.kind == .text and std.mem.eql(u8, item.text, "Copy SHA")) {
        remaining_card = true;
    };
    try t.expect(!remaining_card);
}

test "gutter click expands removed lines inline without changing buffer selection or dirty state" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    try command(root, &.{ "init", "-q" });
    try command(root, &.{ "config", "user.name", "Gutter author" });
    try command(root, &.{ "config", "user.email", "gutter@zircon.invalid" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "main.zig", .data = "const a = 1;\nconst b = 2;\nconst c = 5;\n" });
    try command(root, &.{ "add", "." });
    try command(root, &.{ "commit", "-m", "Original lines" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "main.zig", .data = "const a = 3;\nconst b = 4;\nconst c = 5;\n" });
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const h = try open(&app, root, "main.zig");
    const owner = try app.windowEntity(zircon.Shell, h);
    try settle(&app);
    const canvas = try elementBounds(&app, h, "primary-editor");
    const point: ui.Point = .{ .x = canvas.x + 6, .y = canvas.y + 10 };
    try app.dispatch(h, .{ .pointer_down = .{ .position = point } });
    try app.dispatch(h, .{ .pointer_up = .{ .position = point } });
    _ = try app.step(0);
    const Check = struct {
        fn expanded(self: *const zircon.Shell) !bool {
            const tab = self.tabs.items[self.active];
            const state = &tab.editor;
            return state.git_changes.len == 1 and state.git_changes[0].expanded and state.primary().head == 0 and !(try self.workspace.getConst(tab.document)).dirty() and state.rowY(0, state.git_revision) == state.line_height * 2 and std.mem.indexOf(u8, state.git_changes[0].removed, "const a = 1;") != null;
        }
        fn collapsed(self: *const zircon.Shell) bool {
            return !self.tabs.items[self.active].editor.git_changes[0].expanded;
        }
    };
    try t.expect(try app.read(owner, Check.expanded, .{}));
    var removed_number = false;
    var removed_x: ?f32 = null;
    var current_x: ?f32 = null;
    for ((try app.window(h)).frames.committed.scene.items) |item| if (item.kind == .text) {
        if (std.mem.eql(u8, item.text, "1") and item.rect.x >= canvas.x and item.rect.x < canvas.x + 76) {
            if (item.color.r > 0.7 and item.color.g < 0.6) {
                removed_number = true;
                removed_x = item.rect.x;
            } else current_x = item.rect.x;
        }
        try t.expect(!std.mem.eql(u8, item.text, "Copy SHA"));
    };
    try t.expect(removed_number);
    try t.expectApproxEqAbs(current_x orelse return error.MissingLineNumber, removed_x.?, 0.01);
    if (comptime ui.testing.native != void) try (try app.window(h)).snapshot("/tmp/zircon-inline-hunk.png");
    try app.dispatch(h, .{ .pointer_down = .{ .position = point } });
    try app.dispatch(h, .{ .pointer_up = .{ .position = point } });
    _ = try app.step(0);
    try t.expect(try app.read(owner, Check.collapsed, .{}));
}

test "Git controls create branches stash changes and reload clean open documents" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    try command(root, &.{ "init", "-b", "main" });
    try command(root, &.{ "config", "user.name", "Git controls" });
    try command(root, &.{ "config", "user.email", "controls@zircon.invalid" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "main.zig", .data = "const a = 1;\n" });
    try command(root, &.{ "add", "." });
    try command(root, &.{ "commit", "-m", "Initial" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "main.zig", .data = "const a = 2;\n" });
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const h = try open(&app, root, "main.zig");
    const owner = try app.windowEntity(zircon.Shell, h);
    try settle(&app);
    try send(&app, h, .git_changes);
    try settle(&app);
    try click(&app, h, "Change actions");
    _ = try app.step(0);
    try click(&app, h, "Stash tracked");
    try settle(&app);
    const Read = struct {
        fn original(self: *const zircon.Shell) !bool {
            const record = try self.workspace.getConst(self.tabs.items[0].document);
            var snapshot = record.doc.snapshot();
            defer snapshot.deinit();
            const bytes = try snapshot.copy(t.allocator, .{ .start = 0, .end = snapshot.byteLen() });
            defer t.allocator.free(bytes);
            return std.mem.eql(u8, bytes, "const a = 1;\n") and !record.dirty();
        }
        fn branch(self: *const zircon.Shell) bool {
            return self.git.status != null and std.mem.eql(u8, self.git.status.?.branch, "feature/ui");
        }
        fn noStashes(self: *const zircon.Shell) bool {
            return self.git.references != null and self.git.references.?.stashes.len == 0;
        }
    };
    try t.expect(try app.read(owner, Read.original, .{}));
    try send(&app, h, .git_branches);
    try settle(&app);
    try app.dispatch(h, .{ .text = "feature/ui" });
    _ = try app.step(0);
    try app.dispatch(h, .{ .key_down = .{ .key = .enter } });
    try settle(&app);
    try t.expect(try app.read(owner, Read.branch, .{}));
    try send(&app, h, .git_stashes);
    try settle(&app);
    var stash_label: ?[]u8 = null;
    for ((try app.window(h)).frames.committed.nodes.items) |node| if (node.kind == .button and std.mem.indexOf(u8, node.kind.button.label, "Zircon stash") != null) {
        stash_label = try t.allocator.dupe(u8, node.kind.button.label);
        break;
    };
    defer if (stash_label) |label| t.allocator.free(label);
    try click(&app, h, stash_label orelse return error.StashNotShown);
    try settle(&app);
    try click(&app, h, "Pop selected stash");
    try settle(&app);
    try t.expect(try app.read(owner, Read.noStashes, .{}));
    try t.expect(!try app.read(owner, Read.original, .{}));
    try send(&app, h, .back_to_editor);
    _ = try app.step(0);
    try app.dispatch(h, .{ .text = "// unsaved\n" });
    _ = try app.step(0);
    const Refuse = struct {
        fn apply(self: *zircon.Shell, cx: *ui.Context(zircon.Shell)) !void {
            var event: ui.Event(ui.Click) = .{ .data = .{} };
            try self.onCommand(&event, cx, .git_stash_all);
        }
    };
    try app.update(owner, Refuse.apply, .{});
    try t.expect((try app.window(h)).frames.committed.root != null);
    const Error = struct {
        fn refused(self: *const zircon.Shell) bool {
            return self.status_is_error and std.mem.indexOf(u8, self.status, "Save your edited files") != null;
        }
    };
    try t.expect(try app.read(owner, Error.refused, .{}));
}

test "light Markdown code keeps theme colors indentation and long tokens inside a narrow preview" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "note.md", .data = "```zig\n    const long_identifier_that_needs_to_wrap_in_a_narrow_preview_without_clipping = \"A long string with 日 and 🙂 that also wraps inside the code background\";\n```\n" });
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const h = try open(&app, root, "note.md");
    const owner = try app.windowEntity(zircon.Shell, h);
    const Theme = struct {
        fn light(self: *zircon.Shell, cx: *ui.Context(zircon.Shell)) !void {
            try cx.update(self.settings.?, zircon.Settings.apply, .{zircon.SettingsPatch{ .theme = "zircon.light" }});
        }
        fn keyword(self: *const zircon.Shell) ui.Color {
            return self.editor_options.theme.tokens[1];
        }
    };
    try app.update(owner, Theme.light, .{});
    try send(&app, h, .markdown_preview);
    _ = try app.step(0);
    const bounds = try elementBounds(&app, h, "markdown-preview");
    const keyword = try app.read(owner, Theme.keyword, .{});
    var found = false;
    for ((try app.window(h)).frames.committed.scene.items) |item| if (item.kind == .text and item.rect.x >= bounds.x and item.rect.y >= bounds.y and item.rect.y < bounds.y + bounds.height) {
        if (std.mem.eql(u8, item.text, "const")) {
            found = true;
            try t.expect(std.meta.eql(item.color, keyword));
            try t.expect(item.rect.x >= bounds.x + 60);
        }
        try t.expect(item.rect.x + item.rect.width <= bounds.x + bounds.width - 20 + 0.1);
    };
    try t.expect(found);
    if (comptime ui.testing.native != void) try (try app.window(h)).snapshot("/tmp/zircon-markdown-code-wrap-light.png");
}

test "Git diff edits live files directly and uses source undo save and redo" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "main.zig", .data = "const value = 1;\n" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "helper.zig", .data = "pub const enabled = false;\n" });
    try command(root, &.{ "init", "-b", "main" });
    try command(root, &.{ "config", "user.email", "fixture@zircon.invalid" });
    try command(root, &.{ "config", "user.name", "Zircon fixture" });
    try command(root, &.{ "add", "." });
    try command(root, &.{ "commit", "-m", "Initial" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "main.zig", .data = "const value = 2;\n" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "helper.zig", .data = "pub const enabled = true;\n" });
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const h = try open(&app, root, "main.zig");
    const owner = try app.windowEntity(zircon.Shell, h);
    try send(&app, h, .git_changes);
    try settle(&app);
    const row = try elementBounds(&app, h, "git-live:main.zig:1");
    const point: ui.Point = .{ .x = row.x + 120, .y = row.y + row.height / 2 };
    try app.dispatch(h, .{ .pointer_down = .{ .position = point } });
    try app.dispatch(h, .{ .pointer_up = .{ .position = point } });
    _ = try app.step(0);
    try app.dispatch(h, .{ .key_down = .{ .key = .home } });
    try app.dispatch(h, .{ .text = "// from Git\n" });
    try app.dispatch(h, .{ .text = "// still typing\n" });
    try settle(&app);
    var actual: []u8 = undefined;
    try app.read(owner, Ops.sourceBySuffix, .{ "main.zig", t.allocator, &actual });
    defer t.allocator.free(actual);
    try t.expectEqualStrings("// from Git\n// still typing\nconst value = 2;\n", actual);
    const disk = try tmp.dir.readFileAlloc(t.io, "main.zig", t.allocator, .limited(1000));
    defer t.allocator.free(disk);
    try t.expectEqualStrings("const value = 2;\n", disk);
    try t.expect((try elementBounds(&app, h, "git-live:main.zig:3")).height > 0);
    try send(&app, h, .undo);
    try settle(&app);
    var undone: []u8 = undefined;
    try app.read(owner, Ops.sourceBySuffix, .{ "main.zig", t.allocator, &undone });
    defer t.allocator.free(undone);
    try t.expectEqualStrings("const value = 2;\n", undone);
    try send(&app, h, .redo);
    try settle(&app);
    try send(&app, h, .save);
    try settle(&app);
    const saved = try tmp.dir.readFileAlloc(t.io, "main.zig", t.allocator, .limited(1000));
    defer t.allocator.free(saved);
    try t.expectEqualStrings(actual, saved);
    if (comptime ui.testing.native != void) try (try app.window(h)).snapshot("/tmp/zircon-editable-git.png");
}

test "Git multibuffer drags across source rows survives redraw and edits either split side safely" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "main.zig", .data = "const a = 1;\nconst b = 2;\nconst c = 3;\n" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "helper.zig", .data = "const helper = false;\n" });
    try command(root, &.{ "init", "-b", "main" });
    try command(root, &.{ "config", "user.email", "fixture@zircon.invalid" });
    try command(root, &.{ "config", "user.name", "Zircon fixture" });
    try command(root, &.{ "add", "." });
    try command(root, &.{ "commit", "-m", "Initial" });
    const initial = "const a = 4;\nconst b = 5;\nconst c = 6;\n";
    try tmp.dir.writeFile(t.io, .{ .sub_path = "main.zig", .data = initial });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "helper.zig", .data = "const helper = true;\n" });
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const h = try open(&app, root, "main.zig");
    const owner = try app.windowEntity(zircon.Shell, h);
    try send(&app, h, .git_changes);
    try settle(&app);
    try t.expectEqual(@as(usize, 2), try app.read(owner, Ops.editableGitSources, .{}));
    var source_canvases: usize = 0;
    var copy_added = false;
    var copy_deleted = false;
    for ((try app.window(h)).frames.committed.nodes.items) |node| {
        if (node.key) |key| if (key == .string and std.mem.startsWith(u8, key.string, "git-excerpt:")) {
            source_canvases += 1;
        };
        if (node.kind == .button) {
            copy_added = copy_added or std.mem.eql(u8, node.kind.button.label, "Copy added lines");
            copy_deleted = copy_deleted or std.mem.eql(u8, node.kind.button.label, "Copy deleted lines");
        }
    }
    try t.expect(source_canvases >= 2);
    try t.expect(!copy_added and !copy_deleted);
    const first = try elementBounds(&app, h, "git-live:main.zig:1");
    const begin: ui.Point = .{ .x = first.x + 76, .y = first.y + first.height / 2 };
    try app.dispatch(h, .{ .pointer_down = .{ .position = begin } });
    _ = try app.step(0);
    const third = try elementBounds(&app, h, "git-live:main.zig:3");
    const end: ui.Point = .{ .x = third.x + 76, .y = third.y + third.height / 2 };
    try app.dispatch(h, .{ .pointer_move = .{ .position = end } });
    _ = try app.step(0);
    try app.dispatch(h, .{ .pointer_up = .{ .position = end } });
    const Check = struct {
        fn selection(self: *const zircon.Shell) bool {
            const view = self.git.editing.current() orelse return false;
            const range = view.editor.primary().range();
            return range.start == 0 and range.end == "const a = 4;\nconst b = 5;\n".len and !view.editor.dragging;
        }
    };
    try t.expect(try app.read(owner, Check.selection, .{}));
    try app.dispatch(h, .{ .text = "// replacement\n" });
    try settle(&app);
    var actual: []u8 = undefined;
    try app.read(owner, Ops.sourceBySuffix, .{ "main.zig", t.allocator, &actual });
    defer t.allocator.free(actual);
    try t.expectEqualStrings("// replacement\nconst c = 6;\n", actual);
    try app.dispatch(h, .{ .action = @backingInt(zircon.Command.undo) });
    try settle(&app);
    try app.dispatch(h, .{ .action = @backingInt(zircon.Command.git_split_view) });
    _ = try app.step(0);
    const split_row = try elementBounds(&app, h, "git-live:main.zig:1");
    const surface = try elementBounds(&app, h, "git-diff-lines");
    if (comptime ui.testing.native != void) try (try app.window(h)).snapshot("/tmp/zircon-git-split-inspect.png");
    try t.expect(split_row.x > surface.x + surface.width * 0.45);
    const old_point: ui.Point = .{ .x = surface.x + 90, .y = split_row.y + split_row.height / 2 };
    try app.dispatch(h, .{ .pointer_down = .{ .position = old_point } });
    try app.dispatch(h, .{ .pointer_up = .{ .position = old_point } });
    try app.dispatch(h, .{ .text = "must not edit" });
    try app.dispatch(h, .{ .action = @backingInt(zircon.Command.undo) });
    try settle(&app);
    var readonly: []u8 = undefined;
    try app.read(owner, Ops.sourceBySuffix, .{ "main.zig", t.allocator, &readonly });
    defer t.allocator.free(readonly);
    try t.expectEqualStrings(initial, readonly);
    const current = try elementBounds(&app, h, "git-live:main.zig:1");
    const current_point: ui.Point = .{ .x = current.x + 76, .y = current.y + current.height / 2 };
    try app.dispatch(h, .{ .pointer_down = .{ .position = current_point } });
    try app.dispatch(h, .{ .pointer_up = .{ .position = current_point } });
    try app.dispatch(h, .{ .key_down = .{ .key = .home } });
    try app.dispatch(h, .{ .text = "// split edit\n" });
    try settle(&app);
    try app.dispatch(h, .{ .action = @backingInt(zircon.Command.save) });
    try settle(&app);
    const saved = try tmp.dir.readFileAlloc(t.io, "main.zig", t.allocator, .limited(1000));
    defer t.allocator.free(saved);
    try t.expectEqualStrings("// split edit\n" ++ initial, saved);
    const sibling = try tmp.dir.readFileAlloc(t.io, "helper.zig", t.allocator, .limited(1000));
    defer t.allocator.free(sibling);
    try t.expectEqualStrings("const helper = true;\n", sibling);
    if (comptime ui.testing.native != void) try (try app.window(h)).snapshot("/tmp/zircon-git-multibuffer-split.png");
}

test "platform menus dispatch commands without duplicating a menu bar in the window" {
    try menuJourney(false);
}

fn reviewPoint(app: *ui.App, h: ui.WindowHandle, key: []const u8, line: []const u8, at: usize) !ui.Point {
    const bounds = try elementBounds(app, h, key);
    const event: ui.Event(ui.Input) = .{ .data = .{ .text = "" }, ._surface = (try app.window(h)).surface };
    const metrics = try event.textMetrics();
    return .{ .x = bounds.x + 76 + metrics.caret(line, .{ .size = 14, .mono = true }, at), .y = bounds.y + bounds.height / 2 };
}

fn reviewDrag(app: *ui.App, h: ui.WindowHandle, from: ui.Point, to: ui.Point) !void {
    try app.dispatch(h, .{ .pointer_down = .{ .position = from } });
    _ = try app.step(0);
    try app.dispatch(h, .{ .pointer_move = .{ .position = to } });
    _ = try app.step(0);
    try app.dispatch(h, .{ .pointer_up = .{ .position = to } });
    _ = try app.step(0);
}

fn expectClipboard(app: *ui.App, h: ui.WindowHandle, expected: []const u8) !void {
    const event: ui.Event(ui.Input) = .{ .data = .{ .text = "" }, ._surface = (try app.window(h)).surface };
    const bytes = try event.readClipboard(t.allocator);
    defer t.allocator.free(bytes);
    try t.expectEqualStrings(expected, bytes);
}

fn reviewRepo(root: []const u8) !void {
    try command(root, &.{ "init", "-b", "main" });
    try command(root, &.{ "config", "user.email", "fixture@zircon.invalid" });
    try command(root, &.{ "config", "user.name", "Zircon fixture" });
    try command(root, &.{ "add", "." });
    try command(root, &.{ "commit", "-m", "Initial" });
}

const CanvasCheck = enum { gutter, active_tint, context_controls, input_focus, added_input_focus, split_input_focus, wrapping, split_wrapping, highlighting };
fn gitCanvasJourney(comptime check: CanvasCheck) !void {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const before = "// zero\n// one\n// two\n// three\nconst context = 1;\nconst changed = false;\n// six\n// seven\n// eight\n// nine\n// ten\n// eleven\n";
    try tmp.dir.writeFile(t.io, .{ .sub_path = "main.zig", .data = before });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "other.zig", .data = "const inactive = false;\n" });
    try reviewRepo(root);
    const segment = "a very long string with multiple words and enough characters to wrap in a narrow editor viewport ";
    const long = "const changed = \"" ++ segment ++ segment ++ segment ++ segment ++ segment ++ segment ++ segment ++ segment ++ "\";";
    try tmp.dir.writeFile(t.io, .{ .sub_path = "main.zig", .data = "// zero\n// one\n// two\n// three\nconst context = 1;\n" ++ long ++ "\n// six\n// seven\n// eight\n// nine\n// ten\n// eleven\n" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "other.zig", .data = "const inactive = true;\n" });
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const title = "Zircon Git canvas " ++ @tagName(check);
    const h = try openNamed(&app, root, "main.zig", title);
    const owner = try app.windowEntity(zircon.Shell, h);
    const Settings = struct {
        fn wrap(self: *zircon.Shell, cx: *ui.Context(zircon.Shell)) !void {
            self.git.editing.horizontal = 80;
            try cx.update(self.settings.?, zircon.Settings.apply, .{zircon.SettingsPatch{ .soft_wrap = .editor_width }});
        }
        fn lineHeight(self: *const zircon.Shell) f32 {
            return self.editor_options.font_size * self.editor_options.line_height;
        }
        fn added(self: *const zircon.Shell) ui.Color {
            return self.editor_options.theme.git_added;
        }
    };
    if (check == .wrapping or check == .split_wrapping) try app.update(owner, Settings.wrap, .{});
    if (check == .split_input_focus) try send(&app, h, .split_right);
    try send(&app, h, .git_diff_all);
    try settle(&app);
    if (check == .split_wrapping) try send(&app, h, .git_split_view);
    const lh = try app.read(owner, Settings.lineHeight, .{});
    switch (check) {
        .gutter => {
            const bounds = try elementBounds(&app, h, "git-live:main.zig:6");
            const color = try app.read(owner, Settings.added, .{});
            var found = false;
            for ((try app.window(h)).frames.committed.scene.items) |item| {
                if (item.kind == .rect and std.meta.eql(item.color, color) and @abs(item.rect.x - bounds.x) < 1 and item.rect.width == 6 and item.rect.y <= bounds.y and item.rect.y + item.rect.height >= bounds.y + lh - 1) found = true;
            }
            try t.expect(found);
        },
        .active_tint => {
            try app.dispatch(h, .{ .focus = true });
            const point = try reviewPoint(&app, h, "git-live:main.zig:6", long, 0);
            try reviewDrag(&app, h, point, point);
            const bounds = try elementBounds(&app, h, "git-live:main.zig:6");
            const Read = struct {
                fn active(self: *const zircon.Shell) ui.Color {
                    return self.editor_options.theme.active_line;
                }
            };
            const active = try app.read(owner, Read.active, .{});
            var subtle = false;
            for ((try app.window(h)).frames.committed.scene.items) |item| {
                if (item.kind == .rect and item.rect.y >= bounds.y and item.rect.y < bounds.y + lh and item.rect.width >= bounds.width - 1 and item.color.r == active.r and item.color.g == active.g and item.color.b == active.b) {
                    subtle = item.color.a > 0 and item.color.a <= 0.2;
                }
            }
            try t.expect(subtle);
        },
        .context_controls => {
            for ((try app.window(h)).frames.committed.scene.items) |item| if (item.kind == .text) try t.expect(!std.mem.startsWith(u8, item.text, "@@"));
            var found = false;
            for ((try app.window(h)).frames.committed.nodes.items) |node| if (node.kind == .button and std.mem.indexOf(u8, node.kind.button.label, "Expand context") != null) {
                found = true;
            };
            try t.expect(found);
            try click(&app, h, "Expand context above main.zig");
            const expanded = try reviewPoint(&app, h, "git-live:main.zig:1", "// zero", 0);
            try reviewDrag(&app, h, expanded, expanded);
            try app.dispatch(h, .{ .text = "// expanded context\n" });
            try settle(&app);
            var actual: []u8 = undefined;
            try app.read(owner, Ops.sourceBySuffix, .{ "main.zig", t.allocator, &actual });
            defer t.allocator.free(actual);
            try t.expect(std.mem.startsWith(u8, actual, "// expanded context\n// zero\n"));
            try t.expect((try elementBounds(&app, h, "git-live:main.zig:1")).height > 0);
        },
        .input_focus, .added_input_focus, .split_input_focus => {
            try app.dispatch(h, .{ .focus = true });
            const point = if (check == .added_input_focus) try reviewPoint(&app, h, "git-live:main.zig:6", long, 0) else try reviewPoint(&app, h, "git-live:main.zig:5", "const context = 1;", 0);
            try reviewDrag(&app, h, point, point);
            try t.expect((try app.window(h)).frames.committed.text_input != null);
            if (comptime ui.testing.native != void) {
                const objc = ui.testing.native.objc;
                const nsapp = objc.send(objc.Id, objc.class("NSApplication"), "sharedApplication", .{});
                const windows = objc.send(objc.Id, nsapp, "windows", .{});
                var target: objc.Id = null;
                for (0..objc.send(usize, windows, "count", .{})) |index| {
                    const candidate = objc.send(objc.Id, windows, "objectAtIndex:", .{index});
                    if (std.mem.eql(u8, title, objc.fromString(objc.send(objc.Id, candidate, "title", .{})))) target = candidate;
                }
                const window = target orelse return error.CanvasWindowMissing;
                const number = objc.send(isize, window, "windowNumber", .{});
                const event = objc.send(objc.Id, objc.class("NSEvent"), "keyEventWithType:location:modifierFlags:timestamp:windowNumber:context:characters:charactersIgnoringModifiers:isARepeat:keyCode:", .{ @as(usize, 10), objc.CGPoint{}, @as(usize, 0), ui.testing.native.now(), number, @as(objc.Id, null), objc.string("x"), objc.string("x"), false, @as(u16, 7) });
                objc.send(void, window, "sendEvent:", .{event});
                for (0..32) |_| try ui.testing.native.pump(0);
                _ = try app.step(0);
                var typed: []u8 = undefined;
                try app.read(owner, Ops.sourceBySuffix, .{ "main.zig", t.allocator, &typed });
                defer t.allocator.free(typed);
                try t.expect(std.mem.indexOf(u8, typed, if (check == .added_input_focus) "xconst changed" else "xconst context") != null);
            }
            try app.dispatch(h, .{ .text = "// typed in Git\n" });
            try settle(&app);
            var actual: []u8 = undefined;
            try app.read(owner, Ops.sourceBySuffix, .{ "main.zig", t.allocator, &actual });
            defer t.allocator.free(actual);
            try t.expect(std.mem.indexOf(u8, actual, if (check == .added_input_focus) "// typed in Git\nconst changed" else "// typed in Git\nconst context") != null);
        },
        .wrapping, .split_wrapping => {
            const bounds = try elementBounds(&app, h, "git-live:main.zig:6");
            try t.expect(bounds.height >= lh * 2);
            if (check == .split_wrapping) {
                const area = try elementBounds(&app, h, "git-diff-lines");
                try t.expect(bounds.x > area.x + area.width * 0.45);
            }
            if (comptime ui.testing.native != void) try (try app.window(h)).snapshot(if (check == .split_wrapping) "/tmp/zircon-git-canvas-split-wrap.png" else "/tmp/zircon-git-canvas-wrap.png");
            const Read = struct {
                fn continuation(self: *const zircon.Shell, index: usize, source_offset: *usize) !void {
                    const review = self.git.review.?;
                    const record = try self.workspace.getConst(self.tabs.items[self.active].document);
                    var snapshot = record.doc.snapshot();
                    defer snapshot.deinit();
                    for (review.rows) |row| if (std.mem.eql(u8, row.path, "main.zig") and row.original.new_line == 6) {
                        const part = row.segments[index];
                        source_offset.* = try snapshot.lineStart(5) + part.start;
                        return;
                    };
                    return error.WrappedRowMissing;
                }
                fn caret(self: *const zircon.Shell, expected: usize) !void {
                    try t.expectEqual(expected, self.git.editing.current().?.editor.primary().head);
                }
                fn wrapWidth(self: *const zircon.Shell) f32 {
                    return self.git.editing.current().?.editor.wrap_cache.width;
                }
            };
            var offset: usize = 0;
            try app.read(owner, Read.continuation, .{ 1, &offset });
            const point: ui.Point = .{ .x = bounds.x + 76 + @as(f32, 0.1), .y = bounds.y + lh * 1.5 };
            try reviewDrag(&app, h, point, point);
            try app.read(owner, Read.caret, .{offset});
            var next_offset: usize = 0;
            try app.read(owner, Read.continuation, .{ 2, &next_offset });
            try app.dispatch(h, .{ .key_down = .{ .key = .down } });
            _ = try app.step(0);
            try app.read(owner, Read.caret, .{next_offset});
            try app.dispatch(h, .{ .key_down = .{ .key = .up } });
            _ = try app.step(0);
            try app.read(owner, Read.caret, .{offset});
            const wrap_width = try app.read(owner, Read.wrapWidth, .{});
            try app.dispatch(h, .{ .text = "X" });
            try t.expectEqual(wrap_width, try app.read(owner, Read.wrapWidth, .{}));
            try settle(&app);
            var actual: []u8 = undefined;
            try app.read(owner, Ops.sourceBySuffix, .{ "main.zig", t.allocator, &actual });
            defer t.allocator.free(actual);
            try t.expectEqual(@as(u8, 'X'), actual[offset]);
            try app.dispatch(h, .{ .resize = .{ .width = 700, .height = 760 } });
            _ = try app.step(0);
            const narrower = try elementBounds(&app, h, "git-live:main.zig:6");
            try t.expect(narrower.height > bounds.height);
        },
        .highlighting => {
            const bounds = try elementBounds(&app, h, "git-live:other.zig:1");
            var token = false;
            for ((try app.window(h)).frames.committed.scene.items) |item| {
                if (item.kind == .text and item.rect.y >= bounds.y and item.rect.y < bounds.y + bounds.height and std.mem.eql(u8, item.text, "const")) token = true;
            }
            try t.expect(token);
        },
    }
}

test "Git canvas schedules extension highlighting for inactive sources" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(t.io, "project");
    try tmp.dir.createDirPath(t.io, "extensions/org.zircon.git-grammar");
    const fixture = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(fixture);
    const root = try std.fs.path.join(t.allocator, &.{ fixture, "project" });
    defer t.allocator.free(root);
    for ([_][]const u8{ "project/a.retry", "project/b.retry" }) |path|
        try tmp.dir.writeFile(t.io, .{ .sub_path = path, .data = "before\n" });
    try reviewRepo(root);
    for ([_][]const u8{ "project/a.retry", "project/b.retry" }) |path|
        try tmp.dir.writeFile(t.io, .{ .sub_path = path, .data = "after\n" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "extensions/org.zircon.git-grammar/extension.json", .data =
        \\{"schema_version":1,"id":"org.zircon.git-grammar","name":"Git grammar","version":"1.0.0","contributes":{"languages":[{"id":"retry","name":"Retry","extensions":["retry"],"grammar":{"builtin":true,"name":"retry","wasm":"","highlights":""}}]}}
    });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "worker.py", .data =
        \\#!/usr/bin/env python3
        \\import json, sys
        \\source = sys.stdin.buffer.read()
        \\print(json.dumps({'bytes': len(source), 'spans': [{'start': 0, 'end': 5, 'kind': 'keyword'}]}))
        \\
    });
    const worker_file = try tmp.dir.openFile(t.io, "worker.py", .{});
    defer worker_file.close(t.io);
    try worker_file.setPermissions(t.io, .fromMode(0o755));
    const worker = try std.fs.path.join(t.allocator, &.{ fixture, "worker.py" });
    defer t.allocator.free(worker);
    const extensions = try std.fs.path.join(t.allocator, &.{ fixture, "extensions" });
    defer t.allocator.free(extensions);
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const h = try open(&app, root, "a.retry");
    const owner = try app.windowEntity(zircon.Shell, h);
    const Check = struct {
        fn configure(self: *zircon.Shell, cx: *ui.Context(zircon.Shell), home: []const u8, executable: []const u8) !void {
            self.extension_host_path = executable;
            try self.loadExtensions(cx, home);
        }
        fn highlighted(self: *const zircon.Shell) bool {
            if (self.git.editing.views.items.len != 2) return false;
            for (self.git.editing.views.items) |view| {
                const record = self.workspace.getConst(view.document) catch return false;
                if (view.editor.grammar_revision != record.doc.revision()) return false;
            }
            return true;
        }
        fn ready(self: *const zircon.Shell) !void {
            try t.expectEqual(@as(usize, 2), self.git.editing.views.items.len);
            for (self.git.editing.views.items) |view| {
                const record = try self.workspace.getConst(view.document);
                try t.expectEqual(@as(?u64, record.doc.revision()), view.editor.grammar_revision);
                try t.expectEqual(@as(usize, 1), view.editor.grammar_spans.len);
                try t.expectEqual(.keyword, view.editor.grammar_spans[0].kind);
            }
            try t.expect(self.git.editing.active == null);
        }
    };
    try app.update(owner, Check.configure, .{ extensions, worker });
    try send(&app, h, .git_diff_all);
    try settle(&app);
    const deadline = std.Io.Clock.awake.now(t.io).addDuration(.fromSeconds(5));
    var now: f64 = 1;
    while (!try app.read(owner, Check.highlighted, .{})) {
        if (std.Io.Clock.awake.now(t.io).compare(.gte, deadline)) {
            try app.read(owner, Check.ready, .{});
            return error.GitGrammarTimeout;
        }
        _ = try app.step(now);
        now += 0.02;
        try std.Io.sleep(t.io, .fromMilliseconds(1), .awake);
    }
    try app.read(owner, Check.ready, .{});
}

test "Git canvas added gutter matches the source editor" {
    try gitCanvasJourney(.gutter);
}
test "Git canvas replaces patch headers with context expansion controls" {
    try gitCanvasJourney(.context_controls);
}
test "Git canvas context click provides native text input before typing" {
    try gitCanvasJourney(.input_focus);
}
test "Git canvas added line accepts native input on first click" {
    try gitCanvasJourney(.added_input_focus);
}
test "Git canvas split wrapping preserves continuation editing and navigation" {
    try gitCanvasJourney(.split_wrapping);
}
test "Git canvas in a split pane retains native input focus" {
    try gitCanvasJourney(.split_input_focus);
}
test "Git canvas word wrap grows the displayed row" {
    try gitCanvasJourney(.wrapping);
}
test "Git canvas highlights inactive source excerpts before clicking" {
    try gitCanvasJourney(.highlighting);
}

test "Git review selects deleted and mixed text through normal clipboard without modifying sources" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const original = "const a = 1;\nconst b = 2;\nconst c = 3;\n";
    const current = "const a = 4;\nconst b = 5;\nconst c = 6;\n";
    try tmp.dir.writeFile(t.io, .{ .sub_path = "main.zig", .data = original });
    try reviewRepo(root);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "main.zig", .data = current });
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const h = try open(&app, root, "main.zig");
    const owner = try app.windowEntity(zircon.Shell, h);
    try send(&app, h, .git_diff_all);
    try settle(&app);
    const word_start = try reviewPoint(&app, h, "git-code:unified:0:0", "const a = 1;", 6);
    const word_end = try reviewPoint(&app, h, "git-code:unified:0:0", "const a = 1;", 11);
    try reviewDrag(&app, h, word_start, word_end);
    const Theme = struct {
        fn selection(self: *const zircon.Shell) ui.Color {
            return self.editor_options.theme.selection;
        }
    };
    const selection_color = try app.read(owner, Theme.selection, .{});
    const old_bounds = try elementBounds(&app, h, "git-code:unified:0:0");
    var painted = false;
    for ((try app.window(h)).frames.committed.scene.items) |item| {
        if (item.kind == .rect and std.meta.eql(item.color, selection_color) and item.rect.width > 0 and item.rect.y >= old_bounds.y and item.rect.y < old_bounds.y + old_bounds.height) painted = true;
    }
    try t.expect(painted);
    try app.dispatch(h, .{ .key_down = .{ .key = .c, .modifiers = .{ .command = true } } });
    try expectClipboard(&app, h, "a = 1");
    try app.dispatch(h, .{ .key_down = .{ .key = .left, .modifiers = .{ .command = true } } });
    try app.dispatch(h, .{ .key_down = .{ .key = .right, .modifiers = .{ .shift = true } } });
    try app.dispatch(h, .{ .key_down = .{ .key = .c, .modifiers = .{ .command = true } } });
    try expectClipboard(&app, h, "c");
    // Reverse drag across two deleted lines, rebuilding the frame in between.
    const first = try reviewPoint(&app, h, "git-code:unified:0:0", "const a = 1;", 0);
    const third = try reviewPoint(&app, h, "git-code:unified:0:2", "const c = 3;", 0);
    try reviewDrag(&app, h, third, first);
    try app.dispatch(h, .{ .action = @backingInt(zircon.Command.copy) });
    try expectClipboard(&app, h, "const a = 1;\nconst b = 2;\n");
    try app.dispatch(h, .{ .text = "must not modify" });
    try app.dispatch(h, .{ .key_down = .{ .key = .backspace } });
    try send(&app, h, .cut);
    try send(&app, h, .paste);
    try send(&app, h, .undo);
    var source: []u8 = undefined;
    try app.read(owner, Ops.sourceBySuffix, .{ "main.zig", t.allocator, &source });
    defer t.allocator.free(source);
    try t.expectEqualStrings(current, source);
    try send(&app, h, .select_all);
    try send(&app, h, .copy);
    try expectClipboard(&app, h, original ++ current);
    try app.dispatch(h, .{ .text = "mixed selection must not edit" });
    try send(&app, h, .save);
    try settle(&app);
    const disk = try tmp.dir.readFileAlloc(t.io, "main.zig", t.allocator, .limited(1000));
    defer t.allocator.free(disk);
    try t.expectEqualStrings(current, disk);
    if (comptime ui.testing.native != void) try (try app.window(h)).snapshot("/tmp/zircon-git-review-deleted-selection.png");
    try send(&app, h, .git_stage_all);
    try settle(&app);
    try send(&app, h, .git_staged_diff);
    try settle(&app);
    try send(&app, h, .select_all);
    try app.dispatch(h, .{ .action = @backingInt(zircon.Command.copy) });
    try expectClipboard(&app, h, original ++ current);
    try app.dispatch(h, .{ .text = "must not edit index" });
    try send(&app, h, .cut);
    const index = try git(root, &.{ "show", ":main.zig" });
    defer t.allocator.free(index);
    try t.expectEqualStrings(current, index);
}

test "Git review split selection stays on its side and edits across live files with one undo" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "one.txt", .data = "old one\n" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "two.txt", .data = "old two\n" });
    try reviewRepo(root);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "one.txt", .data = "new one\n" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "two.txt", .data = "new two\n" });
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const h = try open(&app, root, "one.txt");
    const owner = try app.windowEntity(zircon.Shell, h);
    try send(&app, h, .git_diff_all);
    try settle(&app);
    try send(&app, h, .git_split_view);
    const old = try reviewPoint(&app, h, "git-code:old:0:0", "old one", 0);
    const new = try reviewPoint(&app, h, "git-live:one.txt:1", "new one", 7);
    try reviewDrag(&app, h, old, new);
    try send(&app, h, .copy);
    try expectClipboard(&app, h, "old one");
    try reviewDrag(&app, h, new, new);
    try send(&app, h, .select_all);
    try send(&app, h, .copy);
    try expectClipboard(&app, h, "new one\nnew two\n");
    try send(&app, h, .cut);
    try settle(&app);
    var first: []u8 = undefined;
    try app.read(owner, Ops.sourceBySuffix, .{ "one.txt", t.allocator, &first });
    defer t.allocator.free(first);
    var second: []u8 = undefined;
    try app.read(owner, Ops.sourceBySuffix, .{ "two.txt", t.allocator, &second });
    defer t.allocator.free(second);
    try t.expectEqualStrings("", first);
    try t.expectEqualStrings("", second);
    try send(&app, h, .undo);
    try settle(&app);
    var restored_first: []u8 = undefined;
    try app.read(owner, Ops.sourceBySuffix, .{ "one.txt", t.allocator, &restored_first });
    defer t.allocator.free(restored_first);
    var restored_second: []u8 = undefined;
    try app.read(owner, Ops.sourceBySuffix, .{ "two.txt", t.allocator, &restored_second });
    defer t.allocator.free(restored_second);
    try t.expectEqualStrings("new one\n", restored_first);
    try t.expectEqualStrings("new two\n", restored_second);
}

test "Git review historical selection copies commit text and survives switching tabs" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "main.txt", .data = "before\n" });
    try reviewRepo(root);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "main.txt", .data = "committed\n" });
    try command(root, &.{ "add", "." });
    try command(root, &.{ "commit", "-m", "Change" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "main.txt", .data = "today\n" });
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const h = try open(&app, root, "main.txt");
    const owner = try app.windowEntity(zircon.Shell, h);
    try send(&app, h, .git_history);
    try settle(&app);
    try app.update(owner, Ops.gitCommit, .{@as(u32, 0)});
    try settle(&app);
    const first = try reviewPoint(&app, h, "git-code:unified:0:0", "before", 0);
    const end = try reviewPoint(&app, h, "git-live:main.txt:1", "committed", 9);
    try reviewDrag(&app, h, first, end);
    try app.dispatch(h, .{ .action = @backingInt(zircon.Command.copy) });
    try expectClipboard(&app, h, "before\ncommitted");
    try send(&app, h, .paste);
    try app.dispatch(h, .{ .text = "must stay historical" });
    const History = struct {
        fn working(self: *zircon.Shell, cx: *ui.Context(zircon.Shell)) void {
            self.git.showWorking();
            cx.notify();
        }
        fn history(self: *zircon.Shell, cx: *ui.Context(zircon.Shell)) !void {
            var event: ui.Event(ui.Click) = .{ .data = .{} };
            try self.onGitHistoryTab(&event, cx, 0);
        }
    };
    try app.update(owner, History.working, .{});
    _ = try app.step(0);
    try app.update(owner, History.history, .{});
    _ = try app.step(0);
    try send(&app, h, .copy);
    try expectClipboard(&app, h, "before\ncommitted");
    var source: []u8 = undefined;
    try app.read(owner, Ops.sourceBySuffix, .{ "main.txt", t.allocator, &source });
    defer t.allocator.free(source);
    try t.expectEqualStrings("today\n", source);
    if (comptime ui.testing.native != void) try (try app.window(h)).snapshot("/tmp/zircon-git-review-history-selection.png");
}

test "Git review captured drag autoscrolls without more pointer movement and stops on release" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    var before: std.ArrayList(u8) = .empty;
    defer before.deinit(t.allocator);
    var after: std.ArrayList(u8) = .empty;
    defer after.deinit(t.allocator);
    for (0..200) |index| {
        try before.print(t.allocator, "old {d}\n", .{index});
        try after.print(t.allocator, "new {d}\n", .{index});
    }
    try tmp.dir.writeFile(t.io, .{ .sub_path = "main.txt", .data = before.items });
    try reviewRepo(root);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "main.txt", .data = after.items });
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const h = try open(&app, root, "main.txt");
    const owner = try app.windowEntity(zircon.Shell, h);
    try send(&app, h, .git_diff_all);
    try settle(&app);
    const first = try reviewPoint(&app, h, "git-code:unified:0:0", "old 0", 0);
    const bounds = try elementBounds(&app, h, "git-diff-lines");
    const outside: ui.Point = .{ .x = first.x, .y = bounds.y + bounds.height + 50 };
    try app.dispatch(h, .{ .pointer_down = .{ .position = first } });
    _ = try app.step(0);
    try app.dispatch(h, .{ .pointer_move = .{ .position = outside } });
    for (1..13) |tick| _ = try app.step(@as(f64, @floatFromInt(tick)) / 60);
    const Check = struct {
        fn scrolling(self: *const zircon.Shell) !f32 {
            try t.expect(self.git.diff_scroll.offset > 50);
            try t.expect(self.git.review.?.editor.primary().range().end > 100);
            return self.git.diff_scroll.offset;
        }
        fn stopped(self: *const zircon.Shell, offset: f32) !void {
            try t.expectEqual(offset, self.git.diff_scroll.offset);
            try t.expect(!self.git.review.?.editor.dragging);
            try t.expectEqual(null, self.git.selection_drag);
        }
    };
    const offset = try app.read(owner, Check.scrolling, .{});
    try app.dispatch(h, .{ .pointer_up = .{ .position = outside } });
    _ = try app.step(0.5);
    try app.read(owner, Check.stopped, .{offset});
}

test "Git review source reload cannot leave invalid projected selection offsets" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "main.txt", .data = "before\n" });
    try reviewRepo(root);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "main.txt", .data = "a much longer current line\n" });
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const h = try open(&app, root, "main.txt");
    const owner = try app.windowEntity(zircon.Shell, h);
    try send(&app, h, .git_diff_all);
    try settle(&app);
    const first = try reviewPoint(&app, h, "git-live:main.txt:1", "a much longer current line", 0);
    const last = try reviewPoint(&app, h, "git-live:main.txt:1", "a much longer current line", 26);
    try reviewDrag(&app, h, first, last);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "main.txt", .data = "x\n" });
    _ = try app.step(2);
    const Check = struct {
        fn selection(self: *const zircon.Shell) !void {
            try t.expect(!self.git.review.?.focused);
        }
    };
    try app.read(owner, Check.selection, .{});
    try settleAt(&app, 2);
    var source: []u8 = undefined;
    try app.read(owner, Ops.sourceBySuffix, .{ "main.txt", t.allocator, &source });
    defer t.allocator.free(source);
    try t.expectEqualStrings("x\n", source);
}

test "foreground native menus route commands through the key window" {
    if (comptime ui.testing.native == void) return error.SkipZigTest;
    try menuJourney(true);
}

fn menuJourney(foreground: bool) !void {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "main.zig", .data = "const value = 1;\n" });
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const shell = try zircon.Shell.init(t.allocator, t.io, root, "main.zig");
    const h = try app.openWindow(zircon.Shell, .{ .title = "ZirconMenuJourney", .visible = false, .menus = &zircon.menus.groups, .width = 1200, .height = 760 }, shell);
    try app.update(try app.windowEntity(zircon.Shell, h), zircon.Shell.bootstrap, .{h});
    try settle(&app);
    const frame = &(try app.window(h)).frames.committed;
    for (frame.nodes.items) |node| if (node.key) |key| if (key == .string) {
        try t.expect(!std.mem.startsWith(u8, key.string, "app-menu:"));
        try t.expect(!std.mem.eql(u8, key.string, "application-menu"));
    };
    try app.dispatch(h, .{ .action = @backingInt(zircon.Command.new_file) });
    _ = try app.step(0);
    const Check = struct {
        fn newFile(self: *const zircon.Shell) bool {
            return self.tabs.items.len == 2;
        }
        fn nativeNewFile(self: *const zircon.Shell) bool {
            return self.tabs.items.len == 3;
        }
    };
    try t.expect(try app.read(try app.windowEntity(zircon.Shell, h), Check.newFile, .{}));
    if (comptime ui.testing.native != void) {
        const objc = ui.testing.native.objc;
        const native_app = objc.send(objc.Id, objc.class("NSApplication"), "sharedApplication", .{});
        const bar = objc.send(objc.Id, native_app, "mainMenu", .{});
        try t.expectEqual(@as(usize, zircon.menus.groups.len), objc.send(usize, bar, "numberOfItems", .{}));
        const heading = objc.send(objc.Id, bar, "itemAtIndex:", .{@as(isize, 6)});
        try t.expectEqualStrings("Git", objc.fromString(objc.send(objc.Id, heading, "title", .{})));
        const windows = objc.send(objc.Id, native_app, "windows", .{});
        var native_window: objc.Id = null;
        for (0..objc.send(usize, windows, "count", .{})) |index| {
            const candidate = objc.send(objc.Id, windows, "objectAtIndex:", .{index});
            if (std.mem.eql(u8, "ZirconMenuJourney", objc.fromString(objc.send(objc.Id, candidate, "title", .{})))) native_window = candidate;
        }
        const window = native_window orelse return error.MenuJourneyWindowMissing;
        const file_heading = objc.send(objc.Id, bar, "itemAtIndex:", .{@as(isize, 1)});
        const file_menu = objc.send(objc.Id, file_heading, "submenu", .{});
        const item = objc.send(objc.Id, file_menu, "itemAtIndex:", .{@as(isize, 0)});
        if (foreground) {
            objc.send(void, native_app, "activateIgnoringOtherApps:", .{true});
            objc.send(void, window, "makeKeyAndOrderFront:", .{@as(objc.Id, null)});
            const deadline = std.Io.Clock.awake.now(t.io).addDuration(.fromMilliseconds(500));
            while (!objc.send(bool, native_app, "isActive", .{}) or objc.send(objc.Id, native_app, "keyWindow", .{}) != window) {
                if (std.Io.Clock.awake.now(t.io).compare(.gte, deadline)) break;
                try ui.testing.native.pump(0.005);
            }
            const active = objc.send(bool, native_app, "isActive", .{});
            const key = objc.send(objc.Id, native_app, "keyWindow", .{});
            if (!active and key == null) {
                try std.Io.Dir.cwd().writeFile(t.io, .{ .sub_path = "/tmp/zircon-native-menu-input-mode.txt", .data = "SKIPPED: macOS denied app activation; keyWindow and menu target are absent\n" });
                return error.SkipZigTest;
            }
            try t.expect(active and key == window);
            objc.send(void, file_menu, "performActionForItemAtIndex:", .{@as(isize, 0)});
        } else {
            const action = objc.send(?*anyopaque, item, "action", .{});
            const responder = objc.send(objc.Id, window, "firstResponder", .{});
            try t.expect(objc.send(bool, native_app, "sendAction:to:from:", .{ action, responder, item }));
        }
        for (0..4) |_| try ui.testing.native.pump(0);
        _ = try app.step(0);
        try t.expect(try app.read(try app.windowEntity(zircon.Shell, h), Check.nativeNewFile, .{}));
        if (foreground) try std.Io.Dir.cwd().writeFile(t.io, .{ .sub_path = "/tmp/zircon-native-menu-input-mode.txt", .data = "PASSED: native responder-chain menu routing through the key window\n" });
    }
}

test "Git canvas active line preserves the change background" {
    try gitCanvasJourney(.active_tint);
}

fn gitSaveJourney(comptime removed_hunk: bool) !void {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "main.zig", .data = "const a = 1;\n" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "helper.zig", .data = "const b = 1;\n" });
    try reviewRepo(root);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "main.zig", .data = "const a = 2;\n" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "helper.zig", .data = "const b = 2;\n" });
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const h = try open(&app, root, "main.zig");
    const owner = try app.windowEntity(zircon.Shell, h);
    const Ownership = struct {
        fn wrap(self: *zircon.Shell, cx: *ui.Context(zircon.Shell)) !void {
            try cx.update(self.settings.?, zircon.Settings.apply, .{zircon.SettingsPatch{ .soft_wrap = .editor_width }});
        }
        fn builds(self: *const zircon.Shell) usize {
            return self.tabs.items[0].editor.wrap_cache.builds;
        }
        fn check(self: *const zircon.Shell) !void {
            try t.expectEqual(@as(usize, 1), self.tabs.items.len);
        }
    };
    try app.update(owner, Ownership.wrap, .{});
    _ = try app.step(0);
    try send(&app, h, .git_diff_all);
    try settle(&app);
    try app.read(owner, Ownership.check, .{});
    const before_edit = zircon.git.processStats();
    const hidden_builds = try app.read(owner, Ownership.builds, .{});
    const first = try reviewPoint(&app, h, "git-live:main.zig:1", "const a = 2;", 0);
    if (removed_hunk) {
        const end = try reviewPoint(&app, h, "git-live:main.zig:1", "const a = 2;", "const a = 2;".len);
        try reviewDrag(&app, h, first, end);
        try app.dispatch(h, .{ .text = "const a = 1;" });
    } else {
        try reviewDrag(&app, h, first, first);
        try app.dispatch(h, .{ .text = "// first\n" });
    }
    try settle(&app);
    const second = try reviewPoint(&app, h, "git-live:helper.zig:1", "const b = 2;", 0);
    try reviewDrag(&app, h, second, second);
    try app.dispatch(h, .{ .text = "// second\n" });
    try settle(&app);
    // Buffer diffs use retained comparison text, without Git subprocesses.
    try t.expectEqual(before_edit.commands, zircon.git.processStats().commands);
    try t.expectEqual(hidden_builds, try app.read(owner, Ownership.builds, .{}));
    try app.read(owner, Ownership.check, .{});
    if (!removed_hunk) {
        const dot = try elementBounds(&app, h, "git-dirty:main.zig");
        _ = try elementBounds(&app, h, "git-dirty:helper.zig");
        const Theme = struct {
            fn blue(self: *const zircon.Shell) ui.Color {
                return self.colors.accent;
            }
        };
        const blue = try app.read(owner, Theme.blue, .{});
        var found = false;
        for ((try app.window(h)).frames.committed.scene.items) |item| if (item.kind == .rect and std.meta.eql(item.color, blue) and item.rect.x == dot.x and item.rect.y == dot.y and item.rect.width == 6 and item.rect.height == 6) {
            found = true;
        };
        try t.expect(found);
        if (comptime ui.testing.native != void) try (try app.window(h)).snapshot("/tmp/zircon-git-dirty-headers.png");
    }
    try app.dispatch(h, .{ .key_down = .{ .key = .s, .modifiers = .{ .command = true } } });
    try settle(&app);
    const main = try tmp.dir.readFileAlloc(t.io, "main.zig", t.allocator, .limited(1000));
    defer t.allocator.free(main);
    const helper = try tmp.dir.readFileAlloc(t.io, "helper.zig", t.allocator, .limited(1000));
    defer t.allocator.free(helper);
    try t.expectEqualStrings(if (removed_hunk) "const a = 1;\n" else "// first\nconst a = 2;\n", main);
    try t.expectEqualStrings("// second\nconst b = 2;\n", helper);
    const Read = struct {
        fn clean(self: *const zircon.Shell) !void {
            for (self.git.editing.views.items) |view| try t.expect(!try self.workspace.dirty(view.document));
        }
    };
    try app.read(owner, Read.clean, .{});
    for ((try app.window(h)).frames.committed.nodes.items) |node| if (node.key) |key| if (key == .string) try t.expect(!std.mem.startsWith(u8, key.string, "git-dirty:"));
    try send(&app, h, .back_to_editor);
    try app.read(owner, Ownership.check, .{});
}

test "Git canvas marks both unsaved files and saves them together" {
    try gitSaveJourney(false);
}
test "Git canvas saves an edited file after its last hunk disappears" {
    try gitSaveJourney(true);
}

test "Git canvas context arrows expand five lines at one boundary" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    var before: std.ArrayList(u8) = .empty;
    defer before.deinit(t.allocator);
    var after: std.ArrayList(u8) = .empty;
    defer after.deinit(t.allocator);
    for (1..81) |number| {
        const old = try std.fmt.allocPrint(t.allocator, "const value_{d} = false;\n", .{number});
        defer t.allocator.free(old);
        const new = try std.fmt.allocPrint(t.allocator, "const value_{d} = {s};\n", .{ number, if (number == 20 or number == 60) "true" else "false" });
        defer t.allocator.free(new);
        try before.appendSlice(t.allocator, old);
        try after.appendSlice(t.allocator, new);
    }
    try tmp.dir.writeFile(t.io, .{ .sub_path = "main.zig", .data = before.items });
    try reviewRepo(root);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "main.zig", .data = after.items });
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const h = try open(&app, root, "main.zig");
    const owner = try app.windowEntity(zircon.Shell, h);
    try send(&app, h, .git_diff_all);
    try settle(&app);
    const Check = struct {
        fn ranges(self: *const zircon.Shell, start: usize, count: usize, second_start: usize, second_count: usize) !void {
            const hunks = self.git.diff.?.hunks;
            try t.expectEqual(@as(usize, 2), hunks.len);
            try t.expectEqual(start, hunks[0].new_start);
            try t.expectEqual(count, hunks[0].new_count);
            try t.expectEqual(second_start, hunks[1].new_start);
            try t.expectEqual(second_count, hunks[1].new_count);
        }
    };
    const down = try elementBounds(&app, h, "git-context:down:main.zig:17");
    const point: ui.Point = .{ .x = down.x + down.width / 2, .y = down.y + down.height / 2 };
    try reviewDrag(&app, h, point, point);
    try app.read(owner, Check.ranges, .{ @as(usize, 17), @as(usize, 12), @as(usize, 57), @as(usize, 7) });
    const up = try elementBounds(&app, h, "git-context:up:main.zig:57");
    const second: ui.Point = .{ .x = up.x + up.width / 2, .y = up.y + up.height / 2 };
    try reviewDrag(&app, h, second, second);
    try app.read(owner, Check.ranges, .{ @as(usize, 17), @as(usize, 12), @as(usize, 52), @as(usize, 12) });
    if (comptime ui.testing.native != void) try (try app.window(h)).snapshot("/tmp/zircon-git-local-context.png");
}

fn stickyFileJourney(comptime search: bool) !void {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    var old: std.ArrayList(u8) = .empty;
    defer old.deinit(t.allocator);
    var new: std.ArrayList(u8) = .empty;
    defer new.deinit(t.allocator);
    for (0..60) |_| {
        try old.appendSlice(t.allocator, "const needle = false;\n");
        try new.appendSlice(t.allocator, "const needle = true;\n");
    }
    for ([_][]const u8{ "main.zig", "z.zig" }) |path| try tmp.dir.writeFile(t.io, .{ .sub_path = path, .data = old.items });
    try reviewRepo(root);
    for ([_][]const u8{ "main.zig", "z.zig" }) |path| try tmp.dir.writeFile(t.io, .{ .sub_path = path, .data = new.items });
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const h = try open(&app, root, "main.zig");
    const owner = try app.windowEntity(zircon.Shell, h);
    if (search) {
        try send(&app, h, .project_search);
        try app.update(owner, Ops.setProjectQuery, .{"needle"});
        try send(&app, h, .run_project_search);
    } else try send(&app, h, .git_diff_all);
    try settle(&app);
    const Check = struct {
        fn end(self: *const zircon.Shell) f32 {
            const lh = self.editor_options.font_size * self.editor_options.line_height;
            if (search) {
                const file = self.search.editing.files.items[0];
                return 36 + @as(f32, @floatFromInt(file.rows)) * lh + @as(f32, @floatFromInt(file.excerpts.len)) * 12;
            }
            return self.git.projection.?.files[0].height(&self.git.diff_view, lh);
        }
        fn scroll(self: *zircon.Shell, cx: *ui.Context(zircon.Shell), value: f32) void {
            if (search) self.search.editing.scroll[0].offset = value else self.git.diff_scroll.offset = value;
            cx.notify();
        }
        fn clean(self: *const zircon.Shell) !void {
            for (self.workspace.slots.items) |slot| if (slot.record) |record| try t.expect(!record.dirty());
        }
    };
    const key = if (search) "search-excerpts" else "git-diff-lines";
    const first_header = if (search) "search-file:0" else "diff-file:main.zig";
    const second_header = if (search) "search-file:1" else "diff-file:z.zig";
    const header_height: f32 = if (search) 36 else zircon.diff_layout.file_height;
    var area = try elementBounds(&app, h, key);
    try app.dispatch(h, .{ .scroll = .{ .position = .{ .x = area.x + 100, .y = area.y + 120 }, .x = 0, .y = -100 } });
    _ = try app.step(0);
    area = try elementBounds(&app, h, key);
    try t.expectApproxEqAbs(area.y, (try elementBounds(&app, h, first_header)).y, 0.1);
    const end = try app.read(owner, Check.end, .{});
    try app.update(owner, Check.scroll, .{end - header_height / 2});
    _ = try app.step(0);
    try t.expectApproxEqAbs(area.y - header_height / 2, (try elementBounds(&app, h, first_header)).y, 0.1);
    try t.expectApproxEqAbs(area.y + header_height / 2, (try elementBounds(&app, h, second_header)).y, 0.1);
    try app.update(owner, Check.scroll, .{end + 100});
    _ = try app.step(0);
    try t.expectApproxEqAbs(area.y, (try elementBounds(&app, h, second_header)).y, 0.1);
    if (comptime ui.testing.native != void) try (try app.window(h)).snapshot(if (search) "/tmp/zircon-search-sticky.png" else "/tmp/zircon-git-sticky.png");
    // The floating header keeps its action and does not focus underlying text.
    if (search) {
        try click(&app, h, "z.zig    60 matches");
    } else try click(&app, h, "Collapse z.zig");
    try app.read(owner, Check.clean, .{});
}

test "Git file header sticks pushes off and keeps its controls" {
    try stickyFileJourney(false);
}
test "project search file header sticks pushes off and opens its source" {
    try stickyFileJourney(true);
}
