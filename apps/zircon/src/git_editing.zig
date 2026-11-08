//! Live Git rows resolve through multibuffer source identities. Source documents
//! retain their own text and history; the diff owns only editor presentation.
const std = @import("std");
const ui = @import("zircon_ui");
const text = @import("zircon_text");
const editing = @import("zircon_editor");
const ws = @import("zircon_workspace");
const git = @import("zircon_git");
const Shell = @import("shell.zig").Shell;
const actions = @import("actions.zig");
const a = std.heap.page_allocator;

const View = struct { document: ws.DocumentId, editor: editing.Editor };
pub const Model = struct {
    views: std.ArrayList(View) = .empty,
    active: ?ws.DocumentId = null,
    pub fn deinit(self: *Model) void {
        for (self.views.items) |*view| view.editor.deinit();
        self.views.deinit(a);
        self.* = .{};
    }
    pub fn remove(self: *Model, id: ws.DocumentId) void {
        if (self.active) |active_id| if (std.meta.eql(active_id, id)) {
            self.active = null;
        };
        for (self.views.items, 0..) |view, index| if (std.meta.eql(view.document, id)) {
            var removed = self.views.orderedRemove(index);
            removed.editor.deinit();
            return;
        };
    }
    pub fn current(self: *const Model) ?*const View {
        const id = self.active orelse return null;
        for (self.views.items) |*view| if (std.meta.eql(view.document, id)) return view;
        return null;
    }
};
pub const Target = struct { document: ws.DocumentId, revision: u64, row: usize, generation: u64 };

pub fn target(self: *const Shell, path: []const u8, row: usize) !?Target {
    if (self.git.selected_commit.len > 0 or self.git.staged_diff or self.git.stash_view) return null;
    const projection = self.git.editable orelse return null;
    const absolute = try std.fs.path.resolve(a, &.{ if (self.git.root_path.len > 0) self.git.root_path else self.workspace.root_path, path });
    defer a.free(absolute);
    for (projection.sources.items) |source| {
        const record = self.workspace.getConst(source.id) catch continue;
        if (record.path == null or !std.mem.eql(u8, record.path.?, absolute)) continue;
        if (row >= source.snapshot.lineCount()) return null;
        var offset = try source.snapshot.lineStart(row);
        var revision = source.snapshot.revision();
        while (revision != record.doc.revision()) {
            var found = false;
            for (0..self.document_changes.len) |index| {
                const event = self.document_changes.get(index).?;
                if (!std.meta.eql(event.document, source.id) or event.before != revision) continue;
                if (event.mappings.len == 0) return null;
                const change: text.Change = .{ .allocator = event.allocator, .before = event.before, .after = event.after, .state = event.state, .mappings = event.mappings };
                offset = change.map(offset, .before);
                revision = event.after;
                found = true;
                break;
            }
            if (!found) return null;
        }
        var snapshot = record.doc.snapshot();
        defer snapshot.deinit();
        return .{ .document = source.id, .revision = revision, .row = (try snapshot.pointAt(offset)).line, .generation = self.git.diff_generation };
    }
    return null;
}

pub fn active(self: *const Shell) bool {
    return self.currentTool(if (self.active_pane == .secondary) 1 else 0) == .git_diff and self.git.selected_commit.len == 0 and !self.git.staged_diff and self.git.editing.active != null;
}

pub fn renderRow(self: *const Shell, b: *ui.Ui, original: git.Line, path: []const u8, fallback: ui.Element) !ui.Element {
    const row = original.new_line orelse return b.listen(fallback, .{ .focusable = true, .on_input = b.onInput(readOnly) });
    const destination = (try target(self, path, row -| 1)) orelse return fallback;
    var content = fallback;
    if (self.git.editing.current()) |view| if (std.meta.eql(view.document, destination.document)) {
        const record = try self.workspace.getConst(view.document);
        var snapshot = record.doc.snapshot();
        defer snapshot.deinit();
        if ((try snapshot.pointAt(view.editor.primary().head)).line == destination.row) {
            // This borrowed copy changes only presentation values. render copies
            // selections and retains immutable text/cache references for the frame.
            var state = view.editor;
            state.scroll.offset = @as(f32, @floatFromInt(destination.row)) * state.line_height;
            state.theme.background = self.colors.document;
            if (original.kind == .addition) {
                const tint = self.colors.added;
                const base = self.colors.document;
                state.theme.background = .{ .r = base.r * 0.86 + tint.r * 0.14, .g = base.g * 0.86 + tint.g * 0.14, .b = base.b * 0.86 + tint.b * 0.14, .a = 1 };
            }
            state.highlight_active_line = false;
            content = try b.styled(try state.render(&record.doc, b), .{ .height = .{ .px = state.line_height }, .flex_grow = 0, .flex_shrink = 0, .overflow = .hidden });
            content = try b.key(.{ .string = "git-diff-editor" }, content);
            content = try b.requestFocus(content, self.editor_focus_request);
        }
    };
    return b.listen(content, .{ .focusable = true, .on_input = b.onInputWith(input, destination) });
}

fn readOnly(self: *Shell, e: *ui.Event(ui.Input), cx: *ui.Context(Shell)) void {
    if (e.data == .pointer_down) {
        self.git.editing.active = null;
        e.focus();
        cx.notify();
    }
    if (e.data == .text or e.data == .edit) {
        e.preventDefault();
        e.stopPropagation();
    }
}

fn getView(self: *Shell, id: ws.DocumentId) !*View {
    for (self.git.editing.views.items) |*view| if (std.meta.eql(view.document, id)) return view;
    var editor = try editing.Editor.init(a);
    errdefer editor.deinit();
    const record = try self.workspace.getConst(id);
    self.configureEditor(&editor, record.path orelse "");
    editor.soft_wrap = .none;
    editor.show_fold_controls = false;
    editor.show_git_gutters = false;
    editor.show_indent_guides = false;
    var snapshot = record.doc.snapshot();
    defer snapshot.deinit();
    editor.synchronize(snapshot);
    try self.git.editing.views.append(a, .{ .document = id, .editor = editor });
    return &self.git.editing.views.items[self.git.editing.views.items.len - 1];
}

fn input(self: *Shell, e: *ui.Event(ui.Input), cx: *ui.Context(Shell), destination: Target) !void {
    if (e.data == .scroll) return;
    if (destination.generation != self.git.diff_generation or self.git.selected_commit.len > 0 or self.git.staged_diff) return;
    const record = self.workspace.get(destination.document) catch return;
    if (e.data == .pointer_down and record.doc.revision() != destination.revision) {
        e.preventDefault();
        cx.notify();
        return;
    }
    const view = try getView(self, destination.document);
    self.git.editing.active = destination.document;
    view.editor.scroll.offset = @as(f32, @floatFromInt(destination.row)) * view.editor.line_height;
    // Patch rows and the source editor use the same source-line gutter.
    if (e.data == .pointer_down) {
        self.editor_focus_request +%= 1;
        e.focus();
    }
    var outcome = try view.editor.handle(&record.doc, e);
    const changed = outcome.change != null or outcome.reset;
    try actions.applyOutcome(self, cx, view.document, 2, &outcome, .typing);
    if (outcome.request_project_search) try actions.execute(self, cx, .project_search, e);
    if (changed) try @import("services/git.zig").start(self, cx, .refresh);
    if (outcome.handled) {
        e.preventDefault();
        e.stopPropagation();
        cx.notify();
    }
}

pub fn command(self: *Shell, cx: *ui.Context(Shell), which: @import("commands.zig").Command) !bool {
    if (!active(self)) return false;
    const id = self.git.editing.active.?;
    const record = try self.workspace.get(id);
    const view = try getView(self, id);
    if (which == .save) {
        try self.workspace.save(id, null);
    } else {
        const command_value: editing.Command = switch (which) {
            .undo => .undo,
            .redo => .redo,
            .select_all => .select_all,
            .delete_line => .delete_line,
            .toggle_comment => .toggle_comment,
            else => return false,
        };
        var outcome = try view.editor.execute(&record.doc, command_value);
        try actions.applyOutcome(self, cx, id, 2, &outcome, if (which == .undo) .undo else if (which == .redo) .redo else .project_edit);
    }
    try @import("services/git.zig").start(self, cx, .refresh);
    cx.notify();
    return true;
}
