//! Real repository queries/mutations run as entity-owned jobs. UI installation
//! checks document revisions and uses an explicit single-owner result handoff.
const std = @import("std");
const ui = @import("zircon_ui");
const git = @import("zircon_git");
const text = @import("zircon_text");
const workspace = @import("zircon_workspace");
const Shell = @import("../shell.zig").Shell;
const a = std.heap.page_allocator;
const BlameRequest = struct { line: usize, expanded: bool = true, document: ?workspace.DocumentId = null };
pub const Operation = union(enum) { refresh, all_diff, diff: struct { path: []const u8, staged: bool }, history: []const u8, stage: []const u8, unstage: []const u8, stage_all, unstage_all, commit: []const u8, blame: BlameRequest, network: git.Network, switch_branch: struct { name: []const u8, create: bool = false, track: bool = false }, stash_save: bool, stash_apply: struct { oid: []const u8, pop: bool }, stash_show: []const u8 };
const BlameTarget = struct { document: workspace.DocumentId, revision: u64, line: usize };
pub const Model = struct {
    projection: ?@import("../models/diff_layout.zig").Projection = null,
    diff_view: @import("../models/diff_layout.zig").State = .{},
    commit_focus: u64 = 0,
    diff_generation: u64 = 0,
    root_path: []u8 = &.{},
    active_document: ?workspace.DocumentId = null,
    status: ?git.Status = null,
    commits: []git.Commit = &.{},
    diff: ?git.Diff = null,
    references: ?git.References = null,
    selected_path: []u8 = &.{},
    selected_commit: []u8 = &.{},
    busy: bool = false,
    blame_target: ?BlameTarget = null,
    blame_changed_at: f64 = 0,
    blame_requested: bool = false,
    pending_blame: ?struct { document: workspace.DocumentId, revision: u64, request: BlameRequest } = null,
    repository: bool = false,
    menu: enum { none, network, changes, branches, stashes, fetch_remote, push_remote } = .none,
    combined: bool = false,
    stash_view: bool = false,
    picker_index: usize = 0,
    picker_scroll: ui.controls.Scroll = .{},
    stash_oid: []u8 = &.{},
    reveal_path: []u8 = &.{},
    stash_selected: ?usize = null,
    operation_label: []const u8 = "",
    generation: u64 = 0,
    status_generation: u64 = 0,
    needs_refresh: bool = false,
    needs_metadata: bool = true,
    pending_all_diff: bool = false,
    diff_scroll: ui.controls.Scroll = .{},
    sidebar_scroll: ui.controls.Scroll = .{},
    tree: @import("../models/git_tree.zig").Tree = .{},
    staged_diff: bool = false,
    error_text: []u8 = &.{},
    pub fn deinit(self: *Model) void {
        a.free(self.root_path);
        self.tree.deinit(a);
        self.diff_view.deinit(a);
        if (self.projection) |*projection| projection.deinit();
        if (self.status) |*value| value.deinit();
        git.deinitHistory(a, self.commits);
        if (self.diff) |*value| value.deinit();
        if (self.references) |*refs| refs.deinit();
        a.free(self.stash_oid);
        a.free(self.reveal_path);
        a.free(self.selected_path);
        a.free(self.selected_commit);
        a.free(self.error_text);
        self.* = undefined;
    }
};
const Result = struct {
    root_path: []u8 = &.{},
    projection: ?@import("../models/diff_layout.zig").Projection = null,
    found: bool = false,
    generation: u64,
    status: ?git.Status = null,
    commits: []git.Commit = &.{},
    commits_ready: bool = false,
    diff: ?git.Diff = null,
    references: ?git.References = null,
    reload_worktree: bool = false,
    blame: ?git.Blame = null,
    blame_message: []u8 = &.{},
    blame_expanded: bool = false,
    quiet_blame: bool = false,
    document: ?workspace.DocumentId = null,
    revision: u64 = 0,
    changes: []git.LineChange = &.{},
    changes_ready: bool = false,
    baseline: []u8 = &.{},
    error_text: []u8 = &.{},
    pub fn deinit(self: *Result) void {
        a.free(self.root_path);
        if (self.projection) |*projection| projection.deinit();
        if (self.status) |*v| v.deinit();
        if (self.references) |*refs| refs.deinit();
        git.deinitHistory(a, self.commits);
        if (self.diff) |*v| v.deinit();
        if (self.blame) |*v| v.deinit();
        a.free(self.blame_message);
        a.free(self.changes);
        a.free(self.baseline);
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
    include_references: bool = false,
    comparison: ?struct { path: ?[]u8, staged: bool, all: bool } = null,
    pub fn run(self: *Job, cancel: *ui.tasks.Cancellation) !*Box {
        try cancel.check();
        var result: Result = .{ .generation = self.generation, .document = self.document, .revision = if (self.snapshot) |s| s.revision() else 0 };
        errdefer result.deinit();
        var repo = (try git.Repository.discover(a, self.io, self.root)) orelse return Box.create(a, result);
        defer repo.deinit();
        result.found = true;
        result.root_path = try a.dupe(u8, repo.root);
        result.quiet_blame = self.operation == .blame and !self.operation.blame.expanded;
        self.perform(&repo, &result) catch |err| {
            if (result.quiet_blame) return Box.create(a, result);
            result.error_text = try std.fmt.allocPrint(a, "Git: {s}\n{s}", .{ @errorName(err), repo.lastError() });
            if (result.status == null) result.status = repo.status(a) catch null;
            if (result.references == null) result.references = repo.references(a) catch null;
        };
        try cancel.check();
        if (result.diff) |diff| result.projection = try @import("../models/diff_layout.zig").Projection.init(a, diff);
        return Box.create(a, result);
    }
    fn perform(self: *Job, repo: *git.Repository, result: *Result) !void {
        result.reload_worktree = switch (self.operation) {
            .switch_branch, .stash_save, .stash_apply => true,
            .network => |n| n == .pull,
            else => false,
        };
        switch (self.operation) {
            .network => |request| try repo.network(request),
            .switch_branch => |request| try repo.switchBranch(request.name, request.create, request.track),
            .stash_save => |all| try repo.stashSave(all),
            .stash_apply => |request| try repo.stashApply(request.oid, request.pop),
            .stash_show => |oid| result.diff = try repo.stashDiff(a, oid),
            .refresh => {},
            .all_diff => result.diff = try repo.allChanges(a),
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
            .blame => |request| if (self.path) |absolute| {
                const path = try repo.relativePath(a, absolute);
                defer a.free(path);
                const bytes = if (self.snapshot) |snapshot| try snapshot.copy(a, .{ .start = 0, .end = snapshot.byteLen() }) else null;
                defer if (bytes) |value| a.free(value);
                result.blame = try repo.blame(a, path, request.line, bytes);
                result.blame_expanded = request.expanded;
                if (request.expanded and !result.blame.?.uncommitted) result.blame_message = try repo.commitMessage(a, result.blame.?.oid);
                return;
            },
        }
        if (self.comparison) |comparison| result.diff = if (comparison.all) try repo.allChanges(a) else try repo.diff(a, comparison.path, comparison.staged);
        if (self.include_references) result.references = try repo.references(a);
        result.status = try repo.status(a);
        result.commits = try repo.history(a, 100);
        result.commits_ready = true;
        if (self.path) |absolute| if (self.snapshot) |snapshot| {
            const path = repo.relativePath(a, absolute) catch return;
            defer a.free(path);
            const base = try repo.baseline(a, path, .index);
            result.baseline = base;
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
            .history, .stage, .unstage, .commit, .stash_show => |value| a.free(value),
            .switch_branch => |r| a.free(r.name),
            .stash_apply => |r| a.free(r.oid),
            .network => |n| switch (n) {
                .fetch => |s| a.free(s),
                .push => |r| a.free(r.remote),
                else => {},
            },
            else => {},
        }
    }
};
pub fn start(self: *Shell, cx: *ui.Context(Shell), operation: Operation) !void {
    const changes_worktree = switch (operation) {
        .switch_branch, .stash_save, .stash_apply => true,
        .network => |n| n == .pull,
        else => false,
    };
    if (changes_worktree) for (self.tabs.items) |tab| {
        const record = try self.workspace.getConst(tab.document);
        if (record.path != null and record.dirty()) return error.SaveBeforeGitOperation;
    };
    if (operation == .blame) {
        if (self.tabs.items.len == 0) return error.NoDocument;
        const id = if (operation == .blame and operation.blame.document != null) operation.blame.document.? else if (self.active_pane == .secondary and self.secondary != null) self.secondary.?.document else self.tabs.items[self.active].document;
        if ((try self.workspace.getConst(id)).path == null) return error.UnsavedBlame;
        if (!self.git.busy and !self.git.repository) return error.NoBlameRepository;
    }
    if (self.git.busy) {
        if (operation == .all_diff) {
            self.git.pending_all_diff = true;
            return;
        }
        if (operation == .blame and self.tabs.items.len > 0) {
            const id = if (operation == .blame and operation.blame.document != null) operation.blame.document.? else if (self.active_pane == .secondary and self.secondary != null) self.secondary.?.document else self.tabs.items[self.active].document;
            self.git.pending_blame = .{ .document = id, .revision = (try self.workspace.getConst(id)).doc.revision(), .request = operation.blame };
            return;
        }
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
        .stash_show => |s| .{ .stash_show = try a.dupe(u8, s) },
        .switch_branch => |r| .{ .switch_branch = .{ .name = try a.dupe(u8, r.name), .create = r.create, .track = r.track } },
        .stash_apply => |r| .{ .stash_apply = .{ .oid = try a.dupe(u8, r.oid), .pop = r.pop } },
        .network => |n| .{ .network = switch (n) {
            .fetch => |r| .{ .fetch = try a.dupe(u8, r) },
            .push => |r| .{ .push = .{ .remote = try a.dupe(u8, r.remote), .publish = r.publish, .force_with_lease = r.force_with_lease } },
            .pull => |r| .{ .pull = r },
        } },
        else => operation,
    };
    if (self.tabs.items.len > 0) {
        const id = if (operation == .blame and operation.blame.document != null) operation.blame.document.? else if (self.active_pane == .secondary and self.secondary != null) self.secondary.?.document else self.tabs.items[self.active].document;
        const record = try self.workspace.getConst(id);
        job.snapshot = record.doc.snapshot();
        job.document = id;
        if (record.path) |path| job.path = try a.dupe(u8, path);
    }
    const mutation = switch (operation) {
        .stage, .unstage, .stage_all, .unstage_all, .commit, .network, .switch_branch, .stash_save, .stash_apply => true,
        else => false,
    };
    if (mutation and self.panel == .git_diff and self.git.selected_commit.len == 0) job.comparison = .{ .path = if (self.git.selected_path.len > 0) try a.dupe(u8, self.git.selected_path) else null, .staged = self.git.staged_diff, .all = self.git.combined };
    job.include_references = self.git.needs_metadata or self.git.references == null or switch (operation) {
        .network, .switch_branch, .stash_save, .stash_apply, .commit => true,
        else => false,
    };
    _ = try cx.spawn(Job, job, complete);
    if (job.include_references) self.git.needs_metadata = false;
    self.git.busy = true;
    self.git.operation_label = @tagName(operation);
    if (operation == .diff) self.git.staged_diff = operation.diff.staged;
    if (operation == .all_diff) self.git.staged_diff = false;
    self.git.generation = job.generation;
    if (operation != .blame) self.git.active_document = job.document;
    cx.notify();
}
fn complete(self: *Shell, cx: *ui.Context(Shell), result: anyerror!*Box) !void {
    self.git.busy = false;
    self.git.operation_label = "";
    const box = result catch |err| {
        if (err != error.Canceled) try self.reportError(err);
        cx.notify();
        return;
    };
    if (box.value.?.generation != self.git.generation) return;
    var value = box.take();
    defer value.deinit();
    self.git.repository = value.found;
    if (value.found) {
        a.free(self.git.root_path);
        self.git.root_path = value.root_path;
        value.root_path = &.{};
    }
    if (value.references) |refs| {
        if (self.git.references) |*old| old.deinit();
        self.git.references = refs;
        value.references = null;
    }
    if (value.reload_worktree) {
        self.git.needs_refresh = true;
        for (self.tabs.items) |*tab| if (try self.workspace.reloadClean(tab.document)) {
            const record = try self.workspace.getConst(tab.document);
            var snap = record.doc.snapshot();
            defer snap.deinit();
            tab.editor.synchronize(snap);
            tab.editor.hideBlame();
            if (self.secondary) |*pane| if (std.meta.eql(pane.document, tab.document)) pane.editor.synchronize(snap);
        };
        try @import("../actions.zig").refreshTree(self);
    }
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
        if (self.git.projection) |*old| old.deinit();
        self.git.projection = value.projection;
        value.projection = null;
        self.git.diff_view.active_hunk = null;
        self.git.diff_view.hover_file = null;
        self.git.diff_generation +%= 1;
        if (self.git.diff) |*old| old.deinit();
        self.git.diff = diff;
        value.diff = null;
        self.git.diff_scroll.offset = 0;
        if (self.git.reveal_path.len > 0) {
            if (@import("../views/git_diff.zig").fileOffset(diff, self.git.reveal_path, self.editor_options.font_size * self.editor_options.line_height)) |offset| self.git.diff_scroll.offset = offset;
            a.free(self.git.reveal_path);
            self.git.reveal_path = &.{};
        }
    }
    if (!value.quiet_blame) {
        a.free(self.git.error_text);
        self.git.error_text = value.error_text;
        value.error_text = &.{};
    }
    if (!self.inline_blame_enabled and !value.blame_expanded) if (value.blame) |*blame| {
        blame.deinit();
        value.blame = null;
    };
    if (value.changes_ready or value.blame != null) if (value.document) |id| if (self.workspace.getConst(id)) |record| {
        if (record.doc.revision() == value.revision) {
            for (self.tabs.items) |*tab| if (std.meta.eql(tab.document, id)) {
                try installEditor(&tab.editor, &value);
            };
            if (self.secondary) |*pane| if (std.meta.eql(pane.document, id)) try installEditor(&pane.editor, &value);
        }
    } else |_| {};
    cx.notify();
    if (self.git.pending_blame) |pending| {
        self.git.pending_blame = null;
        const id = if (self.active_pane == .secondary and self.secondary != null) self.secondary.?.document else if (self.tabs.items.len > 0) self.tabs.items[self.active].document else return;
        if (std.meta.eql(id, pending.document) and (try self.workspace.getConst(id)).doc.revision() == pending.revision) {
            try start(self, cx, .{ .blame = pending.request });
            return;
        }
    }
    if (self.git.pending_all_diff) {
        self.git.pending_all_diff = false;
        try start(self, cx, .all_diff);
        return;
    }
    if (self.git.needs_refresh) {
        self.git.needs_refresh = false;
        try start(self, cx, .refresh);
    }
}
fn installEditor(editor: *@import("zircon_editor").Editor, result: *const Result) !void {
    if (result.blame) |blame| {
        try editor.setBlame(.{ .line = blame.line - 1, .revision = result.revision, .author = blame.author, .summary = blame.summary, .oid = blame.oid, .timestamp = blame.timestamp, .email = blame.email, .message = result.blame_message, .uncommitted = blame.uncommitted, .expanded = result.blame_expanded and (editor.blame_hovered or editor.blame_pinned) });
    }
    if (!result.changes_ready) return;
    const baseline = try editor.allocator.dupe(u8, result.baseline);
    errdefer editor.allocator.free(baseline);
    const changes = try editor.allocator.alloc(@import("zircon_editor").GitChange, result.changes.len);
    errdefer editor.allocator.free(changes);
    var row: usize = 0;
    var cursor: usize = 0;
    for (result.changes, 0..) |change, i| {
        while (row < change.old_start and cursor < baseline.len) {
            cursor = if (std.mem.indexOfScalarPos(u8, baseline, cursor, '\n')) |at| at + 1 else baseline.len;
            row += 1;
        }
        const begin = cursor;
        while (row < change.old_end and cursor < baseline.len) {
            cursor = if (std.mem.indexOfScalarPos(u8, baseline, cursor, '\n')) |at| at + 1 else baseline.len;
            row += 1;
        }
        changes[i] = .{ .kind = switch (change.kind) {
            .added => .added,
            .modified => .modified,
            .deleted => .deleted,
        }, .start = change.start, .end = change.end, .old_start = change.old_start, .old_count = change.old_end - change.old_start, .removed = baseline[begin..cursor] };
        for (editor.git_changes) |previous| if (previous.start == change.start and previous.end == change.end and previous.old_start == change.old_start and std.mem.eql(u8, previous.removed, changes[i].removed)) {
            changes[i].expanded = previous.expanded;
            break;
        };
    }
    editor.allocator.free(editor.git_changes);
    editor.allocator.free(editor.git_baseline);
    editor.git_changes = changes;
    editor.git_baseline = baseline;
    editor.git_revision = result.revision;
}

/// Delay automatic blame until the current line settles. Results still bind to
/// the original document revision, so typing cannot install obsolete authorship.
pub fn pollBlame(self: *Shell, cx: *ui.Context(Shell)) !void {
    if (!self.inline_blame_enabled or !self.git.repository or self.panel != .editor or self.overlay != .none or self.tabs.items.len == 0) return;
    const pane = if (self.active_pane == .secondary and self.secondary != null) &self.secondary.? else null;
    const id = if (pane) |value| value.document else self.tabs.items[self.active].document;
    const state = if (pane) |value| &value.editor else &self.tabs.items[self.active].editor;
    if (state.inline_blame) |blame| if (blame.expanded) return;
    const record = try self.workspace.getConst(id);
    if (record.path == null) return;
    var snapshot = record.doc.snapshot();
    defer snapshot.deinit();
    const line = (try snapshot.pointAt(@min(state.primary().head, snapshot.byteLen()))).line;
    const target: BlameTarget = .{ .document = id, .revision = snapshot.revision(), .line = line };
    const now = if (self.window) |h| (try cx.app.window(h)).time else return;
    if (self.git.blame_target == null or !std.meta.eql(self.git.blame_target.?, target)) {
        self.git.blame_target = target;
        self.git.blame_changed_at = now;
        self.git.blame_requested = false;
    }
    if (self.git.blame_requested or self.git.busy or now - self.git.blame_changed_at < 0.3) return;
    self.git.blame_requested = true;
    if (state.inline_blame) |blame| if (blame.revision == snapshot.revision() and blame.line == line) return;
    try start(self, cx, .{ .blame = .{ .line = line + 1, .expanded = false } });
}
