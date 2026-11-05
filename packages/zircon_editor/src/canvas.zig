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
    const value: Canvas = .{ .snapshot = snapshot, .profile = if (state.language_profile) |profile| try profile.copy(b.allocator()) else null, .blame = if (state.inline_blame != null and state.inline_blame.?.revision == snapshot.revision()) try state.inline_blame.?.copy(b.allocator()) else null, .git_changes = if (state.show_git_gutters and state.git_revision == snapshot.revision()) try b.allocator().dupe(annotations.GitChange, state.git_changes) else &.{}, .theme = state.theme, .show_line_numbers = state.show_line_numbers, .selections = selections, .scroll = state.scroll.offset, .horizontal = state.horizontal, .font_size = state.font_size, .line_height = state.line_height, .tab_width = state.tab_width, .language = state.language, .states = states, .state_start = start, .marked = state.marked, .search = try b.allocator().dupe(u8, state.search_query) };
    return b.custom(Canvas, value, .{ .flex_grow = 1, .overflow = .hidden, .background = state.theme.background });
}
const RenderLine = struct { row: usize, range: text.Range, original: []const u8, display: display.Line, spans: []const syntax.Span, y: f32, oversized: bool = false };
const Prepared = struct { lines: []RenderLine, caret: ui.Rect, gutter: f32 };
const Canvas = struct {
    snapshot: text.Snapshot,
    profile: ?@import("profile.zig").Profile,
    blame: ?annotations.Blame,
    git_changes: []const annotations.GitChange,
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
        const first = annotations.sourceRow(self.scroll, self.line_height, self.blame);
        const visible = try ui.controls.visibleRows(self.snapshot.lineCount(), self.line_height, @as(f32, @floatFromInt(first)) * self.line_height, bounds.height + annotations.blame_height, 2);
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
            line.* = .{ .row = row, .range = range, .original = original, .display = expanded, .spans = lexed.spans, .y = bounds.y + annotations.rowY(row, self.line_height, self.blame) - self.scroll, .oversized = oversized };
            if (self.selections.len > 0 and (try self.snapshot.pointAt(self.selections[0].head)).line == row) {
                caret.x = bounds.x + gutter - self.horizontal + if (oversized) @as(f32, 0) else expanded.caret(metrics.*, style, @min(self.selections[0].head - range.start, original.len));
                caret.y = line.y + 3;
            }
        }
        if (cx.focused and self.selections.len > 0) {
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
        return .{ .lines = lines, .caret = caret, .gutter = gutter };
    }
    pub fn paint(self: *Canvas, cx: *ui.PaintCx, bounds: ui.Rect, metrics: *LayoutState, prepared: *Prepared) !void {
        try cx.painter.fillRect(.{ .bounds = bounds, .color = self.theme.background });
        try cx.painter.pushClip(bounds);
        defer cx.painter.popClip();
        const style: ui.TextStyle = .{ .size = self.font_size, .mono = true, .color = self.theme.foreground };
        const primary_row = if (self.selections.len > 0) (try self.snapshot.pointAt(self.selections[0].head)).line else 0;
        for (prepared.lines) |line| {
            if (line.row == primary_row) try cx.painter.fillRect(.{ .bounds = .{ .x = bounds.x, .y = line.y, .width = bounds.width, .height = self.line_height }, .color = self.theme.active_line });
            const x = bounds.x + prepared.gutter - self.horizontal;
            try cx.painter.pushClip(.{ .x = bounds.x + prepared.gutter - 4, .y = bounds.y, .width = @max(0, bounds.width - prepared.gutter + 4), .height = bounds.height });
            if (!line.oversized) {
                for (self.selections) |item| {
                    const range = item.range();
                    if (range.start == range.end or range.end < line.range.start or range.start > line.range.end) continue;
                    const start = @max(range.start, line.range.start) - line.range.start;
                    const end = @min(range.end, line.range.end) - line.range.start;
                    const left = line.display.caret(metrics.*, style, start);
                    const right = line.display.caret(metrics.*, style, end);
                    try cx.painter.fillRect(.{ .bounds = .{ .x = x + @min(left, right), .y = line.y + 1, .width = @max(if (range.end > line.range.end) self.font_size * 0.6 else 0, @abs(right - left)), .height = self.line_height - 2 }, .color = if (cx.focused) self.theme.selection else self.theme.inactive_selection });
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
            if (cx.focused and @mod(cx.time, 1.0) < 0.5 and !line.oversized) for (self.selections) |item| if ((try self.snapshot.pointAt(item.head)).line == line.row) {
                const caret_x = x + line.display.caret(metrics.*, style, @min(item.head - line.range.start, line.original.len));
                try cx.painter.fillRect(.{ .bounds = .{ .x = caret_x, .y = line.y + 3, .width = 1.5, .height = self.line_height - 4 }, .color = self.theme.caret });
            };
            cx.painter.popClip();
            try cx.painter.fillRect(.{ .bounds = .{ .x = bounds.x, .y = line.y, .width = prepared.gutter - 8, .height = self.line_height }, .color = if (line.row == primary_row) self.theme.active_line else self.theme.background });
            for (self.git_changes) |change| if ((line.row >= change.start and line.row < change.end) or (change.kind == .deleted and line.row == @min(change.start, self.snapshot.lineCount() - 1))) {
                try cx.painter.fillRect(.{ .bounds = .{ .x = bounds.x + 4, .y = line.y + 2, .width = 3, .height = self.line_height - 4 }, .color = ui.Color.rgb(switch (change.kind) {
                    .added => @as(u24, 0x75b88a),
                    .modified => 0xd8b579,
                    .deleted => 0xd1787c,
                }) });
            };

            if (self.show_line_numbers) {
                const number = try std.fmt.allocPrint(cx.painter.allocator, "{d}", .{line.row + 1});
                const number_width = metrics.text(metrics.context, number, style) catch ui.Size{ .width = 20, .height = 16 };
                try cx.painter.drawText(.{ .bounds = .{ .x = bounds.x + prepared.gutter - 18 - number_width.width, .y = line.y + 3, .width = number_width.width + 2, .height = self.line_height }, .text = number, .style = .{ .size = self.font_size - 1, .mono = true, .color = if (line.row == primary_row) self.theme.active_number else self.theme.line_number } });
            }
        }
        if (self.blame) |blame| {
            const y = bounds.y + @as(f32, @floatFromInt(blame.line + 1)) * self.line_height - self.scroll;
            if (y < bounds.y + bounds.height and y + annotations.blame_height > bounds.y) {
                try cx.painter.fillRect(.{ .bounds = .{ .x = bounds.x + prepared.gutter, .y = y + 2, .width = @max(0, bounds.width - prepared.gutter - 12), .height = annotations.blame_height - 6 }, .color = self.theme.active_line, .radius = 5 });
                const title = try std.fmt.allocPrint(cx.painter.allocator, "{s}   {s}", .{ blame.author, blame.oid[0..@min(8, blame.oid.len)] });
                try cx.painter.drawText(.{ .bounds = .{ .x = bounds.x + prepared.gutter + 14, .y = y + 14, .width = @max(0, bounds.width - prepared.gutter - 40), .height = 24 }, .text = title, .style = .{ .size = 13, .color = self.theme.foreground } });
                try cx.painter.drawText(.{ .bounds = .{ .x = bounds.x + prepared.gutter + 14, .y = y + 42, .width = @max(0, bounds.width - prepared.gutter - 40), .height = 24 }, .text = blame.summary, .style = .{ .size = 12, .color = self.theme.line_number } });
            }
        }
        const content = @as(f32, @floatFromInt(self.snapshot.lineCount())) * self.line_height + if (self.blame != null) annotations.blame_height else @as(f32, 0);
        if (content > bounds.height and bounds.height > 0) {
            const height = @max(24, bounds.height * bounds.height / content);
            const y = bounds.y + (bounds.height - height) * self.scroll / @max(1, content - bounds.height);
            try cx.painter.fillRect(.{ .bounds = .{ .x = bounds.x + bounds.width - 7, .y = y, .width = 4, .height = height }, .color = self.theme.scrollbar, .radius = 2 });
        }
    }
};
fn drawRun(cx: *ui.PaintCx, line: RenderLine, theme: @import("theme.zig").Theme, metrics: ui.layout.Measurer, style: ui.TextStyle, x: f32, start: usize, end: usize, kind: syntax.Kind) !void {
    const begin = line.display.displayOffset(start);
    const finish = line.display.displayOffset(end);
    if (begin == finish) return;
    const left = metrics.caret(line.display.bytes, style, begin);
    const right = metrics.caret(line.display.bytes, style, finish);
    var actual = style;
    actual.color = theme.tokens[@backingInt(kind)];
    try cx.painter.drawText(.{ .bounds = .{ .x = x + @min(left, right), .y = line.y + 3, .width = @max(1, @abs(right - left) + 2), .height = style.size * 1.6 }, .text = line.display.bytes[begin..finish], .style = actual });
}
