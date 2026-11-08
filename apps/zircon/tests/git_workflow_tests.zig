//! Git acceptance uses the application and disposable local repositories.
const std = @import("std");
const zircon = @import("zircon");
const ui = @import("zircon_ui");
const t = std.testing;

fn git(root: []const u8, arguments: []const []const u8) ![]u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(t.allocator);
    try argv.appendSlice(t.allocator, &.{ "git", "-C", root });
    try argv.appendSlice(t.allocator, arguments);
    const result = try std.process.run(t.allocator, t.io, .{ .argv = argv.items });
    defer t.allocator.free(result.stderr);
    if (!result.term.success()) {
        t.allocator.free(result.stdout);
        std.debug.print("Fixture git failed: {s}\n", .{result.stderr});
        return error.FixtureGitFailed;
    }
    return result.stdout;
}
fn run(root: []const u8, arguments: []const []const u8) !void {
    t.allocator.free(try git(root, arguments));
}
fn initRepo(tmp: std.testing.TmpDir) ![:0]u8 {
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    errdefer t.allocator.free(root);
    try run(root, &.{ "init", "-q", "-b", "main" });
    try run(root, &.{ "config", "user.name", "Fixture" });
    try run(root, &.{ "config", "user.email", "fixture@zircon.invalid" });
    try run(root, &.{ "config", "commit.gpgsign", "false" });
    try run(root, &.{ "config", "core.hooksPath", ".git/hooks" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "main.txt", .data = "initial\n" });
    try run(root, &.{ "add", "main.txt" });
    try run(root, &.{ "commit", "-qm", "Initial" });
    return root;
}
const Ops = struct {
    fn command(self: *zircon.Shell, cx: *ui.Context(zircon.Shell), which: zircon.Command) !void {
        var event: ui.Event(ui.Click) = .{ .data = .{} };
        try self.onCommand(&event, cx, which);
    }
    fn ready(self: *const zircon.Shell) bool {
        return self.git.repository and self.git.status != null and self.git.references != null and !self.git.busy;
    }
    fn errors(self: *const zircon.Shell) !void {
        if (self.git.error_text.len > 0) std.debug.print("App git failed: {s}\n", .{self.git.error_text});
        try t.expectEqualStrings("", self.git.error_text);
        try t.expect(!self.status_is_error);
    }
    fn source(self: *const zircon.Shell, expected: []const u8) !void {
        var snapshot = try self.workspace.snapshot(self.tabs.items[0].document);
        defer snapshot.deinit();
        const bytes = try snapshot.copy(t.allocator, .{ .start = 0, .end = snapshot.byteLen() });
        defer t.allocator.free(bytes);
        try t.expectEqualStrings(expected, bytes);
    }
    fn clean(self: *const zircon.Shell) bool {
        return !(self.workspace.dirty(self.tabs.items[0].document) catch true);
    }
    fn tracking(self: *const zircon.Shell, expected: []const u8) !void {
        for (self.git.references.?.branches) |branch| if (std.mem.eql(u8, branch.name, "main")) {
            try t.expect(std.mem.indexOf(u8, branch.tracking, expected) != null);
            return;
        };
        return error.MainBranchMissing;
    }
};
fn settle(app: *ui.App) !void {
    const deadline = std.Io.Clock.awake.now(t.io).addDuration(.fromSeconds(8));
    while (try app.tasksPending()) {
        _ = try app.step(0);
        if (std.Io.Clock.awake.now(t.io).compare(.gte, deadline)) return error.GitWorkflowTimeout;
        try std.Io.sleep(t.io, .fromMilliseconds(1), .awake);
    }
    _ = try app.step(0);
}
fn open(app: *ui.App, root: []const u8) !ui.WindowHandle {
    const handle = try app.openWindow(zircon.Shell, .{ .visible = false, .width = 1200, .height = 800 }, try zircon.Shell.init(t.allocator, t.io, root, "main.txt"));
    const owner = try app.windowEntity(zircon.Shell, handle);
    try app.update(owner, zircon.Shell.bootstrap, .{handle});
    try app.update(owner, Ops.command, .{.git_changes});
    try settle(app);
    try t.expect(try app.read(owner, Ops.ready, .{}));
    return handle;
}
fn button(app: *ui.App, handle: ui.WindowHandle, name: []const u8) !struct { bounds: ui.Rect, enabled: bool } {
    const frame = &(try app.window(handle)).frames.committed;
    for (frame.nodes.items, 0..) |node, index| if (node.kind == .button and std.mem.eql(u8, node.kind.button.label, name)) return .{ .bounds = frame.bounds[index], .enabled = node.kind.button.on_click != null };
    return error.ButtonMissing;
}
fn click(app: *ui.App, handle: ui.WindowHandle, name: []const u8) !void {
    const target = try button(app, handle, name);
    try t.expect(target.enabled);
    const position: ui.Point = .{ .x = target.bounds.x + target.bounds.width / 2, .y = target.bounds.y + target.bounds.height / 2 };
    try app.dispatch(handle, .{ .pointer_down = .{ .position = position } });
    try app.dispatch(handle, .{ .pointer_up = .{ .position = position } });
    _ = try app.step(0);
}
fn message(app: *ui.App, handle: ui.WindowHandle, content: []const u8) !void {
    const frame = &(try app.window(handle)).frames.committed;
    const rect = for (frame.nodes.items, 0..) |node, index| {
        if (node.key) |key| if (key == .string and std.mem.eql(u8, key.string, "commit-message")) break frame.bounds[index];
    } else return error.CommitInputMissing;
    const position: ui.Point = .{ .x = rect.x + 15, .y = rect.y + 12 };
    try app.dispatch(handle, .{ .pointer_down = .{ .position = position } });
    try app.dispatch(handle, .{ .pointer_up = .{ .position = position } });
    try app.dispatch(handle, .{ .key_down = .{ .key = .a, .modifiers = .{ .command = true } } });
    try app.dispatch(handle, .{ .text = content });
    _ = try app.step(0);
}

test "Git commit without explicit staging commits tracked changes and leaves new files" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try initRepo(tmp);
    defer t.allocator.free(root);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "main.txt", .data = "changed\n" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "new.txt", .data = "new\n" });
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const handle = try open(&app, root);
    const owner = try app.windowEntity(zircon.Shell, handle);
    try message(&app, handle, "Tracked edit");
    const target = try button(&app, handle, "Commit tracked changes");
    try t.expect(target.enabled);
    try app.update(owner, Ops.command, .{.git_commit});
    try settle(&app);
    try app.read(owner, Ops.errors, .{});
    const content = try git(root, &.{ "show", "HEAD:main.txt" });
    defer t.allocator.free(content);
    try t.expectEqualStrings("changed\n", content);
    const status = try git(root, &.{ "status", "--porcelain" });
    defer t.allocator.free(status);
    try t.expectEqualStrings("?? new.txt\n", status);
}

test "Git stage saves the current dirty source before updating the index" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try initRepo(tmp);
    defer t.allocator.free(root);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "main.txt", .data = "disk\n" });
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const handle = try open(&app, root);
    const owner = try app.windowEntity(zircon.Shell, handle);
    try app.update(owner, Ops.command, .{.back_to_editor});
    _ = try app.step(0);
    try app.dispatch(handle, .{ .text = "typed " });
    try settle(&app);
    try app.read(owner, Ops.source, .{"typed disk\n"});
    try click(&app, handle, "Stage main.txt");
    try settle(&app);
    try app.read(owner, Ops.errors, .{});
    const staged = try git(root, &.{ "show", ":main.txt" });
    defer t.allocator.free(staged);
    try t.expectEqualStrings("typed disk\n", staged);
    try t.expect(try app.read(owner, Ops.clean, .{}));
}

test "Git app publishes fetches pulls and pushes through local remote controls" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var bare = t.tmpDir(.{});
    defer bare.cleanup();
    var peer = t.tmpDir(.{});
    defer peer.cleanup();
    const root = try initRepo(tmp);
    defer t.allocator.free(root);
    const remote = try bare.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(remote);
    const other = try peer.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(other);
    try run(remote, &.{ "init", "--bare", "-q", "-b", "main" });
    try run(root, &.{ "remote", "add", "origin", remote });
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const handle = try open(&app, root);
    const owner = try app.windowEntity(zircon.Shell, handle);
    try click(&app, handle, "Publish");
    try settle(&app);
    try app.read(owner, Ops.errors, .{});
    const upstream = try git(root, &.{ "rev-parse", "--abbrev-ref", "@{upstream}" });
    defer t.allocator.free(upstream);
    try t.expectEqualStrings("origin/main\n", upstream);
    try run(other, &.{ "clone", "-q", remote, "." });
    try run(other, &.{ "config", "user.name", "Peer" });
    try run(other, &.{ "config", "user.email", "peer@zircon.invalid" });
    try run(other, &.{ "config", "commit.gpgsign", "false" });
    try peer.dir.writeFile(t.io, .{ .sub_path = "main.txt", .data = "from peer\n" });
    try run(other, &.{ "add", "main.txt" });
    try run(other, &.{ "commit", "-qm", "Peer edit" });
    try run(other, &.{ "push", "-q" });
    try click(&app, handle, "Remote actions");
    try click(&app, handle, "Fetch");
    try settle(&app);
    try app.read(owner, Ops.errors, .{});
    try app.read(owner, Ops.tracking, .{"behind 1"});
    try click(&app, handle, "Remote actions");
    try click(&app, handle, "Pull");
    try settle(&app);
    try app.read(owner, Ops.errors, .{});
    try app.read(owner, Ops.source, .{"from peer\n"});
    try app.update(owner, Ops.command, .{.dismiss});
    try app.update(owner, Ops.command, .{.back_to_editor});
    _ = try app.step(0);
    try app.dispatch(handle, .{ .text = "local " });
    try app.update(owner, Ops.command, .{.save});
    try settle(&app);
    try click(&app, handle, "Stage main.txt");
    try settle(&app);
    try message(&app, handle, "Local edit");
    try click(&app, handle, "Commit staged changes");
    try settle(&app);
    try app.read(owner, Ops.errors, .{});
    try click(&app, handle, "Push");
    try settle(&app);
    try app.read(owner, Ops.errors, .{});
    const local_oid = try git(root, &.{ "rev-parse", "HEAD" });
    defer t.allocator.free(local_oid);
    const remote_oid = try git(remote, &.{ "rev-parse", "main" });
    defer t.allocator.free(remote_oid);
    try t.expectEqualStrings(local_oid, remote_oid);
}

test "Git commit preserves an explicit index and failed hooks retain the message" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try initRepo(tmp);
    defer t.allocator.free(root);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "main.txt", .data = "staged\n" });
    try run(root, &.{ "add", "main.txt" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "main.txt", .data = "unstaged\n" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "new.txt", .data = "untracked\n" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = ".git/hooks/pre-commit", .data = "#!/bin/sh\necho fixture-hook-refused >&2\nexit 1\n" });
    const hook = try tmp.dir.openFile(t.io, ".git/hooks/pre-commit", .{});
    defer hook.close(t.io);
    try hook.setPermissions(t.io, .fromMode(0o755));
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const handle = try open(&app, root);
    const owner = try app.windowEntity(zircon.Shell, handle);
    try message(&app, handle, "Keep staged snapshot");
    try click(&app, handle, "Commit staged changes");
    try settle(&app);
    const Check = struct {
        fn refresh(self: *zircon.Shell, cx: *ui.Context(zircon.Shell)) !void {
            self.git.next_refresh = 0;
            try self.pollLanguage(cx);
        }
        fn failure(self: *const zircon.Shell) bool {
            return std.mem.indexOf(u8, self.git.error_text, "fixture-hook-refused") != null;
        }
        fn messageText(self: *zircon.Shell, cx: *ui.Context(zircon.Shell), expected: []const u8) !void {
            var bytes: []u8 = undefined;
            try cx.read(self.fields.?.git_commit.message, ui.controls.TextInput.copy, .{ t.allocator, &bytes });
            defer t.allocator.free(bytes);
            try t.expectEqualStrings(expected, bytes);
        }
    };
    try t.expect(try app.read(owner, Check.failure, .{}));
    try app.update(owner, Check.refresh, .{});
    try settle(&app);
    try t.expect(try app.read(owner, Check.failure, .{}));
    try app.update(owner, Check.messageText, .{"Keep staged snapshot"});
    const staged = try git(root, &.{ "show", ":main.txt" });
    defer t.allocator.free(staged);
    try t.expectEqualStrings("staged\n", staged);
    try tmp.dir.deleteFile(t.io, ".git/hooks/pre-commit");
    try click(&app, handle, "Commit staged changes");
    try settle(&app);
    try app.read(owner, Ops.errors, .{});
    try app.update(owner, Check.messageText, .{""});
    const committed = try git(root, &.{ "show", "HEAD:main.txt" });
    defer t.allocator.free(committed);
    try t.expectEqualStrings("staged\n", committed);
    const disk = try tmp.dir.readFileAlloc(t.io, "main.txt", t.allocator, .limited(128));
    defer t.allocator.free(disk);
    try t.expectEqualStrings("unstaged\n", disk);
    const status = try git(root, &.{ "status", "--porcelain" });
    defer t.allocator.free(status);
    try t.expectEqualStrings(" M main.txt\n?? new.txt\n", status);
}

test "Git staging stops before index mutation when saving would overwrite an external edit" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try initRepo(tmp);
    defer t.allocator.free(root);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "main.txt", .data = "disk\n" });
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const handle = try open(&app, root);
    const owner = try app.windowEntity(zircon.Shell, handle);
    try app.update(owner, Ops.command, .{.back_to_editor});
    _ = try app.step(0);
    try app.dispatch(handle, .{ .text = "typed " });
    try settle(&app);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "main.txt", .data = "external\n" });
    try click(&app, handle, "Stage main.txt");
    try settle(&app);
    try t.expect(!try app.read(owner, Ops.clean, .{}));
    try app.read(owner, Ops.source, .{"typed disk\n"});
    const staged = try git(root, &.{ "show", ":main.txt" });
    defer t.allocator.free(staged);
    try t.expectEqualStrings("initial\n", staged);
    const disk = try tmp.dir.readFileAlloc(t.io, "main.txt", t.allocator, .limited(128));
    defer t.allocator.free(disk);
    try t.expectEqualStrings("external\n", disk);
}

const Identity = struct { references: usize, commits: usize, diff_generation: u64, status_generation: u64 };
const RefreshOps = struct {
    fn identity(self: *const zircon.Shell) Identity {
        return .{
            .references = @intFromPtr(self.git.references.?.branches.ptr),
            .commits = @intFromPtr(self.git.commits.ptr),
            .diff_generation = self.git.diff_generation,
            .status_generation = self.git.status_generation,
        };
    }
    fn automatic(self: *zircon.Shell, cx: *ui.Context(zircon.Shell)) !void {
        self.git.next_refresh = 0;
        self.project_watch.next_check = 0;
        try self.pollLanguage(cx);
    }
    fn latest(self: *const zircon.Shell, expected: []const u8) !void {
        try t.expectEqualStrings(expected, self.git.commits[0].subject);
    }
};

test "Git automatic refresh retains unchanged UI data and reloads history after external commits" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try initRepo(tmp);
    defer t.allocator.free(root);
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const handle = try open(&app, root);
    const owner = try app.windowEntity(zircon.Shell, handle);
    const before = try app.read(owner, RefreshOps.identity, .{});
    const processes = zircon.git.processStats();
    for (0..3) |_| {
        try app.update(owner, RefreshOps.automatic, .{});
        try settle(&app);
    }
    try t.expectEqual(processes.history, zircon.git.processStats().history);
    try t.expectEqual(before, try app.read(owner, RefreshOps.identity, .{}));
    try tmp.dir.writeFile(t.io, .{ .sub_path = "main.txt", .data = "external\n" });
    try run(root, &.{ "add", "main.txt" });
    try run(root, &.{ "commit", "-qm", "External commit" });
    try app.update(owner, RefreshOps.automatic, .{});
    try settle(&app);
    try app.read(owner, RefreshOps.latest, .{"External commit"});
    try app.read(owner, Ops.source, .{"external\n"});
}

test "Git staging rejects a newer edit made after preparation captured the source" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try initRepo(tmp);
    defer t.allocator.free(root);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "main.txt", .data = "disk\n" });
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const handle = try open(&app, root);
    const owner = try app.windowEntity(zircon.Shell, handle);
    const target = try button(&app, handle, "Stage main.txt");
    const position: ui.Point = .{ .x = target.bounds.x + target.bounds.width / 2, .y = target.bounds.y + target.bounds.height / 2 };
    try app.dispatch(handle, .{ .pointer_down = .{ .position = position } });
    try app.dispatch(handle, .{ .pointer_up = .{ .position = position } });
    const Edit = struct {
        fn source(self: *zircon.Shell, cx: *ui.Context(zircon.Shell)) !void {
            const tab = &self.tabs.items[0];
            const record = try self.workspace.get(tab.document);
            var outcome = try tab.editor.insert(&record.doc, "newer ");
            if (outcome.change) |*change| change.deinit();
            cx.notify();
        }
        fn failed(self: *const zircon.Shell) bool {
            return self.status_is_error and std.mem.indexOf(u8, self.status, "changed while Git") != null;
        }
    };
    try app.update(owner, Edit.source, .{});
    try settle(&app);
    try t.expect(try app.read(owner, Edit.failed, .{}));
    const staged = try git(root, &.{ "show", ":main.txt" });
    defer t.allocator.free(staged);
    try t.expectEqualStrings("initial\n", staged);
    try app.read(owner, Ops.source, .{"newer disk\n"});
}
