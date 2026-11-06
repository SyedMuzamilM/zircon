//! Frame-owned source text shared by diff and search excerpts. Measurements,
//! highlights and glyph drawing use the same font and expanded tab positions.
const std = @import("std");
const ui = @import("zircon_ui");
const editor = @import("zircon_editor");
pub const Highlight = struct { start: usize, end: usize, color: ui.Color };
pub fn element(b: *ui.Ui, source: []const u8, path: []const u8, font: f32, line_height: f32, theme: editor.Theme, ranges: []const Highlight) !ui.Element {
    const safe = if (source.len > 65536) "[Line exceeds the display limit]" else if (!std.unicode.utf8ValidateSlice(source)) "[Non-UTF-8 source line]" else source;
    const owned = try b.allocator().dupe(u8, safe);
    const expanded = try editor.display.Line.build(b.allocator(), owned, 4);
    const lexed = try editor.syntax.lex(b.allocator(), expanded.bytes, editor.syntax.languageForPath(path), .{});
    var highlights: std.ArrayList(Highlight) = .empty;
    if (safe.ptr == source.ptr) for (ranges) |range| {
        try highlights.append(b.allocator(), .{ .start = expanded.displayOffset(range.start), .end = expanded.displayOffset(range.end), .color = range.color });
    };
    return b.custom(Code, .{ .text = expanded.bytes, .spans = lexed.spans, .theme = theme, .font = font, .line_height = line_height, .highlights = highlights.items }, .{ .flex_grow = 1, .min_width = .{ .px = 0 }, .overflow = .hidden });
}
const Code = struct {
    text: []const u8,
    spans: []const editor.syntax.Span,
    theme: editor.Theme,
    font: f32,
    line_height: f32,
    highlights: []const Highlight,
    pub const LayoutState = void;
    pub const PrepaintState = void;
    pub fn requestLayout(self: *Code, cx: *ui.LayoutCx) !ui.LayoutResult(void) {
        return .{ .size = .{ .width = cx.available.width, .height = self.line_height }, .state = {} };
    }
    pub fn prepaint(_: *Code, _: *ui.PrepaintCx, _: ui.Rect, _: *void) !void {}
    pub fn paint(self: *Code, cx: *ui.PaintCx, bounds: ui.Rect, _: *void, _: *void) !void {
        var cursor: usize = 0;
        var x: f32 = bounds.x;
        const size = try cx.measurer.text(cx.measurer.context, "M", .{ .size = self.font, .mono = true });
        const y = bounds.y + @max(0, bounds.height - size.height) / 2;
        for (self.highlights) |highlight| {
            const style: ui.TextStyle = .{ .size = self.font, .mono = true };
            const left = cx.measurer.caret(self.text, style, highlight.start);
            const right = cx.measurer.caret(self.text, style, highlight.end);
            try cx.painter.fillRect(.{ .bounds = .{ .x = bounds.x + left, .y = bounds.y + 1, .width = right - left, .height = @max(0, bounds.height - 2) }, .color = highlight.color, .radius = ui.controls.metrics.text_highlight_radius });
        }
        for (self.spans) |span| {
            if (span.start > cursor) x += try self.run(cx, self.text[cursor..span.start], self.theme.foreground, x, y, bounds);
            x += try self.run(cx, self.text[span.start..span.end], self.theme.tokens[@backingInt(span.kind)], x, y, bounds);
            cursor = span.end;
            if (x >= bounds.x + bounds.width) break;
        }
        if (cursor < self.text.len and x < bounds.x + bounds.width) _ = try self.run(cx, self.text[cursor..], self.theme.foreground, x, y, bounds);
    }
    fn run(self: *Code, cx: *ui.PaintCx, bytes: []const u8, color: ui.Color, x: f32, y: f32, bounds: ui.Rect) !f32 {
        const style: ui.TextStyle = .{ .size = self.font, .mono = true, .color = color };
        const measured = try cx.measurer.text(cx.measurer.context, bytes, style);
        try cx.painter.drawText(.{ .bounds = .{ .x = x, .y = y, .width = @max(0, bounds.x + bounds.width - x), .height = measured.height }, .text = bytes, .style = style });
        return measured.width;
    }
};
