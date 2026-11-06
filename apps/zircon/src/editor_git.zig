//! Git decorations have independent targets: the thin change strip expands
//! source hunks; author metadata opens a hover card without moving source rows.
const std = @import("std");
const ui = @import("zircon_ui");
const editing = @import("zircon_editor");
const text = @import("zircon_text");
const Shell = @import("shell.zig").Shell;
const annotations = editing.annotations;
pub fn handle(self: *Shell, cx: *ui.Context(Shell), state: *editing.Editor, document: *const text.Document, id: @import("zircon_workspace").DocumentId, e: *ui.Event(ui.Input)) !bool {
    var snapshot = document.snapshot();
    defer snapshot.deinit();
    const pointer: ?ui.Point = switch (e.data) {
        .pointer_move, .pointer_down => |p| p.position,
        .scroll => |p| p.position,
        else => null,
    };
    const point = pointer orelse return false;
    if (e.data == .pointer_down and e.data.pointer_down.button == .primary and point.x >= e.bounds.x and point.x < e.bounds.x + 14) {
        for (state.visibleChanges(snapshot.revision()), 0..) |change, index| {
            if (state.wrap_cache.folding.hidden(try snapshot.lineStart(@min(change.start, snapshot.lineCount() - 1)))) continue;
            var marker = annotations.marker(change, state.visibleChanges(snapshot.revision()), state.line_height, e.bounds, state.scroll.offset);
            if (state.projected() and state.wrap_cache.valid(snapshot.revision())) {
                marker.y = e.bounds.y + state.rowY(change.start, snapshot.revision()) - state.scroll.offset - (if (change.expanded) @as(f32, @floatFromInt(change.old_count)) * state.line_height else 0);
                if (change.end > change.start) marker.height = state.rowY(change.end, snapshot.revision()) - state.rowY(change.start, snapshot.revision()) + (if (change.expanded) @as(f32, @floatFromInt(change.old_count)) * state.line_height else 0);
            }
            marker.x = e.bounds.x;
            marker.width = 14;
            if (change.kind == .deleted and !change.expanded) {
                marker.y -= 3;
                marker.height += 6;
            }
            if (!annotations.contains(marker, point)) continue;
            state.git_changes[index].expanded = !state.git_changes[index].expanded;
            e.preventDefault();
            cx.notify();
            return true;
        }
    }
    const blame = if (state.inline_blame) |*value| value else return false;
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const geometry = (try editing.blame_view.layout(arena.allocator(), snapshot, blame.*, state.visibleChanges(snapshot.revision()), .{ .source_y = if (state.projected() and state.wrap_cache.valid(snapshot.revision())) state.wrap_cache.rowY(state.wrap_cache.starts.items[blame.line + 1] - 1, state.line_height, state.visibleChanges(snapshot.revision())) else null, .source_x = if (state.projected() and state.wrap_cache.valid(snapshot.revision())) state.wrap_cache.rows.items[state.wrap_cache.starts.items[blame.line + 1] - 1].x else 0, .font = state.font_size, .line_height = state.line_height, .gutter = if (state.show_line_numbers) editing.gutterWidth(snapshot.lineCount(), state.font_size) else 20, .horizontal = state.horizontal, .scroll = state.scroll.offset, .tab_width = state.tab_width }, try e.textMetrics(), e.bounds)) orelse return false;
    const on_label = annotations.contains(geometry.label, point);
    const bridge_top = @min(geometry.label.y + geometry.label.height, geometry.card.y + geometry.card.height);
    const bridge_bottom = @max(geometry.label.y, geometry.card.y);
    const bridge: ui.Rect = .{ .x = geometry.card.x, .y = bridge_top, .width = geometry.card.width, .height = @max(0, bridge_bottom - bridge_top) };
    const on_card = blame.expanded and (annotations.contains(geometry.card, point) or annotations.contains(bridge, point));
    if (e.data == .pointer_move) {
        state.blame_bounds = e.bounds;
        const was_hovered = state.blame_hovered;
        state.blame_hovered = on_label or on_card;
        if (state.blame_hovered and !was_hovered) {
            state.blame_message_scroll = 0;
            if (blame.message.len > 0 or blame.uncommitted) blame.expanded = true else try @import("services/git.zig").start(self, cx, .{ .blame = .{ .line = blame.line + 1, .document = id } });
            cx.notify();
        } else if (!state.blame_hovered and !state.blame_pinned and blame.expanded) {
            blame.expanded = false;
            cx.notify();
        }
        return false;
    }
    if (on_card and e.data == .scroll) {
        state.blame_message_scroll = std.math.clamp(state.blame_message_scroll - e.data.scroll.y, 0, @max(0, geometry.content_height - geometry.message.height));
        e.preventDefault();
        cx.notify();
        return true;
    }
    if (e.data == .pointer_down and e.data.pointer_down.button == .primary) {
        if (on_card) {
            if (annotations.contains(geometry.copy, point) and !blame.uncommitted) try e.writeClipboard(blame.oid);
            if (annotations.contains(geometry.close, point)) {
                blame.expanded = false;
                state.blame_hovered = false;
                state.blame_pinned = false;
            }
            e.preventDefault();
            cx.notify();
            return true;
        }
        if (on_label) {
            state.blame_pinned = true;
            state.blame_hovered = true;
            if (blame.message.len > 0 or blame.uncommitted) blame.expanded = true else try @import("services/git.zig").start(self, cx, .{ .blame = .{ .line = blame.line + 1, .document = id } });
            e.preventDefault();
            cx.notify();
            return true;
        }
        if (blame.expanded) {
            blame.expanded = false;
            state.blame_pinned = false;
            state.blame_hovered = false;
            cx.notify();
        }
    }
    return false;
}

pub fn dismissOutside(self: *Shell, cx: *ui.Context(Shell), e: *ui.Event(ui.Input)) void {
    const point: ?ui.Point = if (e.data == .pointer_move) e.data.pointer_move.position else null;
    const leaving = e.data == .pointer_leave or (e.data == .focus and !e.data.focus);
    for (self.tabs.items) |*tab| dismissState(&tab.editor, point, leaving, cx);
    if (self.secondary) |*pane| dismissState(&pane.editor, point, leaving, cx);
}
fn dismissState(state: *editing.Editor, point: ?ui.Point, leaving: bool, cx: *ui.Context(Shell)) void {
    if (state.blame_pinned or !state.blame_hovered) return;
    if (leaving or (point != null and !annotations.contains(state.blame_bounds, point.?))) {
        state.blame_hovered = false;
        if (state.inline_blame) |*blame| blame.expanded = false;
        cx.notify();
    }
}
