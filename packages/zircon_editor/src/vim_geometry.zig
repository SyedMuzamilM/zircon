//! Modal geometry uses the same expanded tabs and shaped caret offsets as paint.
const std = @import("std");
const text = @import("zircon_text");
const ui = @import("zircon_ui");
const display = @import("display.zig");
const Editor = @import("editor.zig").Editor;
fn line(a: std.mem.Allocator, self: *Editor, s: text.Snapshot, row: usize) !display.Line {
    const range = try s.lineRange(row);
    if (range.end - range.start > 64 * 1024) return display.Line.build(a, "", self.tab_width);
    return display.Line.build(a, try s.copy(a, range), self.tab_width);
}
pub fn vertical(self: *Editor, s: text.Snapshot, from: usize, row: usize, event: *ui.Event(ui.Input)) !usize {
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    var fixed: ui.layout.FixedMetrics = .{ .advance = self.font_size * 0.6, .line_height = self.line_height };
    const metrics = if (event._surface != null) try event.textMetrics() else fixed.measurer();
    const point = try s.pointAt(from);
    const current = try line(arena.allocator(), self, s, point.line);
    const target = try line(arena.allocator(), self, s, row);
    const x = self.preferred_x orelse current.caret(metrics, .{ .size = self.font_size, .mono = true }, point.byte_column);
    self.preferred_x = x;
    return try s.lineStart(row) + target.index(metrics, .{ .size = self.font_size, .mono = true }, x);
}
pub fn block(self: *Editor, s: text.Snapshot, event: *ui.Event(ui.Input)) !void {
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    var fixed: ui.layout.FixedMetrics = .{ .advance = self.font_size * 0.6, .line_height = self.line_height };
    const metrics = if (event._surface != null) try event.textMetrics() else fixed.measurer();
    const style: ui.TextStyle = .{ .size = self.font_size, .mono = true };
    const anchor = try s.pointAt(self.vim.anchor);
    const cursor = try s.pointAt(self.vim.cursor);
    const anchor_line = try line(arena.allocator(), self, s, anchor.line);
    const cursor_line = try line(arena.allocator(), self, s, cursor.line);
    const left_x = anchor_line.caret(metrics, style, anchor.byte_column);
    const right_x = self.preferred_x orelse cursor_line.caret(metrics, style, cursor.byte_column);
    var selections: std.ArrayList(@import("selections.zig").Selection) = .empty;
    errdefer selections.deinit(self.allocator);
    var row = @min(anchor.line, cursor.line);
    while (row <= @max(anchor.line, cursor.line)) : (row += 1) {
        const range = try s.lineRange(row);
        const expanded = try line(arena.allocator(), self, s, row);
        if (expanded.caret(metrics, style, range.end - range.start) < @min(left_x, right_x)) continue;
        const start = range.start + expanded.index(metrics, style, @min(left_x, right_x));
        const last = range.start + expanded.index(metrics, style, @max(left_x, right_x));
        try selections.append(self.allocator, .{ .anchor = start, .head = if (last < range.end) try s.nextBoundary(last) else last });
    }
    if (selections.items.len == 0) try selections.append(self.allocator, .{ .anchor = self.vim.cursor, .head = self.vim.cursor });
    self.selections.items.deinit(self.allocator);
    self.selections.items = selections;
}
