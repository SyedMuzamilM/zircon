//! Real repository queries/mutations run as entity-owned jobs. UI installation
//! checks document revisions and uses an explicit single-owner result handoff.
const std = @import("std");
const ui = @import("zircon_ui");
const git = @import("zircon_git");
const text = @import("zircon_text");
const workspace = @import("zircon_workspace");
const Shell = @import("../shell.zig").Shell;
const a = std.heap.page_allocator;
pub const Operation = union(enum) { refresh, all_diff, diff: struct { path: []const u8, staged: bool }, history: []const u8, stage: []const u8, unstage: []const u8, stage_all, unstage_all, commit: []const u8, blame: usize };
pub const Model = struct {
    active_document: ?workspace.DocumentId = null,
    status: ?git.Status = null,
    commits: []git.Commit = &.{},
    diff: ?git.Diff = null,
    selected_path: []u8 = &.{},
    selected_commit: []u8 = &.{},
    busy: bool = false,
    repository: bool = false,
    generation: u64 = 0,
    status_generation: u64 = 0,
    needs_refresh: bool = false,
    diff_scroll: ui.controls.Scroll = .{},
    sidebar_scroll: ui.controls.Scroll = .{},
    tree: @import("../models/git_tree.zig").Tree = .{},
    staged_diff: bool = false,
    error_text: []u8 = &.{},
    pub fn deinit(self: *Model) void {
        self.tree.deinit(a);
        if (self.status) |*value| value.deinit();
        git.deinitHistory(a, self.commits);
        if (self.diff) |*value| value.deinit();
        a.free(self.selected_path);
        a.free(self.selected_commit);
        a.free(self.error_text);
        self.* = undefined;
    }
};
const Result = struct {
    found: bool = false,
    generation: u64,
    status: ?git.Status = null,
    commits: []git.Commit = &.{},
    commits_ready: bool = false,
    diff: ?git.Diff = null,
    blame: ?git.Blame = null,
    document: ?workspace.DocumentId = null,
    revision: u64 = 0,
    changes: []git.LineChange = &.{},
    changes_ready: bool = false,
    error_text: []u8 = &.{},
    pub fn deinit(self: *Result) void {
        if (self.status) |*v| v.deinit();
        git.deinitHistory(a, self.commits);
        if (self.diff) |*v| v.deinit();
        if (self.blame) |*v| v.deinit();
        a.free(self.changes);
        a.free(self.error_text);
    }
};
const Box = @import("handoff.zig").Handoff(Result);
const Job = struct {
    pub const Output = *Box;
    io: std.Io,
    root: []u8,
    operation: Operation,
    generation: u64,
    snapshot: ?text.Snapshot = null,
    document: ?workspace.DocumentId = null,
    path: ?[]u8 = null,
    comparison: ?struct { path: ?[]u8, staged: bool } = null,
    pub fn run(self: *Job, cancel: *ui.tasks.Cancellation) !*Box {
        try cancel.check();
        var result: Result = .{ .generation = self.generation, .document = self.document, .revision = if (self.snapshot) |s| s.revision() else 0 };
        errdefer result.deinit();
        var repo = (try git.Repository.discover(a, self.io, self.root)) orelse return Box.create(a, result);
        defer repo.deinit();
        result.found = true;
        self.perform(&repo, &result) catch |err| {
            result.error_text = try std.fmt.allocPrint(a, "Git: {s}\n{s}", .{ @errorName(err), repo.lastError() });
            if (result.status == null) result.status = repo.status(a) catch null;
        };
        try cancel.check();
        return Box.create(a, result);
    }
    fn perform(self: *Job, repo: *git.Repository, result: *Result) !void {
        switch (self.operation) {
            .refresh => {},
            .all_diff => result.diff = try repo.diff(a, null, false),
            .diff => |request| result.diff = try repo.diff(a, request.path, request.staged),
            .history => |oid| result.diff = try repo.commitDiff(a, oid, null),
            .stage => |path| try repo.stage(&.{path}),
            .unstage => |path| try repo.unstage(&.{path}),
            .commit => |message| try repo.commit(message),
            .stage_all, .unstage_all => {
                var current = try repo.status(a);
                defer current.deinit();
                var paths: std.ArrayList([]const u8) = .empty;
                defer paths.deinit(a);
                for (current.entries) |entry| {
                    if ((self.operation == .stage_all and entry.unstaged) or (self.operation == .unstage_all and entry.staged)) try paths.append(a, entry.path);
                }
                if (self.operation == .stage_all) try repo.stage(paths.items) else try repo.unstage(paths.items);
            },
            .blame => |line| if (self.path) |absolute| {
                const path = try repo.relativePath(a, absolute);
                defer a.free(path);
                const bytes = if (self.snapshot) |snapshot| try snapshot.copy(a, .{ .start = 0, .end = snapshot.byteLen() }) else null;
                defer if (bytes) |value| a.free(value);
                result.blame = try repo.blame(a, path, line, bytes);
            },
        }
        if (self.comparison) |comparison| result.diff = try repo.diff(a, comparison.path, comparison.staged);
        result.status = try repo.status(a);
        result.commits = try repo.history(a, 100);
        result.commits_ready = true;
        if (self.path) |absolute| if (self.snapshot) |snapshot| {
            const path = repo.relativePath(a, absolute) catch return;
            defer a.free(path);
            const base = try repo.baseline(a, path, .index);
            defer a.free(base);
            const bytes = try snapshot.copy(a, .{ .start = 0, .end = snapshot.byteLen() });
            defer a.free(bytes);
            result.changes = try git.diffLines(a, base, bytes);
            result.changes_ready = true;
        };
    }
    pub fn discard(_: *Job, result: *Box) void {
        result.destroy();
    }
    pub fn deinit(self: *Job, _: std.mem.Allocator) void {
        a.free(self.root);
        if (self.comparison) |comparison| if (comparison.path) |path| a.free(path);
        if (self.path) |path| a.free(path);
        if (self.snapshot) |*snapshot| snapshot.deinit();
        switch (self.operation) {
            .diff => |r| a.free(r.path),
            .history, .stage, .unstage, .commit => |value| a.free(value),
            else => {},
        }
    }
};
pub fn start(self: *Shell, cx: *ui.Context(Shell), operation: Operation) !void {
    if (self.git.busy) {
        if (operation == .refresh) {
            self.git.needs_refresh = true;
            return;
        }
        return error.GitBusy;
    }
    if (self.git.generation == std.math.maxInt(u64)) return error.GitGenerationExhausted;
    var job: Job = .{ .io = self.workspace.io, .root = try a.dupe(u8, self.workspace.root_path), .operation = .refresh, .generation = self.git.generation + 1 };
    errdefer job.deinit(a);
    job.operation = switch (operation) {
        .diff => |r| .{ .diff = .{ .path = try a.dupe(u8, r.path), .staged = r.staged } },
        .history => |s| .{ .history = try a.dupe(u8, s) },
        .stage => |s| .{ .stage = try a.dupe(u8, s) },
        .unstage => |s| .{ .unstage = try a.dupe(u8, s) },
        .commit => |s| .{ .commit = try a.dupe(u8, s) },
        else => operation,
    };
    if (self.tabs.items.len > 0) {
        const id = if (self.active_pane == .secondary and self.secondary != null) self.secondary.?.document else self.tabs.items[self.active].document;
        const record = try self.workspace.getConst(id);
        job.snapshot = record.doc.snapshot();
        job.document = id;
        if (record.path) |path| job.path = try a.dupe(u8, path);
    }
    const mutation = switch (operation) {
        .stage, .unstage, .stage_all, .unstage_all, .commit => true,
        else => false,
    };
    if (mutation and self.panel == .git_diff and self.git.selected_commit.len == 0) job.comparison = .{ .path = if (self.git.selected_path.len > 0) try a.dupe(u8, self.git.selected_path) else null, .staged = self.git.staged_diff };
    _ = try cx.spawn(Job, job, complete);
    self.git.busy = true;
    if (operation == .diff) self.git.staged_diff = operation.diff.staged;
    if (operation == .all_diff) self.git.staged_diff = false;
    self.git.generation = job.generation;
    self.git.active_document = job.document;
    cx.notify();
}
fn complete(self: *Shell, cx: *ui.Context(Shell), result: anyerror!*Box) !void {
    self.git.busy = false;
    const box = result catch |err| {
        if (err != error.Canceled) try self.reportError(err);
        cx.notify();
        return;
    };
    if (box.value.?.generation != self.git.generation) return;
    var value = box.take();
    defer value.deinit();
    self.git.repository = value.found;
    if (value.status) |status| {
        if (self.git.status) |*old| old.deinit();
        self.git.status = status;
        self.git.status_generation = value.generation;
        value.status = null;
    }
    if (value.commits_ready) {
        git.deinitHistory(a, self.git.commits);
        self.git.commits = value.commits;
        value.commits = &.{};
    }
    if (value.diff) |diff| {
        if (self.git.diff) |*old| old.deinit();
        self.git.diff = diff;
        value.diff = null;
        self.git.diff_scroll.offset = 0;
    }
    a.free(self.git.error_text);
    self.git.error_text = value.error_text;
    value.error_text = &.{};
    if (value.changes_ready) if (value.document) |id| if (self.workspace.getConst(id)) |record| {
        if (record.doc.revision() == value.revision) {
            for (self.tabs.items) |*tab| if (std.meta.eql(tab.document, id)) {
                try installEditor(&tab.editor, &value);
            };
            if (self.secondary) |*pane| if (std.meta.eql(pane.document, id)) try installEditor(&pane.editor, &value);
        }
    } else |_| {};
    cx.notify();
    if (self.git.needs_refresh) {
        self.git.needs_refresh = false;
        try start(self, cx, .refresh);
    }
}
fn installEditor(editor: *@import("zircon_editor").Editor, result: *const Result) !void {
    const changes = try editor.allocator.alloc(@import("zircon_editor").GitChange, result.changes.len);
    for (result.changes, 0..) |change, i| changes[i] = .{ .kind = switch (change.kind) {
        .added => .added,
        .modified => .modified,
        .deleted => .deleted,
    }, .start = change.start, .end = change.end };
    if (result.blame) |blame| editor.setBlame(.{ .line = blame.line - 1, .revision = result.revision, .author = blame.author, .summary = blame.summary, .oid = blame.oid, .timestamp = blame.timestamp }) catch |err| {
        editor.allocator.free(changes);
        return err;
    };
    editor.allocator.free(editor.git_changes);
    editor.git_changes = changes;
    editor.git_revision = result.revision;
}
