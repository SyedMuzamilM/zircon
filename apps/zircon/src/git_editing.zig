//! Live Git rows resolve through multibuffer source identities. Source documents
//! retain their own text and history; the diff owns only editor presentation.
const std = @import("std");
const editing = @import("zircon_editor");
const git = @import("zircon_git");
const zircon_git_ui = @import("zircon_git_ui");
const text = @import("zircon_text");
const ui = @import("zircon_ui");
const ws = @import("zircon_workspace");
const actions = @import("actions.zig");
const commands = @import("commands.zig");
const git_selection = @import("git_selection.zig");
const multibuffer_editing = @import("multibuffer_editing.zig");
const services_git = @import("services/git.zig");
const shell = @import("shell.zig");
const Shell = shell.Shell;
const a = std.heap.page_allocator;

pub const Model = zircon_git_ui.Editors;
const View = zircon_git_ui.SourceEditor;
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

pub fn renderRow(self: *const Shell, b: *ui.Ui, original: git.Line, path: []const u8, fallback: ui.Element, width: f32) !ui.Element {
    const row = original.new_line orelse return b.fluent().adopt(fallback).listeners(.{ .focusable = true, .on_input = b.onInput(readOnly) }).build();
    const destination = (try target(self, path, row -| 1)) orelse return fallback;
    if (try renderBlock(self, b, original, path, 1, width)) |block| return block;
    return b.fluent().adopt(fallback).listeners(.{ .focusable = true, .on_input = b.onInputWith(input, destination) }).build();
}

pub fn renderBlock(self: *const Shell, b: *ui.Ui, original: git.Line, path: []const u8, count: usize, width: f32) !?ui.Element {
    const row = original.new_line orelse return null;
    const destination = (try target(self, path, row -| 1)) orelse return null;
    const view = self.git.editing.find(destination.document) orelse return null;
    const record = try self.workspace.getConst(view.document);
    var snapshot = record.doc.snapshot();
    defer snapshot.deinit();
    const caret = (try snapshot.pointAt(view.editor.primary().head)).line;
    const has_caret = self.git.editing.active != null and std.meta.eql(self.git.editing.active.?, view.document) and caret >= destination.row and caret < destination.row + count;
    // One source canvas per contiguous run, with source-relative selections.
    // Header/deletion blocks remain outside the editable source ranges.
    var state = view.editor;
    var projected_selection: [1]editing.Selection = undefined;
    if (self.git.review) |*review| if (review.focused) {
        var selected: ?text.Range = null;
        const range = review.editor.primary().range();
        if (range.start < range.end) {
            const first = review.rowAt(range.start) orelse 0;
            const last = review.rowAt(range.end - 1) orelse first;
            for (review.rows[first .. last + 1]) |item| {
                if (!std.mem.eql(u8, item.path, path) or item.original.new_line == null or review.side == .old) continue;
                const number = item.original.new_line.?;
                if (number < row or number >= row + count) continue;
                const start = @max(range.start, item.range.start);
                const end = @min(range.end, item.range.end);
                if (start >= end) continue;
                const source_start = try snapshot.lineStart(destination.row + number - row);
                if (selected == null) selected = .{ .start = source_start + start - item.range.start, .end = source_start + end - item.range.start } else selected.?.end = source_start + end - item.range.start;
            }
        }
        state.selections.items = .empty;
        if (selected) |range_value| {
            projected_selection[0] = .{ .anchor = range_value.start, .head = range_value.end };
            state.selections.items.items = &projected_selection;
            state.selections.items.capacity = 1;
        } else if (has_caret) {
            projected_selection[0] = view.editor.primary();
            state.selections.items.items = &projected_selection;
            state.selections.items.capacity = 1;
        }
    };
    state.horizontal = self.git.editing.horizontal;
    state.show_scrollbars = false;
    state.soft_wrap = self.editor_options.soft_wrap;
    const gutter = if (state.show_line_numbers) editing.gutterWidth(snapshot.lineCount(), state.font_size) else 20;
    if (state.soft_wrap != .none) {
        const metrics = (try b.frame.app.?.window(self.window.?)).surface.?.measurer();
        try state.wrap_cache.ensure(snapshot, width - gutter - 12, state.font_size, state.tab_width, metrics);
    }
    state.scroll.offset = state.rowY(destination.row, snapshot.revision());
    state.theme.background = self.colors.document;
    if (original.kind == .addition) {
        const tint = self.colors.added;
        const base = self.colors.document;
        state.theme.background = .{ .r = base.r * 0.86 + tint.r * 0.14, .g = base.g * 0.86 + tint.g * 0.14, .b = base.b * 0.86 + tint.b * 0.14, .a = 1 };
    }
    state.highlight_active_line = has_caret and self.editor_options.active_line;
    state.theme.active_line.a = 0.16;
    state.theme.inactive_selection = state.theme.selection;
    const additions: [1]editing.GitChange = .{.{ .kind = .added, .start = destination.row, .end = destination.row + count }};
    if (original.kind == .addition) {
        state.show_git_gutters = true;
        state.git_changes = @constCast(&additions);
        state.git_revision = snapshot.revision();
    }
    var canvas = try state.renderExcerpt(&record.doc, b, count);
    if (has_caret) canvas = try b.fluent().adopt(canvas).id(.{ .string = "git-diff-editor" }).listeners(.{ .focusable = true }).request_focus(self.editor_focus_request).build();
    var markers: std.ArrayList(ui.Element) = .empty;
    var height: f32 = 0;
    for (0..count) |i| {
        const source_row = destination.row + i;
        const line_height = state.rowY(source_row + 1, snapshot.revision()) - state.rowY(source_row, snapshot.revision());
        height += line_height;
        try markers.append(b.allocator(), try b.fluent().div().h_px(line_height).shrink_0().id(.{ .string = try std.fmt.allocPrint(b.allocator(), "git-live:{s}:{d}", .{ path, row + i }) }).build());
    }
    return try b.fluent().stack().h_px(height).shrink_0().overflow_hidden().children(.{
        canvas, b.fluent().column().children(markers.items),
    }).listeners(.{ .focusable = true, .on_input = b.onInputWith(input, destination) }).id(.{ .string = try std.fmt.allocPrint(b.allocator(), "git-excerpt:{s}:{d}", .{ path, row }) }).build();
}

/// The multibuffer surface owns focus and pointer capture across frame rebuilds.
/// Source canvases may appear/disappear when the active excerpt changes.
pub fn surface(self: *Shell, e: *ui.Event(ui.Input), cx: *ui.Context(Shell)) !void {
    if (try git_selection.surface(self, e, cx)) return;
    if (self.git.selected_commit.len > 0 or self.git.staged_diff or self.git.stash_view) return;
    if (e.data == .pointer_up) {
        if (self.git.editing.active) |id| {
            const view = try getView(self, id);
            if (view.editor.dragging) {
                view.editor.dragging = false;
                e.releasePointer();
                e.stopPropagation();
                cx.notify();
            }
        }
        return;
    }
    if (e.data == .pointer_down or e.data == .pointer_move) {
        const point = if (e.data == .pointer_down) e.data.pointer_down.position else e.data.pointer_move.position;
        if (e.data == .pointer_move) {
            const current = self.git.editing.current() orelse return;
            if (!current.editor.dragging) return;
        }
        const projection = self.git.projection orelse return;
        const diff = self.git.diff orelse return;
        const lh = self.editor_options.font_size * self.editor_options.line_height;
        const hit = projection.hit(diff, &self.git.diff_view, lh, point.y - e.bounds.y + self.git.diff_scroll.offset) orelse return;
        if (self.git.diff_view.mode == .split and point.x < e.bounds.x + e.bounds.width / 2) {
            if (e.data == .pointer_down) self.git.editing.active = null;
            return;
        }
        const destination = (try target(self, hit.path, hit.source_row)) orelse return;
        if (e.data == .pointer_move) if (self.git.editing.active) |id| if (!std.meta.eql(id, destination.document)) return;
        const previous_bounds = e.bounds;
        defer e.bounds = previous_bounds;
        e.bounds.y += hit.top - self.git.diff_scroll.offset;
        e.bounds.height = lh;
        if (self.git.diff_view.mode == .split) {
            e.bounds.x += e.bounds.width / 2 + 1;
            e.bounds.width /= 2;
        }
        try input(self, e, cx, destination);
    } else if (e.data == .text or e.data == .edit or e.data == .key_down or e.data == .unmark) {
        if (try navigate(self, e, cx)) return;
        const id = self.git.editing.active orelse return;
        const record = try self.workspace.getConst(id);
        const view = try getView(self, id);
        var snapshot = record.doc.snapshot();
        defer snapshot.deinit();
        const destination: Target = .{ .document = id, .revision = snapshot.revision(), .row = (try snapshot.pointAt(view.editor.primary().head)).line, .generation = self.git.diff_generation };
        const bounds = e.bounds;
        defer e.bounds = bounds;
        if (self.git.diff_view.mode == .split) {
            e.bounds.width = (bounds.width - 1) / 2;
            e.bounds.x += e.bounds.width + 1;
        }
        try input(self, e, cx, destination);
    }
}

fn navigate(self: *Shell, event: *ui.Event(ui.Input), cx: *ui.Context(Shell)) !bool {
    if (event.data != .key_down) return false;
    const key = event.data.key_down;
    if (key.modifiers.command or key.modifiers.control or key.modifiers.alt) return false;
    if (key.key != .up and key.key != .down and key.key != .left and key.key != .right) return false;
    const current = self.git.editing.current() orelse return false;
    const projection = self.git.projection orelse return false;
    const diff = self.git.diff orelse return false;
    const sources = self.git.editable orelse return false;
    const record = try self.workspace.getConst(current.document);
    if (try sources.sourceRevision(current.document) != record.doc.revision()) return false;
    const absolute = record.path orelse return false;
    const root = if (self.git.root_path.len > 0) self.git.root_path else self.workspace.root_path;
    if (absolute.len <= root.len) return false;
    var before = record.doc.snapshot();
    defer before.deinit();
    const point = try before.pointAt(current.editor.primary().head);
    const line = try before.lineRange(point.line);
    if (key.key == .left and current.editor.primary().head > line.start) return false;
    if (key.key == .right and current.editor.primary().head < line.end) return false;
    const forward = key.key == .down or key.key == .right;
    if ((key.key == .up or key.key == .down) and current.editor.soft_wrap != .none and current.editor.wrap_cache.valid(before.revision())) {
        const cache = current.editor.wrap_cache;
        const visual = cache.atOffset(current.editor.primary().head);
        if (forward and visual + 1 < cache.rows.items.len and cache.rows.items[visual + 1].line == point.line) return false;
        if (!forward and visual > 0 and cache.rows.items[visual - 1].line == point.line) return false;
    }
    const next = projection.adjacent(diff, &self.git.diff_view, absolute[root.len + 1 ..], point.line, forward);
    if (next) |hit| {
        const destination = (try target(self, hit.path, hit.source_row)) orelse return false;
        const same_source = std.meta.eql(destination.document, current.document);
        const consecutive = if (forward) destination.row == point.line + 1 else point.line > 0 and destination.row == point.line - 1;
        if (same_source and consecutive) return false;
        if (!key.modifiers.shift) {
            const target_record = try self.workspace.getConst(destination.document);
            var snapshot = target_record.doc.snapshot();
            defer snapshot.deinit();
            const range = try snapshot.lineRange(destination.row);
            var at = if (key.key == .right) range.start else if (key.key == .left) range.end else range.start + @min(point.byte_column, range.end - range.start);
            while (!snapshot.isBoundary(at)) at -= 1;
            const view = try getView(self, destination.document);
            try view.editor.setSelection(snapshot, .{ .start = at, .end = at });
            view.editor.edit_scope = visibleRange(self, destination.document, at);
            view.editor.vim.cursor = at;
            view.editor.vim.anchor = at;
            self.git.editing.active = destination.document;
            self.editor_focus_request +%= 1;
            try reveal(self, cx, view);
        }
    }
    event.preventDefault();
    event.stopPropagation();
    cx.notify();
    return true;
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

pub fn getView(self: *Shell, id: ws.DocumentId) !*View {
    for (self.git.editing.views.items) |*view| if (std.meta.eql(view.document, id)) return view;
    var editor = try editing.Editor.init(a);
    errdefer editor.deinit();
    const record = try self.workspace.getConst(id);
    self.configureEditor(&editor, record.path orelse "");
    editor.soft_wrap = self.editor_options.soft_wrap;
    editor.show_fold_controls = false;
    editor.show_git_gutters = false;
    editor.show_indent_guides = self.editor_options.indent_guides;
    var snapshot = record.doc.snapshot();
    defer snapshot.deinit();
    editor.synchronize(snapshot);
    for (self.tabs.items) |tab| if (std.meta.eql(tab.document, id) and tab.editor.grammar_revision == snapshot.revision()) {
        try editor.setHighlights(snapshot, tab.editor.grammar_spans);
        break;
    };
    try self.git.editing.views.append(a, .{ .document = id, .editor = editor });
    return &self.git.editing.views.items[self.git.editing.views.items.len - 1];
}

pub fn visibleRange(self: *const Shell, id: ws.DocumentId, at: usize) ?text.Range {
    const projection = self.git.editable orelse return null;
    const record = self.workspace.getConst(id) catch return null;
    for (projection.excerpts.items) |excerpt| {
        if (!std.meta.eql(excerpt.value.source, id)) continue;
        var range = excerpt.value.source_range;
        var revision = projection.sourceRevision(id) catch return null;
        while (revision != record.doc.revision()) {
            var found = false;
            for (0..self.document_changes.len) |i| {
                const event = self.document_changes.get(i).?;
                if (!std.meta.eql(event.document, id) or event.before != revision) continue;
                if (event.mappings.len == 0) return null;
                const change: text.Change = .{ .allocator = event.allocator, .before = event.before, .after = event.after, .state = event.state, .mappings = event.mappings };
                range.start = change.map(range.start, .before);
                range.end = change.map(range.end, .after);
                revision = event.after;
                found = true;
                break;
            }
            if (!found) return null;
        }
        if (at >= range.start and at <= range.end) return range;
    }
    return null;
}

fn input(self: *Shell, e: *ui.Event(ui.Input), cx: *ui.Context(Shell), destination: Target) !void {
    if (e.data == .scroll) return;
    if (destination.generation != self.git.diff_generation or self.git.selected_commit.len > 0 or self.git.staged_diff) return;
    const history_command = self.key_bindings.resolve(e.data);
    if (history_command == .undo or history_command == .redo) {
        if (try multibuffer_editing.travel(self, cx, destination.document, if (history_command == .undo) .undo else .redo)) {
            e.preventDefault();
            return;
        }
    }
    const record = self.workspace.get(destination.document) catch return;
    if (e.data == .pointer_down and record.doc.revision() != destination.revision) {
        e.preventDefault();
        cx.notify();
        return;
    }
    const view = try getView(self, destination.document);
    if (e.data == .pointer_down or view.editor.edit_scope == null) {
        var snapshot = record.doc.snapshot();
        defer snapshot.deinit();
        const at = if (e.data == .pointer_down) try snapshot.lineStart(@min(destination.row, snapshot.lineCount() - 1)) else view.editor.primary().head;
        view.editor.edit_scope = visibleRange(self, destination.document, at) orelse return;
    }
    self.git.editing.active = destination.document;
    view.editor.scroll.offset = view.editor.rowY(destination.row, record.doc.revision());
    // Patch rows and the source editor use the same source-line gutter.
    if (e.data == .pointer_down) {
        self.editor_focus_request +%= 1;
        e.focus();
    }
    var outcome = view.editor.handle(&record.doc, e) catch |err| switch (err) {
        error.CrossExcerptEdit => editing.Outcome{ .handled = true },
        else => return err,
    };
    const changed = outcome.change != null or outcome.reset;
    if (outcome.reset) view.editor.edit_scope = null;
    if (!changed) if (view.editor.edit_scope) |scope| {
        for (view.editor.selections.items.items) |*selection| {
            selection.anchor = std.math.clamp(selection.anchor, scope.start, scope.end);
            selection.head = std.math.clamp(selection.head, scope.start, scope.end);
        }
    };
    try actions.applyOutcome(self, cx, view.document, 2, &outcome, .typing);
    if (outcome.request_project_search) try actions.execute(self, cx, .project_search, e);
    if (changed) try services_git.bufferChanged(self, cx);
    if (outcome.handled) {
        if (e.data == .key_down or changed) {
            self.editor_focus_request +%= 1;
            try reveal(self, cx, view);
        }
        e.preventDefault();
        e.stopPropagation();
        cx.notify();
    }
}

fn contentBounds(self: *const Shell, cx: *ui.Context(Shell)) ?ui.Rect {
    const handle = self.window orelse return null;
    const window = cx.app.window(handle) catch return null;
    const frame = &window.frames.committed;
    for (frame.nodes.items, 0..) |node, index| if (node.key) |key| if (key == .string and std.mem.eql(u8, key.string, "git-diff-lines")) return frame.bounds[index];
    return null;
}

fn reveal(self: *Shell, cx: *ui.Context(Shell), view: *const View) !void {
    const projection = self.git.projection orelse return;
    const diff = self.git.diff orelse return;
    const bounds = contentBounds(self, cx) orelse return;
    const record = try self.workspace.getConst(view.document);
    const absolute = record.path orelse return;
    const root = if (self.git.root_path.len > 0) self.git.root_path else self.workspace.root_path;
    if (absolute.len <= root.len) return;
    var snapshot = record.doc.snapshot();
    defer snapshot.deinit();
    const row = (try snapshot.pointAt(view.editor.primary().head)).line;
    var y = projection.sourceOffset(diff, &self.git.diff_view, absolute[root.len + 1 ..], row, view.editor.line_height) orelse return;
    if (view.editor.soft_wrap != .none and view.editor.wrap_cache.valid(snapshot.revision())) {
        const cache = view.editor.wrap_cache;
        y += @as(f32, @floatFromInt(cache.atOffset(view.editor.primary().head) - cache.starts.items[row])) * view.editor.line_height;
    }
    if (y < self.git.diff_scroll.offset) self.git.diff_scroll.offset = y;
    if (y + view.editor.line_height > self.git.diff_scroll.offset + bounds.height) self.git.diff_scroll.offset = @max(0, y + view.editor.line_height - bounds.height);
}

pub fn command(self: *Shell, cx: *ui.Context(Shell), which: commands.Command) !bool {
    if (self.currentTool(if (self.active_pane == .secondary) 1 else 0) != .git_diff) return false;
    var projected_event: ui.Event(ui.Input) = .{ .data = .{ .text = "" } };
    if (self.window) |handle| projected_event._surface = (try cx.app.window(handle)).surface;
    if (try git_selection.command(self, cx, which, &projected_event)) return true;
    if (which == .save) {
        if (self.git.selected_commit.len == 0 and !self.git.staged_diff and !self.git.stash_view) {
            for (self.git.editing.views.items) |view| {
                if (try self.workspace.dirty(view.document)) try self.workspace.save(view.document, null);
            }
            try services_git.start(self, cx, .refresh);
            cx.notify();
        }
        return true;
    }
    if (which == .zoom_in or which == .zoom_out) {
        self.editor_options.font_size = std.math.clamp(self.editor_options.font_size + @as(f32, if (which == .zoom_in) 1 else -1), 10, 26);
        for (self.git.editing.views.items) |*view| {
            view.editor.font_size = self.editor_options.font_size;
            view.editor.line_height = self.editor_options.font_size * self.editor_options.line_height;
        }
        cx.notify();
        return true;
    }
    if (!active(self)) return switch (which) {
        .undo, .redo, .select_all, .delete_line, .toggle_comment, .cut, .copy, .paste => true,
        else => false,
    };
    const id = self.git.editing.active.?;
    if (which == .undo or which == .redo) if (try multibuffer_editing.travel(self, cx, id, if (which == .undo) .undo else .redo)) return true;
    const record = try self.workspace.get(id);
    const view = try getView(self, id);
    const command_value: editing.Command = switch (which) {
        .undo => .undo,
        .redo => .redo,
        .select_all => .select_all,
        .delete_line => .delete_line,
        .toggle_comment => .toggle_comment,
        else => return false,
    };
    var outcome = view.editor.execute(&record.doc, command_value) catch |err| switch (err) {
        error.CrossExcerptEdit => editing.Outcome{ .handled = true },
        else => return err,
    };
    if (which == .undo or which == .redo) view.editor.edit_scope = null;
    try actions.applyOutcome(self, cx, id, 2, &outcome, if (which == .undo) .undo else if (which == .redo) .redo else .project_edit);
    try services_git.bufferChanged(self, cx);
    cx.notify();
    return true;
}

pub fn clipboard(self: *Shell, cx: *ui.Context(Shell), event: *ui.Event(ui.Input)) !void {
    const id = self.git.editing.active orelse return;
    const record = try self.workspace.get(id);
    const view = try getView(self, id);
    var outcome = try view.editor.handle(&record.doc, event);
    const changed = outcome.change != null;
    try actions.applyOutcome(self, cx, id, 2, &outcome, .typing);
    if (changed) try services_git.bufferChanged(self, cx);
}
