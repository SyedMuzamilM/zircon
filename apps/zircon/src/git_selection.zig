//! Git selection uses ordinary editor commands over immutable projected text.
//! Mutations resolve and validate every selected source before any write.
const std = @import("std");
const editing = @import("zircon_editor");
const gui = @import("zircon_git_ui");
const multi = @import("zircon_multibuffer");
const text = @import("zircon_text");
const ui = @import("zircon_ui");
const actions = @import("actions.zig");
const commands = @import("commands.zig");
const autoscroll = @import("excerpt_autoscroll.zig");
const git_editing = @import("git_editing.zig");
const transactions = @import("multibuffer_editing.zig");
const shell = @import("shell.zig");
const Shell = shell.Shell;
const Review = gui.review.Review;
const Side = gui.review.Side;
const a = std.heap.page_allocator;

pub fn rebuild(self: *Shell) !void {
    const side: Side = if (self.git.diff_view.mode == .unified) .unified else if (self.git.review) |review| (if (review.side == .old) .old else .new) else .new;
    try install(self, side);
}

pub fn cancel(self: *Shell) void {
    self.git.selection_drag = null;
    if (self.git.review) |*review| review.editor.dragging = false;
}

/// A live source can change before its asynchronous patch refresh arrives.
/// Drop selections involving that source; immutable base/history text stays
/// selectable at its captured revision.
pub fn changed(self: *Shell, id: multi.SourceId) !void {
    const review = if (self.git.review) |*value| value else return;
    if (!review.focused or review.side == .old or self.git.selected_commit.len > 0 or self.git.staged_diff or self.git.stash_view) return;
    const record = try self.workspace.getConst(id);
    const path = record.path orelse return;
    const root = if (self.git.root_path.len > 0) self.git.root_path else self.workspace.root_path;
    const relative = try std.fs.path.relative(a, self.workspace.root_path, null, root, path);
    defer a.free(relative);
    const selected = review.editor.primary().range();
    const first = review.rowAt(selected.start) orelse return;
    const last = review.rowAt(if (selected.end > selected.start) selected.end - 1 else selected.end).?;
    for (review.rows[first .. last + 1]) |row| if (row.original.new_line != null and std.mem.eql(u8, row.path, relative)) {
        review.focused = false;
        cancel(self);
        return;
    };
}

pub fn poll(self: *Shell, cx: *ui.Context(Shell)) !void {
    const drag = if (self.git.selection_drag) |*value| value else return;
    const review = if (self.git.review) |*value| value else return cancel(self);
    if (!review.editor.dragging or self.currentTool(if (self.active_pane == .secondary) 1 else 0) != .git_diff) return cancel(self);
    const handle = self.window orelse return;
    const projection = self.git.projection orelse return;
    const max = @max(0, projection.contentHeight(&self.git.diff_view, review.editor.line_height) - drag.bounds.height);
    const offset = std.math.clamp(self.git.diff_scroll.offset + drag.delta(try cx.app.currentTime()), 0, max);
    if (offset == self.git.diff_scroll.offset) return;
    self.git.diff_scroll.offset = offset;
    var event: ui.Event(ui.Input) = .{ .data = .{ .pointer_move = .{ .position = drag.point } }, .bounds = drag.bounds, ._surface = (try cx.app.window(handle)).surface };
    _ = try surface(self, &event, cx);
}

fn install(self: *Shell, side: Side) !void {
    const diff = self.git.diff orelse return;
    const projection = self.git.projection orelse return;
    var next = try Review.init(a, diff, projection, &self.git.diff_view, side);
    if (self.git.review) |*previous| {
        next.retainSelection(previous);
        previous.deinit();
    }
    self.git.review = next;
}

const Resolved = struct { source: multi.SourceId, revision: u64, range: text.Range };

fn resolve(self: *Shell, row: gui.review.Row) !?Resolved {
    if (self.git.selected_commit.len > 0 or self.git.staged_diff or self.git.stash_view) return null;
    const review = &(self.git.review orelse return null);
    if (review.side == .old) return null;
    const number = row.original.new_line orelse return null;
    const destination = try git_editing.target(self, row.path, number -| 1) orelse return null;
    var snapshot = try self.workspace.snapshot(destination.document);
    defer snapshot.deinit();
    const range = try snapshot.lineRangeIncludingEnding(destination.row);
    const bytes = try snapshot.copy(a, range);
    defer a.free(bytes);
    var projected = review.document.snapshot();
    defer projected.deinit();
    const expected = try projected.copy(a, row.range);
    defer a.free(expected);
    // A stale patch must never edit a different line in a newer source.
    if (!std.mem.eql(u8, bytes, expected)) return null;
    return .{ .source = destination.document, .revision = snapshot.revision(), .range = range };
}

/// The returned edits consume only displayed live bytes. Omitted source gaps
/// and deleted/base text are never converted to a live document range.
fn plan(self: *Shell, replacement: []const u8) !?[]multi.SourceEdit {
    const review = &(self.git.review orelse return null);
    const selected = review.editor.primary().range();
    var result: std.ArrayList(multi.SourceEdit) = .empty;
    errdefer result.deinit(a);
    const first = review.rowAt(selected.start) orelse return null;
    for (review.rows[first..]) |row| {
        if (row.range.start >= selected.end and result.items.len > 0) break;
        const start = @max(selected.start, row.range.start);
        const end = @min(selected.end, row.range.end);
        if (start > end) continue;
        const source = try resolve(self, row) orelse {
            result.deinit(a);
            return null;
        };
        try result.append(a, .{ .source = source.source, .source_revision = source.revision, .range = .{ .start = source.range.start + start - row.range.start, .end = source.range.start + end - row.range.start }, .replacement = if (result.items.len == 0) replacement else "" });
        if (selected.end <= row.range.end) break;
    }
    if (result.items.len == 0) {
        result.deinit(a);
        return null;
    }
    return try result.toOwnedSlice(a);
}

/// Mirror a contiguous live selection into the existing source editor. This
/// preserves normal typing, IME, pairing and source history without a text copy.
fn synchronizeSource(self: *Shell, cx: *ui.Context(Shell)) !bool {
    self.git.editing.active = null;
    const edits = (try plan(self, "")) orelse return false;
    defer a.free(edits);
    const first = edits[0];
    var end = first.range.end;
    for (edits[1..]) |edit| {
        if (!std.meta.eql(first.source, edit.source) or edit.range.start != end) return false;
        end = edit.range.end;
    }
    const view = try git_editing.getView(self, first.source);
    var snapshot = try self.workspace.snapshot(first.source);
    defer snapshot.deinit();
    const selected = self.git.review.?.editor.primary();
    view.editor.selections.single(if (selected.anchor <= selected.head) .{ .anchor = first.range.start, .head = end } else .{ .anchor = end, .head = first.range.start });
    view.editor.edit_scope = git_editing.visibleRange(self, first.source, first.range.start);
    view.editor.dragging = false;
    view.editor.vim.cursor = view.editor.primary().head;
    view.editor.vim.anchor = view.editor.primary().anchor;
    self.git.editing.active = first.source;
    self.editor_focus_request +%= 1;
    cx.notify();
    return true;
}

fn replace(self: *Shell, cx: *ui.Context(Shell), replacement: []const u8) !void {
    const edits = (try plan(self, replacement)) orelse return;
    defer a.free(edits);
    try transactions.apply(self, cx, edits);
    self.git.review.?.focused = false;
    const first = edits[0];
    const view = try git_editing.getView(self, first.source);
    var snapshot = try self.workspace.snapshot(first.source);
    defer snapshot.deinit();
    const caret = first.range.start + replacement.len;
    try view.editor.setSelection(snapshot, .{ .start = caret, .end = caret });
    view.editor.edit_scope = null;
    self.git.editing.active = first.source;
    self.editor_focus_request +%= 1;
}

pub fn command(self: *Shell, cx: *ui.Context(Shell), which: commands.Command, event: *ui.Event(ui.Input)) !bool {
    const review = if (self.git.review) |*value| value else return false;
    if (which == .select_all) {
        if (review.rows.len == 0) return true;
        _ = try review.editor.execute(&review.document, .select_all);
        review.focused = true;
        self.editor_focus_request +%= 1;
        _ = try synchronizeSource(self, cx);
        cx.notify();
        return true;
    }
    if (!review.focused) return false;
    switch (which) {
        .copy, .cut => {
            if (which == .cut) {
                const edits = (try plan(self, "")) orelse return true;
                a.free(edits);
            }
            const original = event.data;
            defer event.data = original;
            event.data = .{ .key_down = .{ .key = .c, .modifiers = .{ .command = true } } };
            _ = try review.editor.handle(&review.document, event);
            if (which == .cut) try replace(self, cx, "");
        },
        .paste => {
            const edits = (try plan(self, "")) orelse return true;
            a.free(edits);
            if (try synchronizeSource(self, cx)) {
                review.focused = false;
                return false;
            }
            const bytes = try event.readClipboard(a);
            defer a.free(bytes);
            try replace(self, cx, bytes);
        },
        .undo, .redo, .delete_line, .toggle_comment => {
            if (!try synchronizeSource(self, cx)) return true;
            review.focused = false;
            return false;
        },
        else => return false,
    }
    cx.notify();
    return true;
}

fn configure(self: *const Shell, review: *Review) void {
    review.editor.font_size = self.editor_options.font_size;
    review.editor.line_height = self.editor_options.font_size * self.editor_options.line_height;
    review.editor.tab_width = self.editor_options.tab_width;
    review.editor.horizontal = if (self.editor_options.soft_wrap == .none) self.git.editing.horizontal else 0;
}

pub fn surface(self: *Shell, event: *ui.Event(ui.Input), cx: *ui.Context(Shell)) !bool {
    if (self.git.review == null) return false;
    const down = event.data == .pointer_down and event.data.pointer_down.button == .primary;
    if (event.data == .pointer_up and self.git.review.?.editor.dragging) {
        self.git.review.?.editor.dragging = false;
        self.git.selection_drag = null;
        event.releasePointer();
        event.stopPropagation();
        cx.notify();
        return true;
    }
    if (down or (event.data == .pointer_move and self.git.review.?.editor.dragging)) {
        const point = if (down) event.data.pointer_down.position else event.data.pointer_move.position;
        const side: Side = if (self.git.diff_view.mode == .unified) .unified else if (!down) self.git.review.?.side else if (point.x < event.bounds.x + event.bounds.width / 2) .old else .new;
        if (self.git.review.?.side != side) try install(self, side);
        const review = &self.git.review.?;
        configure(self, review);
        const lh = review.editor.line_height;
        self.git.selection_drag = autoscroll.Drag.track(self.git.selection_drag, point, event.bounds, try cx.app.currentTime());
        const at = review.hit(point.y - event.bounds.y + self.git.diff_scroll.offset, lh, !down) orelse {
            // Leave header controls available, but do not reinterpret split
            // alignment padding as a click in the live source editor.
            cancel(self);
            return true;
        };
        const row = review.rows[at];
        if (down and row.original.new_line != null and side != .old) {
            if (try git_editing.target(self, row.path, row.original.new_line.? -| 1) != null and try resolve(self, row) == null) {
                review.focused = false;
                cancel(self);
                return false;
            }
        }
        const bounds = event.bounds;
        defer event.bounds = bounds;
        event.bounds.y += row.top(lh) - self.git.diff_scroll.offset;
        event.bounds.height = lh;
        if (side != .unified) {
            event.bounds.width = (event.bounds.width - 1) / 2;
            if (side == .new) event.bounds.x += event.bounds.width + 1;
        }
        // Navigation's hidden-number gutter is 20px. Match the actual row's
        // source gutter, including unusually large source line numbers.
        var gutter: f32 = 20;
        if (self.editor_options.line_numbers) if (self.git.projection) |projection| {
            for (projection.files) |file| if (std.mem.eql(u8, file.path, row.path)) {
                gutter = editing.gutterWidth(file.max_line, self.editor_options.font_size);
                break;
            };
        };
        if (side != .old) if (row.original.new_line) |number| {
            if (try git_editing.target(self, row.path, number -| 1)) |destination| {
                var snapshot = try self.workspace.snapshot(destination.document);
                defer snapshot.deinit();
                if (self.git.editing.find(destination.document)) |view| gutter = if (view.editor.show_line_numbers) editing.gutterWidth(snapshot.lineCount(), self.editor_options.font_size) else 20;
            }
        };
        event.bounds.x += gutter - 20;
        var clicked_segment: ?editing.wrap.Row = null;
        if (row.segments.len > 0) {
            const local = @max(0, point.y - bounds.y + self.git.diff_scroll.offset - row.top(lh));
            const segment_index = @min(row.segments.len - 1, @as(usize, @intFromFloat(@floor(local / lh))));
            clicked_segment = row.segments[segment_index];
            event.bounds.x -= row.segments[segment_index].x;
        }
        review.editor.scroll.offset = @as(f32, @floatFromInt(at)) * lh;
        // Clamp Y into this text row so dragging through headers selects the
        // row found above rather than jumping to another projected line.
        const original = event.data;
        defer event.data = original;
        if (down) event.data.pointer_down.position.y = event.bounds.y + lh / 2 else event.data.pointer_move.position.y = event.bounds.y + lh / 2;
        _ = try review.editor.handle(&review.document, event);
        if (clicked_segment) |segment| if (!down or event.data.pointer_down.clicks == 1) {
            const selected = &review.editor.selections.items.items[0];
            selected.head = std.math.clamp(selected.head, row.range.start + segment.start, row.range.start + segment.end);
            if (down and !event.data.pointer_down.modifiers.shift) selected.anchor = selected.head;
        };
        review.focused = true;
        _ = try synchronizeSource(self, cx);
        event.capturePointer();
        event.focus();
        event.preventDefault();
        event.stopPropagation();
        cx.notify();
        return true;
    }
    const review = &self.git.review.?;
    if (!review.focused) return false;
    configure(self, review);
    if (self.key_bindings.resolveEditor(event.data)) |which| {
        if (try command(self, cx, which, event)) {
            event.preventDefault();
            event.stopPropagation();
            return true;
        }
    }
    if (event.data == .key_down) {
        const key = event.data.key_down;
        const navigation = switch (key.key) {
            .left, .right, .up, .down, .home, .end, .page_up, .page_down, .escape => true,
            .a, .e, .b, .f, .p, .n => key.modifiers.control and !key.modifiers.command,
            else => false,
        };
        if (navigation) {
            const vertical = !key.modifiers.command and !key.modifiers.alt and !key.modifiers.control and (key.key == .up or key.key == .down or key.key == .page_up or key.key == .page_down);
            if (vertical) try review.vertical(event, key.key, key.modifiers.shift) else _ = try review.editor.handle(&review.document, event);
            _ = try synchronizeSource(self, cx);
            const y = review.caretY() orelse return true;
            if (y < self.git.diff_scroll.offset) self.git.diff_scroll.offset = y;
            if (y + review.editor.line_height > self.git.diff_scroll.offset + event.bounds.height) self.git.diff_scroll.offset = @max(0, y + review.editor.line_height - event.bounds.height);
            event.preventDefault();
            event.stopPropagation();
            cx.notify();
            return true;
        }
    }
    if (event.data == .text or event.data == .edit or event.data == .unmark or event.data == .key_down) {
        if (try synchronizeSource(self, cx)) {
            review.focused = false;
            return false;
        }
        const bytes: ?[]const u8 = switch (event.data) {
            .text => |value| value,
            // Composition ranges belong to a single source's native snapshot.
            // Multi-source edits use explicit text/paste until a projected
            // surrounding-text contract exists.
            .edit => null,
            .key_down => |key| switch (key.key) {
                .backspace, .delete => "",
                .enter => "\n",
                .tab => "\t",
                else => null,
            },
            else => null,
        };
        if (bytes) |value| try replace(self, cx, value);
        event.preventDefault();
        event.stopPropagation();
        return true;
    }
    return false;
}
