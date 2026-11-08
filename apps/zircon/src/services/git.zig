//! Real repository queries/mutations run as entity-owned jobs. UI installation
//! checks document revisions and uses an explicit single-owner result handoff.
const std = @import("std");
const zircon_editor = @import("zircon_editor");
const git = @import("zircon_git");
const multibuffer = @import("zircon_multibuffer");
const text = @import("zircon_text");
const ui = @import("zircon_ui");
const workspace = @import("zircon_workspace");
const actions = @import("../actions.zig");
const git_editing = @import("../git_editing.zig");
const diff_layout = @import("../models/diff_layout.zig");
const git_tree = @import("../models/git_tree.zig");
const shell = @import("../shell.zig");
const views_git_diff = @import("../views/git_diff.zig");
const handoff = @import("handoff.zig");
const Shell = shell.Shell;
const a = std.heap.page_allocator;
const BlameRequest = struct { line: usize, expanded: bool = true, document: ?workspace.DocumentId = null };
pub const Operation = union(enum) { refresh, all_diff, diff: struct { path: []const u8, staged: bool }, history: []const u8, stage: []const u8, unstage: []const u8, stage_all, unstage_all, commit: []const u8, blame: BlameRequest, network: git.Network, switch_branch: struct { name: []const u8, create: bool = false, track: bool = false }, stash_save: bool, stash_apply: struct { oid: []const u8, pop: bool }, stash_show: []const u8 };
const BlameTarget = struct { document: workspace.DocumentId, revision: u64, line: usize };
pub const Presentation = struct {
    diff: ?git.Diff = null,
    projection: ?diff_layout.Projection = null,
    state: diff_layout.State = .{},
    scroll: ui.controls.Scroll = .{},
    message: []u8 = &.{},
    fn deinit(self: *Presentation) void {
        a.free(self.message);
        if (self.diff) |*diff| diff.deinit();
        if (self.projection) |*projection| projection.deinit();
        self.state.deinit(a);
    }
};
pub const HistoryTab = struct {
    oid: []u8,
    subject: []u8,
    pane: u8,
    presentation: ?Presentation = null,
    pub fn deinit(self: *HistoryTab) void {
        a.free(self.oid);
        a.free(self.subject);
        if (self.presentation) |*presentation| presentation.deinit();
    }
};
pub const Model = struct {
    /// Live source snapshots and excerpt identities shared by the diff editor.
    editable: ?multibuffer.MultiBuffer = null,
    editable_source: ?workspace.DocumentId = null,
    editing: git_editing.Model = .{},
    projection: ?diff_layout.Projection = null,
    diff_view: diff_layout.State = .{},
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
    history_tabs: std.ArrayList(HistoryTab) = .empty,
    commit_message: []u8 = &.{},
    working_presentation: ?Presentation = null,
    pending_history: ?[]u8 = null,
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
    next_refresh: f64 = 0,
    needs_metadata: bool = true,
    pending_all_diff: bool = false,
    diff_scroll: ui.controls.Scroll = .{},
    sidebar_scroll: ui.controls.Scroll = .{},
    tree: git_tree.Tree = .{},
    staged_diff: bool = false,
    error_text: []u8 = &.{},
    pub fn entryForPath(self: *const Model, path: []const u8) ?git.Entry {
        const status = self.status orelse return null;
        if (self.root_path.len == 0) return null;
        const root = std.mem.trimEnd(u8, self.root_path, "/");
        if (path.len <= root.len or !std.mem.startsWith(u8, path, root) or path[root.len] != '/') return null;
        return statusEntry(status.entries, path[root.len + 1 ..]);
    }
    pub fn deinit(self: *Model) void {
        self.editing.deinit();
        if (self.editable) |*value| value.deinit();
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
        a.free(self.commit_message);
        if (self.working_presentation) |*presentation| presentation.deinit();
        if (self.pending_history) |oid| a.free(oid);
        for (self.history_tabs.items) |*tab| tab.deinit();
        self.history_tabs.deinit(a);
        a.free(self.error_text);
        self.* = undefined;
    }
    pub fn clearEditable(self: *Model) void {
        if (self.editable) |*value| value.deinit();
        self.editable = null;
        self.editable_source = null;
    }
    pub fn setEditableSource(self: *Model, id: workspace.DocumentId, snapshot: text.Snapshot) !void {
        self.clearEditable();
        var projection = multibuffer.MultiBuffer.init(a);
        errdefer projection.deinit();
        try projection.addSource(id, snapshot);
        try projection.setExcerpts(id, &.{.{ .start = 0, .end = snapshot.byteLen() }});
        self.editable = projection;
        self.editable_source = id;
    }
    pub fn setEditableProjection(self: *Model, projection: multibuffer.MultiBuffer, source: ?workspace.DocumentId) void {
        self.clearEditable();
        self.editable = projection;
        self.editable_source = source;
    }
    fn stashPresentation(self: *Model) void {
        const presentation: Presentation = .{ .diff = self.diff, .projection = self.projection, .state = self.diff_view, .scroll = self.diff_scroll, .message = self.commit_message };
        self.diff = null;
        self.projection = null;
        self.diff_view = .{};
        self.diff_scroll = .{};
        self.commit_message = &.{};
        if (self.selected_commit.len > 0) {
            for (self.history_tabs.items) |*tab| if (std.mem.eql(u8, tab.oid, self.selected_commit)) {
                if (tab.presentation) |*old| old.deinit();
                tab.presentation = presentation;
                return;
            };
            var unused = presentation;
            unused.deinit();
        } else {
            if (self.working_presentation) |*old| old.deinit();
            self.working_presentation = presentation;
        }
    }
    fn restorePresentation(self: *Model, source: *?Presentation) void {
        if (source.*) |presentation| {
            self.diff = presentation.diff;
            self.projection = presentation.projection;
            self.diff_view = presentation.state;
            self.diff_scroll = presentation.scroll;
            self.commit_message = presentation.message;
            source.* = null;
        }
        self.diff_generation +%= 1;
    }
    pub fn showWorking(self: *Model) void {
        if (self.selected_commit.len == 0) return;
        self.stashPresentation();
        a.free(self.selected_commit);
        self.selected_commit = &.{};
        self.stash_view = false;
        self.restorePresentation(&self.working_presentation);
    }
    pub fn openHistoryTab(self: *Model, oid: []const u8, pane: u8) !void {
        if (std.mem.eql(u8, self.selected_commit, oid)) return;
        const selected = try a.dupe(u8, oid);
        errdefer a.free(selected);
        var found: ?usize = null;
        for (self.history_tabs.items, 0..) |tab, index| if (std.mem.eql(u8, tab.oid, oid)) {
            found = index;
            break;
        };
        if (found == null) {
            const owned = try a.dupe(u8, oid);
            errdefer a.free(owned);
            var subject: []const u8 = "Commit";
            for (self.commits) |commit| if (std.mem.eql(u8, commit.oid, oid)) {
                subject = commit.subject;
                break;
            };
            const owned_subject = try a.dupe(u8, subject);
            errdefer a.free(owned_subject);
            try self.history_tabs.append(a, .{ .oid = owned, .subject = owned_subject, .pane = pane });
            found = self.history_tabs.items.len - 1;
        }
        self.stashPresentation();
        a.free(self.selected_commit);
        self.selected_commit = selected;
        self.restorePresentation(&self.history_tabs.items[found.?].presentation);
    }
};
fn matchesPath(absolute: []const u8, relative: []const u8) bool {
    if (std.mem.eql(u8, absolute, relative)) return true;
    if (absolute.len <= relative.len or !std.mem.endsWith(u8, absolute, relative)) return false;
    const separator = absolute[absolute.len - relative.len - 1];
    return separator == '/' or separator == '\\';
}
pub fn ensureEditable(self: *Shell) !void {
    if (self.git.editable != null or self.git.selected_path.len == 0) return;
    for (self.tabs.items) |tab| {
        const record = try self.workspace.getConst(tab.document);
        if (record.path) |path| if (std.mem.endsWith(u8, path, self.git.selected_path)) {
            var snapshot = record.doc.snapshot();
            defer snapshot.deinit();
            try self.git.setEditableSource(tab.document, snapshot);
            return;
        };
    }
}
fn statusEntry(entries: []const git.Entry, path: []const u8) ?git.Entry {
    for (entries) |entry| if (std.mem.eql(u8, entry.path, path)) return entry;
    return null;
}
fn newFile(entry: git.Entry) bool {
    return !entry.conflicted and (entry.index == .added or entry.index == .untracked or entry.worktree == .untracked);
}
pub fn rebuildEditable(self: *Shell, diff: git.Diff) !void {
    // Opening a diff also loads the live documents that have no source tab yet.
    // Keep the selected pane and tool while adding them to workspace ownership.
    if (self.git.selected_commit.len == 0 and !self.git.staged_diff and !self.git.stash_view) {
        const old_active = self.active;
        const old_pane = self.active_pane;
        const old_panel = self.panel;
        const old_overlay = self.overlay;
        defer {
            self.active = old_active;
            self.active_pane = old_pane;
            self.panel = old_panel;
            self.overlay = old_overlay;
        }
        self.active_pane = .primary;
        var previous: []const u8 = "";
        for (diff.hunks) |hunk| {
            if (std.mem.eql(u8, previous, hunk.path)) continue;
            previous = hunk.path;
            const absolute = try std.fs.path.resolve(a, &.{ if (self.git.root_path.len > 0) self.git.root_path else self.workspace.root_path, hunk.path });
            defer a.free(absolute);
            var present = false;
            for (self.tabs.items) |tab| if ((try self.workspace.getConst(tab.document)).path) |path| if (std.mem.eql(u8, path, absolute)) {
                present = true;
                break;
            };
            if (!present) {
                const old_count = self.tabs.items.len;
                self.openPath(absolute) catch |err| switch (err) {
                    error.FileNotFound, error.InvalidUtf8 => continue,
                    else => return err,
                };
                if (self.tabs.items.len > old_count) self.tabs.items[self.tabs.items.len - 1].primary = false;
            }
        }
    }
    var projection = multibuffer.MultiBuffer.init(a);
    errdefer projection.deinit();
    var source: ?workspace.DocumentId = null;
    var source_count: usize = 0;
    for (self.tabs.items, 0..) |tab, tab_index| {
        const record = self.workspace.getConst(tab.document) catch continue;
        const path = record.path orelse continue;
        var duplicate = false;
        for (self.tabs.items[0..tab_index]) |previous| if (std.meta.eql(previous.document, tab.document)) {
            duplicate = true;
            break;
        };
        if (duplicate) continue;
        var included = false;
        for (diff.hunks) |hunk| if (matchesPath(path, hunk.path)) {
            included = true;
            break;
        };
        if (!included) continue;
        var snapshot = record.doc.snapshot();
        defer snapshot.deinit();
        try projection.addSource(tab.document, snapshot);
        try projection.setExcerpts(tab.document, &.{.{ .start = 0, .end = snapshot.byteLen() }});
        source = tab.document;
        source_count += 1;
    }
    self.git.setEditableProjection(projection, if (source_count == 1) source else null);
}
const SourceVersion = struct { document: workspace.DocumentId, revision: u64 };
const CapturedBuffer = struct { document: workspace.DocumentId, path: []u8, snapshot: text.Snapshot, dirty: bool };
const Result = struct {
    source_versions: []SourceVersion = &.{},
    history_oid: []u8 = &.{},
    message: []u8 = &.{},
    preserve_scroll: bool = false,
    root_path: []u8 = &.{},
    projection: ?diff_layout.Projection = null,
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
        a.free(self.source_versions);
        a.free(self.history_oid);
        a.free(self.message);
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
const Box = handoff.Handoff(Result);
const Job = struct {
    pub const Output = *Box;
    io: std.Io,
    buffers: []CapturedBuffer = &.{},
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
        if (self.operation == .history) {
            result.history_oid = try a.dupe(u8, self.operation.history);
            result.message = try repo.commitMessage(a, self.operation.history);
        }
        result.preserve_scroll = self.comparison != null;
        result.found = true;
        result.root_path = try a.dupe(u8, repo.root);
        result.quiet_blame = self.operation == .blame and !self.operation.blame.expanded;
        self.perform(&repo, &result) catch |err| {
            if (result.quiet_blame) return Box.create(a, result);
            result.error_text = try std.fmt.allocPrint(a, "Git: {s}\n{s}", .{ @errorName(err), repo.lastError() });
            if (result.status == null) result.status = repo.status(a) catch null;
            if (result.references == null) result.references = repo.references(a) catch null;
        };
        if (result.diff != null and self.operation != .history and self.operation != .stash_show and !(self.operation == .diff and self.operation.diff.staged) and !(self.comparison != null and self.comparison.?.staged)) {
            var inputs: std.ArrayList(git.buffer_diff.Buffer) = .empty;
            defer {
                for (inputs.items) |input| {
                    a.free(input.path);
                    a.free(input.before);
                    a.free(input.after);
                }
                inputs.deinit(a);
            }
            var versions: std.ArrayList(SourceVersion) = .empty;
            defer versions.deinit(a);
            for (self.buffers) |buffer| {
                try versions.append(a, .{ .document = buffer.document, .revision = buffer.snapshot.revision() });
                if (!buffer.dirty) continue;
                const path = repo.relativePath(a, buffer.path) catch continue;
                errdefer a.free(path);
                const selected_path = if (self.operation == .diff) self.operation.diff.path else if (self.comparison) |comparison| comparison.path else null;
                if (selected_path) |selected| if (!std.mem.eql(u8, selected, path)) {
                    a.free(path);
                    continue;
                };
                const before = try repo.baseline(a, path, if (self.operation == .all_diff or (self.comparison != null and self.comparison.?.all)) .head else .index);
                errdefer a.free(before);
                const after = try buffer.snapshot.copy(a, .{ .start = 0, .end = buffer.snapshot.byteLen() });
                errdefer a.free(after);
                try inputs.append(a, .{ .path = path, .before = before, .after = after });
            }
            if (inputs.items.len > 0) {
                const replacement = try git.buffer_diff.replace(a, result.diff.?, inputs.items);
                result.diff.?.deinit();
                result.diff = replacement;
            }
            result.source_versions = try versions.toOwnedSlice(a);
        }
        try cancel.check();
        if (result.diff) |diff| result.projection = try diff_layout.Projection.init(a, diff);
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
        if (self.include_references) {
            result.commits = try repo.history(a, 100);
            result.commits_ready = true;
        }
        if (self.path) |absolute| if (self.snapshot) |snapshot| {
            const path = repo.relativePath(a, absolute) catch return;
            defer a.free(path);
            const base = try repo.baseline(a, path, .index);
            result.baseline = base;
            const bytes = try snapshot.copy(a, .{ .start = 0, .end = snapshot.byteLen() });
            defer a.free(bytes);
            const entry = statusEntry(result.status.?.entries, path);
            if (entry == null or !newFile(entry.?)) result.changes = try git.diffLines(a, base, bytes);
            result.changes_ready = true;
        };
    }
    pub fn discard(_: *Job, result: *Box) void {
        result.destroy();
    }
    pub fn deinit(self: *Job, _: std.mem.Allocator) void {
        a.free(self.root);
        for (self.buffers) |*buffer| {
            a.free(buffer.path);
            buffer.snapshot.deinit();
        }
        a.free(self.buffers);
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
    if (operation == .diff or operation == .all_diff) try ensureEditable(self);
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
        if (operation == .history) {
            const pending = try a.dupe(u8, operation.history);
            if (self.git.pending_history) |old| a.free(old);
            self.git.pending_history = pending;
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
    if ((mutation or operation == .refresh) and (self.panel == .git_diff or self.secondary_tool == .git_diff) and self.git.selected_commit.len == 0) job.comparison = .{ .path = if (self.git.selected_path.len > 0) try a.dupe(u8, self.git.selected_path) else null, .staged = self.git.staged_diff, .all = self.git.combined };
    job.include_references = self.git.needs_metadata or self.git.references == null or switch (operation) {
        .network, .switch_branch, .stash_save, .stash_apply, .commit => true,
        else => false,
    };
    var buffers: std.ArrayList(CapturedBuffer) = .empty;
    defer buffers.deinit(a);
    errdefer for (buffers.items) |*buffer| {
        a.free(buffer.path);
        buffer.snapshot.deinit();
    };
    for (self.tabs.items) |tab| {
        const record = try self.workspace.getConst(tab.document);
        const path = record.path orelse continue;
        const owned = try a.dupe(u8, path);
        errdefer a.free(owned);
        try buffers.append(a, .{ .document = tab.document, .path = owned, .snapshot = record.doc.snapshot(), .dirty = record.dirty() });
    }
    job.buffers = try buffers.toOwnedSlice(a);
    _ = try cx.spawn(Job, job, complete);
    if (job.include_references) self.git.needs_metadata = false;
    self.git.busy = true;
    self.git.next_refresh = try cx.app.currentTime() + 1;
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
        try actions.refreshTree(self);
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
    var diff_stale = false;
    for (value.source_versions) |source| {
        const record = self.workspace.getConst(source.document) catch {
            diff_stale = true;
            break;
        };
        if (record.doc.revision() != source.revision) {
            diff_stale = true;
            break;
        }
    }
    if (diff_stale and value.diff != null) {
        value.diff.?.deinit();
        value.diff = null;
        self.git.pending_all_diff = true;
    }
    if (value.diff != null and !std.mem.eql(u8, value.history_oid, self.git.selected_commit)) {
        value.diff.?.deinit();
        value.diff = null;
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
        if (!value.preserve_scroll) self.git.diff_scroll.offset = 0;
        a.free(self.git.commit_message);
        self.git.commit_message = value.message;
        value.message = &.{};
        try rebuildEditable(self, diff);
        if (self.git.reveal_path.len > 0) {
            if (views_git_diff.fileOffset(diff, self.git.reveal_path, self.editor_options.font_size * self.editor_options.line_height)) |offset| self.git.diff_scroll.offset = offset;
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
    if (self.git.pending_history) |pending| {
        self.git.pending_history = null;
        defer a.free(pending);
        try start(self, cx, .{ .history = pending });
        return;
    }
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
fn installEditor(editor: *zircon_editor.Editor, result: *const Result) !void {
    if (result.blame) |blame| {
        try editor.setBlame(.{ .line = blame.line - 1, .revision = result.revision, .author = blame.author, .summary = blame.summary, .oid = blame.oid, .timestamp = blame.timestamp, .email = blame.email, .message = result.blame_message, .uncommitted = blame.uncommitted, .expanded = result.blame_expanded and (editor.blame_hovered or editor.blame_pinned) });
    }
    if (!result.changes_ready) return;
    const baseline = try editor.allocator.dupe(u8, result.baseline);
    errdefer editor.allocator.free(baseline);
    const changes = try editor.allocator.alloc(zircon_editor.GitChange, result.changes.len);
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
