//! Language edits are prepared for every target before any text is published.
const std = @import("std");
const editor = @import("zircon_editor");
const lsp = @import("zircon_language");
const text = @import("zircon_text");
const ui = @import("zircon_ui");
const ws = @import("zircon_workspace");
const actions = @import("../actions.zig");
const shell = @import("../shell.zig");
const Shell = shell.Shell;

pub const Revision = struct { document: ws.DocumentId, revision: u64 };
pub const Pending = struct {
    document: ws.DocumentId,
    session: usize,
    request: u64,
    revision: u64,
    documents: []const Revision = &.{},
    allocator: ?std.mem.Allocator = null,

    pub fn capture(self: *Pending, workspace: *const ws.Workspace, a: std.mem.Allocator) !void {
        var revisions: std.ArrayList(Revision) = .empty;
        errdefer revisions.deinit(a);
        for (workspace.slots.items, 0..) |slot, index| if (slot.record) |record| {
            try revisions.append(a, .{ .document = .{ .workspace = workspace.identity, .slot = @intCast(index), .generation = slot.generation }, .revision = record.doc.revision() });
        };
        self.documents = try revisions.toOwnedSlice(a);
        self.allocator = a;
    }

    pub fn deinit(self: *Pending) void {
        if (self.allocator) |a| a.free(self.documents);
        self.* = undefined;
    }

    pub fn validateSource(self: Pending, workspace: *const ws.Workspace) !void {
        const record = workspace.getConst(self.document) catch return error.StaleWorkspaceEdit;
        if (record.doc.revision() != self.revision) return error.StaleWorkspaceEdit;
    }

    fn validateTarget(self: Pending, workspace: *const ws.Workspace, id: ws.DocumentId, version: ?u64) !void {
        const record = try workspace.getConst(id);
        if (version) |expected| if (record.doc.revision() != expected) return error.StaleWorkspaceEdit;
        if (std.meta.eql(id, self.document)) {
            if (record.doc.revision() != self.revision) return error.StaleWorkspaceEdit;
            return;
        }
        for (self.documents) |stamp| if (std.meta.eql(stamp.document, id)) {
            if (record.doc.revision() != stamp.revision) return error.StaleWorkspaceEdit;
            return;
        };
        // A target opened after the request can only use its untouched disk text.
        if (record.dirty() or record.doc.revision() != 0) return error.StaleWorkspaceEdit;
    }
};

const Target = struct { id: ws.DocumentId, tab: usize, edits: []const text.Edit };

pub fn apply(self: *Shell, cx: *ui.Context(Shell), pending: Pending, files: []const lsp.FileEdits, origin: ws.ChangeOrigin) !void {
    try pending.validateSource(&self.workspace);
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const targets = try a.alloc(Target, files.len);
    // Resolve and validate every source range before adding tabs or preparing edits.
    for (files, targets, 0..) |file, *target, index| {
        const path = try lsp.filePath(a, file.uri);
        const id = try self.workspace.open(path);
        for (targets[0..index]) |previous| if (std.meta.eql(previous.id, id)) return error.DuplicateWorkspaceEdit;
        try pending.validateTarget(&self.workspace, id, file.version);
        var snapshot = try self.workspace.snapshot(id);
        defer snapshot.deinit();
        const edits = try a.alloc(text.Edit, file.edits.len);
        for (file.edits, edits) |edit, *actual| actual.* = .{ .range = .{ .start = try lsp.offsetAt(snapshot, edit.range.start), .end = try lsp.offsetAt(snapshot, edit.range.end) }, .text = edit.new_text };
        std.mem.sort(text.Edit, edits, {}, struct {
            fn less(_: void, lhs: text.Edit, rhs: text.Edit) bool {
                return lhs.range.start < rhs.range.start;
            }
        }.less);
        // Document.prepare checks overlaps and UTF-8 without changing text.
        const record = try self.workspace.get(id);
        var checked = try record.doc.prepare(snapshot.revision(), edits, 0);
        checked.deinit();
        target.* = .{ .id = id, .tab = 0, .edits = edits };
    }
    // Normal tabs own every edited document, including files opened by the server.
    for (targets) |*target| {
        target.tab = for (self.tabs.items, 0..) |tab, index| {
            if (std.meta.eql(tab.document, target.id)) break index;
        } else blk: {
            var view = try editor.Editor.init(self.allocator);
            errdefer view.deinit();
            const record = try self.workspace.getConst(target.id);
            self.configureEditor(&view, record.path orelse "");
            var snapshot = record.doc.snapshot();
            defer snapshot.deinit();
            view.synchronize(snapshot);
            try self.tabs.append(self.allocator, .{ .document = target.id, .editor = view });
            break :blk self.tabs.items.len - 1;
        };
    }
    const prepared = try a.alloc(editor.Editor.PreparedEdit, targets.len);
    var count: usize = 0;
    defer for (prepared[0..count]) |*edit| edit.deinit();
    const group = try editor.Editor.freshGroup();
    for (targets, prepared) |target, *edit| {
        const record = try self.workspace.get(target.id);
        edit.* = try self.tabs.items[target.tab].editor.prepareEdits(&record.doc, target.edits, group, .preserve);
        count += 1;
    }
    const outcomes = try a.alloc(editor.Outcome, targets.len);
    // No event dispatch or allocation between these commits. All candidates,
    // history entries and selections were reserved above.
    for (prepared, outcomes) |*edit, *outcome| outcome.* = edit.commit() catch unreachable;
    var failure: ?anyerror = null;
    for (targets, outcomes) |target, *outcome| {
        // Publication still runs if a dependent presentation refresh fails.
        actions.applyOutcome(self, cx, target.id, 0, outcome, origin) catch |err| {
            if (failure == null) failure = err;
        };
    }
    cx.notify();
    if (failure) |err| return err;
}
