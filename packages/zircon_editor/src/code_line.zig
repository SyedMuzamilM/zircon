//! Frame-owned source text shared by diff and search excerpts. Measurements,
//! highlights and glyph drawing use the same font and expanded tab positions.
const std = @import("std");
const ui = @import("zircon_ui");
const editor = @import("root.zig");
pub const Highlight = struct { start: usize, end: usize, color: ui.Color, newline: bool = false };
pub const Options = struct { tab_width: usize = 4, horizontal: f32 = 0, segments: []const editor.wrap.Row = &.{}, indent_guides: bool = true, indent_cells: ?usize = null, underline: ?editor.element.Mark = null };
pub fn element(b: *ui.Ui, source: []const u8, path: []const u8, font: f32, line_height: f32, theme: editor.Theme, ranges: []const Highlight, options: Options) !ui.Element {
    const safe = if (source.len > 65536) "[Line exceeds the display limit]" else if (!std.unicode.utf8ValidateSlice(source)) "[Non-UTF-8 source line]" else source;
    const owned = try b.allocator().dupe(u8, safe);
    const expanded = try editor.display.Line.build(b.allocator(), owned, options.tab_width);
    const lexed = try editor.syntax.lex(b.allocator(), expanded.bytes, editor.syntax.languageForPath(path), .{});
    var highlights: std.ArrayList(Highlight) = .empty;
    if (safe.ptr == source.ptr) for (ranges) |range| {
        try highlights.append(b.allocator(), .{ .start = expanded.displayOffset(range.start), .end = expanded.displayOffset(range.end), .color = range.color, .newline = range.newline or range.end > source.len });
    };
    var segments: std.ArrayList(editor.wrap.Row) = .empty;
    for (options.segments) |part| {
        var mapped = part;
        mapped.start = expanded.displayOffset(part.start);
        mapped.end = expanded.displayOffset(part.end);
        try segments.append(b.allocator(), mapped);
    }
    if (segments.items.len == 0) try segments.append(b.allocator(), .{ .line = 0, .start = 0, .end = expanded.bytes.len, .x = 0, .first = true });
    const underline = if (options.underline != null and safe.ptr == source.ptr) options.underline else null;
    return b.custom(Code, .{ .text = expanded.bytes, .spans = lexed.spans, .theme = theme, .font = font, .line_height = line_height, .highlights = highlights.items, .horizontal = options.horizontal, .segments = segments.items, .indent_cells = if (options.indent_guides) options.indent_cells orelse editor.indent_guides.cells(safe, options.tab_width) else 0, .tab_width = options.tab_width, .underline_start = if (underline) |mark| expanded.displayOffset(mark.range.start) else null, .underline_end = if (underline) |mark| expanded.displayOffset(mark.range.end) else 0, .underline_color = if (underline) |mark| editor.element.color(theme, mark.severity) else ui.Color.rgb(0) }, .{ .flex_grow = 1, .min_width = .{ .px = 0 }, .overflow = .hidden });
}
const Code = struct {
    text: []const u8,
    spans: []const editor.syntax.Span,
    theme: editor.Theme,
    font: f32,
    line_height: f32,
    highlights: []const Highlight,
    horizontal: f32,
    segments: []const editor.wrap.Row,
    indent_cells: usize,
    tab_width: usize,
    underline_start: ?usize = null,
    underline_end: usize = 0,
    underline_color: ui.Color = ui.Color.rgb(0),
    pub const LayoutState = void;
    pub const PrepaintState = void;
    pub fn requestLayout(self: *Code, cx: *ui.LayoutCx) !ui.LayoutResult(void) {
        return .{ .size = .{ .width = cx.available.width, .height = self.line_height * @as(f32, @floatFromInt(self.segments.len)) }, .state = {} };
    }
    pub fn prepaint(_: *Code, _: *ui.PrepaintCx, _: ui.Rect, _: *void) !void {}
    pub fn paint(self: *Code, cx: *ui.PaintCx, bounds: ui.Rect, _: *void, _: *void) !void {
        try cx.painter.pushClip(bounds);
        defer cx.painter.popClip();
        const style: ui.TextStyle = .{ .size = self.font, .mono = true };
        const size = try cx.measurer.text(cx.measurer.context, "M", style);
        for (self.segments, 0..) |part, index| {
            const top = bounds.y + @as(f32, @floatFromInt(index)) * self.line_height;
            const y = top + @max(0, self.line_height - size.height) / 2;
            const x = bounds.x - self.horizontal - part.x;
            try cx.painter.pushClip(.{ .x = bounds.x, .y = top, .width = bounds.width, .height = self.line_height });
            for (self.highlights) |highlight| {
                const start = @max(part.start, highlight.start);
                const end = @min(part.end, highlight.end);
                if (start > end or (start == end and !highlight.newline)) continue;
                const left = cx.measurer.caret(self.text, style, start);
                const right = cx.measurer.caret(self.text, style, end) + (if (highlight.newline and index + 1 == self.segments.len) self.font * 0.6 else @as(f32, 0));
                try cx.painter.fillRect(.{ .bounds = .{ .x = x + left, .y = top, .width = @max(0, right - left), .height = self.line_height }, .color = highlight.color });
            }
            const advance = @max(1, cx.measurer.caret(" ", style, 1));
            const step = @as(f32, @floatFromInt(self.tab_width));
            var guide: usize = @as(usize, @intFromFloat(@floor(self.horizontal / advance / step))) * self.tab_width;
            const last_guide = @min(self.indent_cells, @as(usize, @intFromFloat(@ceil((self.horizontal + bounds.width) / advance))));
            var tint = self.theme.line_number;
            tint.a = 0.2;
            while (guide < last_guide) : (guide += self.tab_width) {
                try cx.painter.fillRect(.{ .bounds = .{ .x = bounds.x - self.horizontal + @as(f32, @floatFromInt(guide)) * advance, .y = top, .width = 1, .height = self.line_height }, .color = tint });
            }
            var cursor = part.start;
            for (self.spans) |span| {
                if (span.end <= part.start) continue;
                if (span.start >= part.end) break;
                const start = @max(span.start, part.start);
                const end = @min(span.end, part.end);
                if (start > cursor) _ = try self.run(cx, self.text[cursor..start], self.theme.foreground, x + cx.measurer.caret(self.text, style, cursor), y, bounds);
                _ = try self.run(cx, self.text[start..end], self.theme.tokens[@backingInt(span.kind)], x + cx.measurer.caret(self.text, style, start), y, bounds);
                cursor = end;
            }
            if (cursor < part.end) _ = try self.run(cx, self.text[cursor..part.end], self.theme.foreground, x + cx.measurer.caret(self.text, style, cursor), y, bounds);
            if (self.underline_start) |origin| if (self.underline_end >= origin) {
                const start = @max(part.start, origin);
                const end = @min(part.end, @max(self.underline_end, origin));
                const point = origin == self.underline_end;
                if (point and origin >= part.start and origin < part.end) {
                    const left = cx.measurer.caret(self.text, style, origin);
                    try editor.element.paint(cx, x + left, @max(6, self.font * 0.55), top, self.line_height, self.underline_color);
                } else if (!point and start < end) {
                    const left = cx.measurer.caret(self.text, style, start);
                    const right = cx.measurer.caret(self.text, style, end);
                    try editor.element.paint(cx, x + left, @max(0, right - left), top, self.line_height, self.underline_color);
                }
            };
            cx.painter.popClip();
        }
    }
    fn run(self: *Code, cx: *ui.PaintCx, bytes: []const u8, color: ui.Color, x: f32, y: f32, bounds: ui.Rect) !f32 {
        const style: ui.TextStyle = .{ .size = self.font, .mono = true, .color = color };
        const measured = try cx.measurer.text(cx.measurer.context, bytes, style);
        try cx.painter.drawText(.{ .bounds = .{ .x = x, .y = y, .width = @max(0, bounds.x + bounds.width - x), .height = measured.height }, .text = bytes, .style = style });
        return measured.width;
    }
};
