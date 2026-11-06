//! Editor custom element. It owns an immutable document root, copies visible
//! lines into frame storage, and publishes a bounded surrounding-text excerpt.
const std = @import("std");
const ui = @import("zircon_ui");
const text = @import("zircon_text");
const editor = @import("editor.zig");
const selection = @import("selections.zig");
const syntax = @import("syntax.zig");
const display = @import("display.zig");
const annotations = @import("annotations.zig");
const line_limit = 64 * 1024;
pub fn gutterWidth(lines: usize, font_size: f32) f32 {
    var digits: usize = 1;
    var remaining = lines;
    while (remaining >= 10) : (remaining /= 10) digits += 1;
    return @max(52, @as(f32, @floatFromInt(digits)) * font_size * 0.62 + 24);
}
pub fn render(state: *const editor.Editor, document: *const text.Document, b: *ui.Ui) !ui.Element {
    var snapshot = document.snapshot();
    errdefer snapshot.deinit();
    const selections = try b.allocator().dupe(selection.Selection, state.selections.items.items);
    const first = state.rowAt(state.scroll.offset, snapshot.revision());
    const start = first -| 2;
    const count = @min(1024, snapshot.lineCount() - @min(start, snapshot.lineCount()));
    const states = try b.allocator().alloc(?syntax.State, count);
    for (states, 0..) |*item, i| item.* = state.syntax_cache.state(snapshot, start + i);
    const changes = try b.allocator().dupe(annotations.GitChange, state.visibleChanges(snapshot.revision()));
    for (changes) |*change| if (change.expanded) {
        change.removed = try b.allocator().dupe(u8, change.removed);
    };
    const value: Canvas = .{ .snapshot = snapshot, .block_cursor = state.vim.enabled and state.vim.mode != .insert, .cursor = if (state.vim.enabled and state.vim.visual()) state.vim.cursor else state.primary().head, .profile = if (state.language_profile) |profile| try profile.copy(b.allocator()) else null, .blame = if (state.inline_blame != null and state.inline_blame.?.revision == snapshot.revision()) try state.inline_blame.?.copy(b.allocator()) else null, .git_changes = changes, .blame_message_scroll = state.blame_message_scroll, .theme = state.theme, .show_line_numbers = state.show_line_numbers, .selections = selections, .scroll = state.scroll.offset, .horizontal = state.horizontal, .font_size = state.font_size, .line_height = state.line_height, .tab_width = state.tab_width, .language = state.language, .states = states, .state_start = start, .marked = state.marked, .search = try b.allocator().dupe(u8, state.search_query) };
    return b.custom(Canvas, value, .{ .flex_grow = 1, .overflow = .hidden, .background = state.theme.background });
}
const RenderLine = struct { row: usize, range: text.Range, original: []const u8, display: display.Line, spans: []const syntax.Span, y: f32, oversized: bool = false, height: f32 = 22 };
const Prepared = struct { lines: []RenderLine, caret: ui.Rect, gutter: f32 };
const Canvas = struct {
    snapshot: text.Snapshot,
    block_cursor: bool,
    cursor: usize,
    profile: ?@import("profile.zig").Profile,
    blame: ?annotations.Blame,
    git_changes: []const annotations.GitChange,
    blame_message_scroll: f32,
    theme: @import("theme.zig").Theme,
    show_line_numbers: bool,
    selections: []const selection.Selection,
    scroll: f32,
    horizontal: f32,
    font_size: f32,
    line_height: f32,
    tab_width: usize,
    language: syntax.Language,
    states: []const ?syntax.State,
    state_start: usize,
    marked: ?text.Range,
    search: []const u8,
    pub const LayoutState = ui.layout.Measurer;
    pub const PrepaintState = Prepared;
    pub fn deinit(self: *Canvas) void {
        self.snapshot.deinit();
    }
    pub fn requestLayout(_: *Canvas, cx: *ui.LayoutCx) !ui.LayoutResult(LayoutState) {
        return .{ .size = cx.available, .state = cx.measurer };
    }
    pub fn prepaint(self: *Canvas, cx: *ui.PrepaintCx, bounds: ui.Rect, metrics: *LayoutState) !Prepared {
        const first = annotations.sourceRow(self.scroll, self.line_height, self.git_changes);
        const visible = try ui.controls.visibleRows(self.snapshot.lineCount(), self.line_height, @as(f32, @floatFromInt(first)) * self.line_height, bounds.height, 2);
        const lines = try cx.allocator.alloc(RenderLine, visible.end - visible.start);
        const gutter: f32 = if (self.show_line_numbers) gutterWidth(self.snapshot.lineCount(), self.font_size) else 20;
        var caret: ui.Rect = .{ .x = bounds.x + gutter - self.horizontal, .y = bounds.y, .width = 1.5, .height = self.line_height - 4 };
        const style: ui.TextStyle = .{ .size = self.font_size, .mono = true };
        for (lines, 0..) |*line, i| {
            const row = visible.start + i;
            const range = try self.snapshot.lineRange(row);
            const oversized = range.end - range.start > line_limit;
            const original = if (oversized) "[Line exceeds the 64 KiB display limit]" else try self.snapshot.copy(cx.allocator, range);
            const expanded = try display.Line.build(cx.allocator, original, self.tab_width);
            const initial = if (row >= self.state_start and row - self.state_start < self.states.len) self.states[row - self.state_start] else null;
            const lexed = if (self.profile != null and !oversized) try @import("profile.zig").lex(cx.allocator, original, self.profile.?, initial orelse .{}) else try syntax.lex(cx.allocator, original, if (initial != null and !oversized) self.language else .plain, initial orelse .{});
            line.* = .{ .row = row, .range = range, .original = original, .display = expanded, .spans = lexed.spans, .y = bounds.y + annotations.rowY(row, self.line_height, self.git_changes) - self.scroll, .oversized = oversized, .height = self.line_height };
            if (self.selections.len > 0 and (try self.snapshot.pointAt(self.selections[0].head)).line == row) {
                caret.x = bounds.x + gutter - self.horizontal + if (oversized) @as(f32, 0) else expanded.caret(metrics.*, style, @min(self.selections[0].head - range.start, original.len));
                caret.y = line.y + 3;
            }
        }
        if (cx.focused and self.selections.len > 0) {
            if (!self.block_cursor) {
                try cx.requestFrameAfter(0.5 - @mod(cx.time, 0.5));
                const selected = self.selections[0].range();
                var begin = selected.start -| 2048;
                var end = @min(self.snapshot.byteLen(), selected.end +| 2048);
                if (self.marked) |marked| {
                    begin = @min(begin, marked.start);
                    end = @max(end, marked.end);
                }
                while (!self.snapshot.isBoundary(begin)) begin -= 1;
                while (!self.snapshot.isBoundary(end)) end += 1;
                const surrounding = try self.snapshot.copy(cx.allocator, .{ .start = begin, .end = end });
                try cx.setTextInput(.{ .text = surrounding, .revision = self.snapshot.revision(), .selection = .{ .start = selected.start - begin, .end = selected.end - begin }, .marked = if (self.marked) |marked| .{ .start = marked.start - begin, .end = marked.end - begin } else null, .caret = caret, .base_byte = begin, .base_utf16 = try self.snapshot.utf16Offset(begin) });
            }
        }
        return .{ .lines = lines, .caret = caret, .gutter = gutter };
    }
    pub fn paint(self: *Canvas, cx: *ui.PaintCx, bounds: ui.Rect, metrics: *LayoutState, prepared: *Prepared) !void {
        try cx.painter.fillRect(.{ .bounds = bounds, .color = self.theme.background });
        try cx.painter.pushClip(bounds);
        defer cx.painter.popClip();
        const style: ui.TextStyle = .{ .size = self.font_size, .mono = true, .color = self.theme.foreground };
        const primary_row = if (self.selections.len > 0) (try self.snapshot.pointAt(if (self.block_cursor) self.cursor else self.selections[0].head)).line else 0;
        for (prepared.lines) |line| {
            if (line.row == primary_row) try cx.painter.fillRect(.{ .bounds = .{ .x = bounds.x, .y = line.y, .width = bounds.width, .height = self.line_height }, .color = self.theme.active_line });
            for (self.git_changes) |change| if (change.expanded and line.row >= change.start and line.row < change.end) {
                var fill = self.theme.git_added;
                fill.a = 0.15;
                try cx.painter.fillRect(.{ .bounds = .{ .x = bounds.x, .y = line.y, .width = bounds.width, .height = self.line_height }, .color = fill });
                if (change.old_count == change.end - change.start and !line.oversized) {
                    const columns = annotations.changedColumns(annotations.lineAt(change.removed, line.row - change.start), line.original);
                    try highlightColumns(cx, metrics.*, line, style, bounds.x + prepared.gutter - self.horizontal, columns.start, columns.end, self.theme.git_added);
                }
            };
            const x = bounds.x + prepared.gutter - self.horizontal;
            try cx.painter.pushClip(.{ .x = bounds.x + prepared.gutter - 4, .y = bounds.y, .width = @max(0, bounds.width - prepared.gutter + 4), .height = bounds.height });
            if (!line.oversized) {
                for (self.selections) |item| {
                    const range = item.range();
                    if (range.start == range.end or range.end <= line.range.start or range.start > line.range.end) continue;
                    const start = @max(range.start, line.range.start) - line.range.start;
                    const end = @min(range.end, line.range.end) - line.range.start;
                    const left = line.display.caret(metrics.*, style, start);
                    const right = if (range.end > line.range.end) @max(left, bounds.x + bounds.width - x) else line.display.caret(metrics.*, style, end);
                    try cx.painter.fillRect(.{ .bounds = .{ .x = x + @min(left, right), .y = line.y, .width = @abs(right - left), .height = self.line_height }, .color = if (cx.focused) self.theme.selection else self.theme.inactive_selection });
                }
                if (self.search.len > 0 and std.mem.indexOfScalar(u8, self.search, '\n') == null) {
                    var at: usize = 0;
                    while (std.mem.indexOfPos(u8, line.original, at, self.search)) |found| {
                        const left = line.display.caret(metrics.*, style, found);
                        const right = line.display.caret(metrics.*, style, found + self.search.len);
                        try cx.painter.fillRect(.{ .bounds = .{ .x = x + @min(left, right), .y = line.y + 1, .width = @abs(right - left), .height = self.line_height - 2 }, .color = .{ .r = 0.6, .g = 0.43, .b = 0.14, .a = 0.3 } });
                        at = found + self.search.len;
                    }
                }
            }
            var at: usize = 0;
            for (line.spans) |span| {
                if (span.start > at) try drawRun(cx, line, self.theme, metrics.*, style, x, at, span.start, .plain);
                try drawRun(cx, line, self.theme, metrics.*, style, x, span.start, span.end, span.kind);
                at = span.end;
            }
            if (at < line.original.len) try drawRun(cx, line, self.theme, metrics.*, style, x, at, line.original.len, .plain);
            if (self.marked) |marked| if (!line.oversized and marked.start <= line.range.end and marked.end >= line.range.start) {
                const left = line.display.caret(metrics.*, style, @max(marked.start, line.range.start) - line.range.start);
                const right = line.display.caret(metrics.*, style, @min(marked.end, line.range.end) - line.range.start);
                try cx.painter.fillRect(.{ .bounds = .{ .x = x + @min(left, right), .y = line.y + self.line_height - 3, .width = @max(1, @abs(right - left)), .height = 1 }, .color = self.theme.caret });
            };
            if (cx.focused and (self.block_cursor or @mod(cx.time, 1.0) < 0.5) and !line.oversized) for (self.selections, 0..) |item, index| {
                if (self.block_cursor and index > 0) continue;
                const head = if (self.block_cursor) self.cursor else item.head;
                if ((try self.snapshot.pointAt(head)).line != line.row) continue;
                const offset = @min(head - line.range.start, line.original.len);
                const left = line.display.caret(metrics.*, style, offset);
                const next = @min(line.original.len, (try self.snapshot.nextBoundary(head)) - line.range.start);
                const width = if (self.block_cursor) (if (offset < line.original.len and line.original[offset] == '\t') self.font_size * 0.6 else @max(self.font_size * 0.6, line.display.caret(metrics.*, style, next) - left)) else @as(f32, 1.5);
                try cx.painter.fillRect(.{ .bounds = .{ .x = x + left, .y = line.y + (if (self.block_cursor) @as(f32, 0) else 3), .width = width, .height = if (self.block_cursor) self.line_height else self.line_height - 4 }, .color = self.theme.caret });
                if (self.block_cursor and next > offset) {
                    var inverted = self.theme;
                    inverted.tokens[@backingInt(syntax.Kind.plain)] = self.theme.background;
                    try drawRun(cx, line, inverted, metrics.*, style, x, offset, next, .plain);
                }
            };
            cx.painter.popClip();
            try cx.painter.fillRect(.{ .bounds = .{ .x = bounds.x, .y = line.y, .width = prepared.gutter - 8, .height = self.line_height }, .color = if (line.row == primary_row) self.theme.active_line else self.theme.background });

            if (self.show_line_numbers) {
                const number = try std.fmt.allocPrint(cx.painter.allocator, "{d}", .{line.row + 1});
                const number_style: ui.TextStyle = .{ .size = self.font_size - 1, .mono = true };
                const number_width = metrics.text(metrics.context, number, number_style) catch ui.Size{ .width = 20, .height = 16 };
                try cx.painter.drawText(.{ .bounds = .{ .x = bounds.x + prepared.gutter - 18 - number_width.width, .y = line.y + (self.line_height - number_width.height) / 2, .width = number_width.width + 2, .height = number_width.height }, .text = number, .style = .{ .size = self.font_size - 1, .mono = true, .color = if (line.row == primary_row) self.theme.active_number else self.theme.line_number } });
            }
        }
        for (self.git_changes) |change| {
            if (change.expanded) try self.paintRemoved(cx, metrics.*, prepared.gutter, bounds, change);
            try cx.painter.fillRect(.{ .bounds = annotations.marker(change, self.git_changes, self.line_height, bounds, self.scroll), .color = switch (change.kind) {
                .added => self.theme.git_added,
                .modified => self.theme.git_modified,
                .deleted => self.theme.git_deleted,
            } });
        }
        if (self.blame) |blame| if (try @import("blame_view.zig").layout(cx.painter.allocator, self.snapshot, blame, self.git_changes, .{ .font = self.font_size, .line_height = self.line_height, .gutter = prepared.gutter, .horizontal = self.horizontal, .scroll = self.scroll, .tab_width = self.tab_width }, metrics.*, bounds)) |geometry| {
            try @import("blame_view.zig").paint(cx, geometry, blame, self.theme, self.font_size, self.blame_message_scroll);
        };
        const content = annotations.rowY(self.snapshot.lineCount(), self.line_height, self.git_changes);
        if (content > bounds.height and bounds.height > 0) {
            const height = @max(24, bounds.height * bounds.height / content);
            const y = bounds.y + (bounds.height - height) * self.scroll / @max(1, content - bounds.height);
            try cx.painter.fillRect(.{ .bounds = .{ .x = bounds.x + bounds.width - 7, .y = y, .width = 4, .height = height }, .color = self.theme.scrollbar, .radius = 2 });
        }
    }
    fn paintRemoved(self: *Canvas, cx: *ui.PaintCx, metrics: LayoutState, gutter: f32, bounds: ui.Rect, change: annotations.GitChange) !void {
        var rows = std.mem.splitScalar(u8, change.removed, '\n');
        var i: usize = 0;
        const top = bounds.y + annotations.changeY(change, self.line_height, self.git_changes) - self.scroll;
        while (i < change.old_count) : (i += 1) {
            const raw = rows.next() orelse "";
            const original = std.mem.trimEnd(u8, raw, "\r");
            const y = top + @as(f32, @floatFromInt(i)) * self.line_height;
            if (y + self.line_height < bounds.y or y >= bounds.y + bounds.height) continue;
            var fill = self.theme.git_deleted;
            fill.a = 0.16;
            try cx.painter.fillRect(.{ .bounds = .{ .x = bounds.x, .y = y, .width = bounds.width, .height = self.line_height }, .color = fill });
            const safe = if (original.len <= line_limit) original else "[Removed line exceeds the display limit]";
            const expanded = try display.Line.build(cx.painter.allocator, safe, self.tab_width);
            const lexed = try syntax.lex(cx.painter.allocator, safe, self.language, .{});
            const line: RenderLine = .{ .row = change.old_start + i, .range = .{ .start = 0, .end = safe.len }, .original = safe, .display = expanded, .spans = lexed.spans, .y = y, .height = self.line_height };
            const style: ui.TextStyle = .{ .size = self.font_size, .mono = true };
            if (change.old_count == change.end - change.start and change.start + i < self.snapshot.lineCount()) {
                const current_range = try self.snapshot.lineRange(change.start + i);
                if (current_range.end - current_range.start <= line_limit) {
                    const current = try self.snapshot.copy(cx.painter.allocator, current_range);
                    const columns = annotations.changedColumns(current, safe);
                    try highlightColumns(cx, metrics, line, style, bounds.x + gutter - self.horizontal, columns.start, columns.end, self.theme.git_deleted);
                }
            }
            try cx.painter.pushClip(.{ .x = bounds.x + gutter, .y = bounds.y, .width = @max(0, bounds.width - gutter), .height = bounds.height });
            var cursor: usize = 0;
            for (lexed.spans) |span| {
                if (span.start > cursor) try drawRun(cx, line, self.theme, metrics, style, bounds.x + gutter - self.horizontal, cursor, span.start, .plain);
                try drawRun(cx, line, self.theme, metrics, style, bounds.x + gutter - self.horizontal, span.start, span.end, span.kind);
                cursor = span.end;
            }
            if (cursor < safe.len) try drawRun(cx, line, self.theme, metrics, style, bounds.x + gutter - self.horizontal, cursor, safe.len, .plain);
            cx.painter.popClip();
            if (self.show_line_numbers) {
                const number = try std.fmt.allocPrint(cx.painter.allocator, "{d}", .{change.old_start + i + 1});
                const number_style: ui.TextStyle = .{ .size = self.font_size - 1, .mono = true, .color = self.theme.git_deleted };
                const measured = try metrics.text(metrics.context, number, number_style);
                try cx.painter.drawText(.{ .bounds = .{ .x = bounds.x + gutter - 18 - measured.width, .y = y + (self.line_height - measured.height) / 2, .width = measured.width + 2, .height = measured.height }, .text = number, .style = number_style });
            }
        }
    }
};
fn drawRun(cx: *ui.PaintCx, line: RenderLine, theme: @import("theme.zig").Theme, metrics: ui.layout.Measurer, style: ui.TextStyle, x: f32, start: usize, end: usize, kind: syntax.Kind) !void {
    const begin = line.display.displayOffset(start);
    const finish = line.display.displayOffset(end);
    if (begin == finish) return;
    const left = metrics.caret(line.display.bytes, style, begin);
    const right = metrics.caret(line.display.bytes, style, finish);
    const measured = try metrics.text(metrics.context, line.display.bytes[begin..finish], style);
    var actual = style;
    actual.color = theme.tokens[@backingInt(kind)];
    try cx.painter.drawText(.{ .bounds = .{ .x = x + @min(left, right), .y = line.y + (line.height - measured.height) / 2, .width = @max(1, @abs(right - left) + 2), .height = measured.height }, .text = line.display.bytes[begin..finish], .style = actual });
}

fn highlightColumns(cx: *ui.PaintCx, metrics: ui.layout.Measurer, line: RenderLine, style: ui.TextStyle, x: f32, start: usize, end: usize, color: ui.Color) !void {
    if (end <= start) return;
    const left = line.display.caret(metrics, style, start);
    const right = line.display.caret(metrics, style, end);
    var fill = color;
    fill.a = 0.25;
    try cx.painter.fillRect(.{ .bounds = .{ .x = x + left, .y = line.y, .width = @max(0, right - left), .height = line.height }, .color = fill });
}
