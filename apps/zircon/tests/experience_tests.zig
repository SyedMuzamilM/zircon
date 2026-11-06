//! App-level journeys use temporary repositories, manifests and real documents.
//! Native rendering has a separate suite; these tests share its event routing.
const std = @import("std");
const ui = @import("zircon_ui");
const zircon = @import("zircon");
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
        if (self.status_is_error) {
            std.debug.print("Journey: {s}\n", .{self.status});
            return error.CommandFailed;
        }
    }
    fn open(self: *zircon.Shell, cx: *ui.Context(zircon.Shell), path: []const u8) !void {
        try self.openPath(path);
        cx.notify();
    }
    fn configure(self: *zircon.Shell, cx: *ui.Context(zircon.Shell), home: []const u8) !void {
        try self.loadExtensions(cx, home);
    }
    fn gitFile(self: *zircon.Shell, cx: *ui.Context(zircon.Shell)) !void {
        var event: ui.Event(ui.Click) = .{ .data = .{} };
        try self.onGitFile(&event, cx, 0);
    }
    fn gitCommit(self: *zircon.Shell, cx: *ui.Context(zircon.Shell)) !void {
        var event: ui.Event(ui.Click) = .{ .data = .{} };
        try self.onGitCommit(&event, cx, 0);
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
    try tmp.dir.writeFile(t.io, .{ .sub_path = "note.md", .data = "# Title\n\nText **bold** and [source](other.md).\n\n```zig\nconst n = 1;\n```\n\n| One | Two |\n| --- | --- |\n| a | b |\n" });
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const h = try open(&app, root, "note.md");
    const owner = try app.windowEntity(zircon.Shell, h);
    try send(&app, h, .markdown_preview);
    _ = try elementBounds(&app, h, "markdown-preview");
    try t.expect(try app.read(owner, Ops.previewCurrent, .{}));
    try app.dispatch(h, .{ .text = "Updated " });
    _ = try app.step(0);
    try t.expect(try app.read(owner, Ops.previewCurrent, .{}));
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
    try send(&app, h, .complete);
    while (!try app.read(owner, Ops.completion, .{})) {
        _ = try app.step(0);
        if (std.Io.Clock.awake.now(t.io).compare(.gte, deadline)) return error.CompletionTimeout;
        std.Io.sleep(t.io, .fromMilliseconds(1), .awake) catch {};
    }
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
    if (comptime ui.testing.native != void) try (try app.window(h)).snapshot("/tmp/zircon-git-all.png");
    try app.update(owner, Ops.gitFile, .{});
    try settle(&app);
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
    try t.expect(try app.read(owner, Updated.empty, .{}));
    try click(&app, h, "Staged");
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
    try app.update(owner, Ops.gitCommit, .{});
    try settle(&app);
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
    const copy_point: ui.Point = .{ .x = canvas.x + canvas.width - 60, .y = canvas.y + 2 * 22.4 + 180 };
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
    const unsaved: ui.Point = .{ .x = canvas.x + 6, .y = canvas.y + 6 };
    try app.dispatch(h, .{ .pointer_down = .{ .position = unsaved } });
    try app.dispatch(h, .{ .pointer_up = .{ .position = unsaved } });
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
}
