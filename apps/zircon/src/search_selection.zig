//! Projected selections belong to the result page, including pointer capture.
const std = @import("std");
const multi = @import("zircon_multibuffer");
const text = @import("zircon_text");
const ui = @import("zircon_ui");
const actions = @import("actions.zig");
const commands = @import("commands.zig");
const autoscroll = @import("excerpt_autoscroll.zig");
const transactions = @import("multibuffer_editing.zig");
const search = @import("search_editing.zig");
const shell = @import("shell.zig");
const search_view = @import("views/project_search.zig");
const Shell = shell.Shell;
const a = std.heap.page_allocator;

pub fn cancel(self: *Shell) void {
    self.search.editing.dragging = @splat(false);
    self.search.editing.autoscroll = @splat(null);
}

pub fn poll(self: *Shell, cx: *ui.Context(Shell)) !void {
    const handle = self.window orelse return;
    for (0..2) |index| {
        const drag = if (self.search.editing.autoscroll[index]) |*value| value else continue;
        if (!self.search.editing.dragging[index] or self.currentTool(@intCast(index)) != .search) {
            self.search.editing.autoscroll[index] = null;
            continue;
        }
        const max = @max(0, try search_view.contentHeight(self) - drag.bounds.height);
        const offset = std.math.clamp(self.search.editing.scroll[index].offset + drag.delta(try cx.app.currentTime()), 0, max);
        if (offset == self.search.editing.scroll[index].offset) continue;
        self.search.editing.scroll[index].offset = offset;
        var event: ui.Event(ui.Input) = .{ .data = .{ .pointer_move = .{ .position = drag.point } }, .bounds = drag.bounds, ._surface = (try cx.app.window(handle)).surface };
        try pointer(self, &event, cx, @intCast(index));
    }
}

pub fn range(self: *const Shell, pane: u8) ?multi.ProjectedRange {
    const model = &self.search.editing;
    return model.projection.selectionRange(model.selection[pane] orelse return null) catch null;
}

pub fn cross(self: *const Shell, pane: u8) bool {
    const selected = self.search.editing.selection[pane] orelse return false;
    return !std.meta.eql(selected.anchor.excerpt, selected.head.excerpt);
}

pub fn paint(self: *const Shell, pane: u8, source: search.Excerpt) ?text.Range {
    const selected = range(self, pane) orelse return null;
    const projected = self.search.editing.projection.projectedRange(source.id) catch return null;
    const first = std.math.clamp(selected.start, projected.start, projected.end);
    const last = std.math.clamp(selected.end, projected.start, projected.end);
    return .{ .start = source.range.start + first - projected.start, .end = source.range.start + last - projected.start };
}

pub fn sync(self: *Shell, pane: u8, source: search.Excerpt, extend: bool) !void {
    const current = try search.view(self, pane, source.document);
    const selection = current.editor.primary();
    const model = &self.search.editing;
    const head: multi.Position = .{ .excerpt = source.id, .offset = selection.head };
    const anchor: multi.Position = if (extend and model.selection[pane] != null) model.selection[pane].?.anchor else .{ .excerpt = source.id, .offset = selection.anchor };
    model.selection[pane] = .{ .anchor = anchor, .head = head };
}

pub fn command(self: *Shell, cx: *ui.Context(Shell), pane: u8, which: commands.Command, event: *ui.Event(ui.Input)) !bool {
    const model = &self.search.editing;
    if (which == .select_all and model.projection.excerpts.items.len > 0) {
        const first = model.projection.excerpts.items[0].value;
        const last = model.projection.excerpts.items[model.projection.excerpts.items.len - 1].value;
        model.selection[pane] = .{ .anchor = .{ .excerpt = first.id, .offset = first.source_range.start }, .head = .{ .excerpt = last.id, .offset = last.source_range.end } };
        try activate(self, cx, pane, model.selection[pane].?.head);
        cx.notify();
        return true;
    }
    if (!cross(self, pane)) return false;
    switch (which) {
        .copy, .cut => {
            const bytes = try model.projection.copy(a, range(self, pane).?);
            defer a.free(bytes);
            try event.writeClipboard(bytes);
            if (which == .cut) try replace(self, cx, pane, "");
        },
        .paste => {
            const bytes = try event.readClipboard(a);
            defer a.free(bytes);
            try replace(self, cx, pane, bytes);
        },
        else => return false,
    }
    cx.notify();
    return true;
}

pub fn input(self: *Shell, cx: *ui.Context(Shell), pane: u8, event: *ui.Event(ui.Input)) !bool {
    if (self.key_bindings.resolveEditor(event.data)) |which| {
        if (try command(self, cx, pane, which, event)) return true;
        if (which == .undo or which == .redo) if (self.search.editing.panes[pane].active) |id| {
            if (try transactions.travel(self, cx, id, if (which == .undo) .undo else .redo)) return true;
        };
    }
    if (!cross(self, pane)) return false;
    switch (event.data) {
        .text => |bytes| try replace(self, cx, pane, bytes),
        .edit => |edit| {
            const id = self.search.editing.panes[pane].active orelse return false;
            if (edit.revision != (try self.workspace.getConst(id)).doc.revision()) return error.StaleTextSnapshot;
            if (edit.composing) return error.CrossSourceCompositionUnsupported;
            try replace(self, cx, pane, edit.text);
        },
        .key_down => |key| switch (key.key) {
            .backspace, .delete => try replace(self, cx, pane, ""),
            .enter => try replace(self, cx, pane, "\n"),
            .tab => try replace(self, cx, pane, "\t"),
            .escape => {
                const head = self.search.editing.selection[pane].?.head;
                self.search.editing.selection[pane] = .{ .anchor = head, .head = head };
                try activate(self, cx, pane, head);
            },
            else => return false,
        },
        else => return false,
    }
    return true;
}

fn replace(self: *Shell, cx: *ui.Context(Shell), pane: u8, bytes: []const u8) !void {
    const model = &self.search.editing;
    const selected = range(self, pane) orelse return;
    const first = try model.projection.positionAt(selected.start, .after);
    const edits = try model.projection.edits(a, selected, bytes);
    defer a.free(edits);
    try transactions.apply(self, cx, edits);
    const caret: multi.Position = .{ .excerpt = first.excerpt, .offset = first.offset + bytes.len };
    model.selection[pane] = .{ .anchor = caret, .head = caret };
    try activate(self, cx, pane, caret);
}

pub fn activate(self: *Shell, cx: *ui.Context(Shell), pane: u8, position: multi.Position) !void {
    const model = &self.search.editing;
    for (model.files.items, 0..) |file, group| for (file.excerpts, 0..) |id, index| if (std.meta.eql(id.id, position.excerpt)) {
        const source = try search.excerpt(self, group, index) orelse return;
        const current = try search.view(self, pane, source.document);
        var snapshot = try self.workspace.snapshot(source.document);
        defer snapshot.deinit();
        try current.editor.setSelection(snapshot, .{ .start = position.offset, .end = position.offset });
        if (model.selection[pane]) |selected| {
            const anchor = if (std.meta.eql(selected.anchor.excerpt, position.excerpt)) selected.anchor.offset else if (try model.projection.projectedOffset(selected.anchor) < try model.projection.projectedOffset(position)) source.range.start else source.range.end;
            current.editor.selections.single(.{ .anchor = anchor, .head = position.offset });
        }
        current.editor.edit_scope = source.range;
        model.panes[pane].active = source.document;
        model.active_excerpt[pane] = source.id;
        _ = try actions.ensureTab(self, source.document);
        try search.reveal(self, cx, .{ .group = @intCast(group), .excerpt = @intCast(index), .generation = model.generation, .revision = snapshot.revision(), .first_row = source.first_row, .pane = pane }, position.offset);
        self.editor_focus_request +%= 1;
        return;
    };
}

/// Hit testing uses the whole page so dragging survives excerpt virtualization.
pub fn pointer(self: *Shell, event: *ui.Event(ui.Input), cx: *ui.Context(Shell), pane: u8) !void {
    const model = &self.search.editing;
    if (event.data == .pointer_up and model.dragging[pane]) {
        model.dragging[pane] = false;
        model.autoscroll[pane] = null;
        event.releasePointer();
        event.stopPropagation();
        cx.notify();
        return;
    }
    const down = event.data == .pointer_down and event.data.pointer_down.button == .primary;
    if (!down and (event.data != .pointer_move or !model.dragging[pane])) return;
    const point = if (down) event.data.pointer_down.position else event.data.pointer_move.position;
    model.autoscroll[pane] = autoscroll.Drag.track(model.autoscroll[pane], point, event.bounds, try cx.app.currentTime());
    const results = self.search.results orelse return;
    const lh = self.editor_options.font_size * self.editor_options.line_height;
    const y = point.y - event.bounds.y + model.scroll[pane].offset;
    var top: f32 = 0;
    for (results.groups, 0..) |group, group_index| {
        top += 36;
        for (group.excerpts, 0..) |_, index| {
            const source = try search.excerpt(self, group_index, index) orelse {
                top += 40;
                continue;
            };
            const height = @as(f32, @floatFromInt(source.rows)) * lh;
            if ((y >= top and y < top + height) or (!down and (y < top + height or (group_index + 1 == results.groups.len and index + 1 == group.excerpts.len)))) {
                const current = try search.view(self, pane, source.document);
                var snapshot = try self.workspace.snapshot(source.document);
                defer snapshot.deinit();
                current.editor.scroll.offset = @as(f32, @floatFromInt(source.first_row)) * lh;
                const previous_bounds = event.bounds;
                defer event.bounds = previous_bounds;
                event.bounds.y += top - model.scroll[pane].offset;
                event.bounds.height = height;
                const at = std.math.clamp(try current.editor.offsetAtPoint(snapshot, event, point), source.range.start, source.range.end);
                const head: multi.Position = .{ .excerpt = source.id, .offset = at };
                const extend = !down or event.data.pointer_down.modifiers.shift;
                if (!extend or model.selection[pane] == null) {
                    var outcome = try current.editor.handle(&(try self.workspace.get(source.document)).doc, event);
                    defer if (outcome.change) |*change| change.deinit();
                    current.editor.dragging = false;
                    try sync(self, pane, source, false);
                } else model.selection[pane].?.head = head;
                model.dragging[pane] = true;
                self.active_pane = if (pane == 1 and self.secondary != null) .secondary else .primary;
                try activate(self, cx, pane, model.selection[pane].?.head);
                event.capturePointer();
                event.preventDefault();
                event.stopPropagation();
                cx.notify();
                return;
            }
            top += height + 12;
        }
    }
}
