//! Code-point and word navigation plus glyph-based vertical/pointer mapping.
const std = @import("std");
const text = @import("zircon_text");
const ui = @import("zircon_ui");
const Editor = @import("editor.zig").Editor;
const commands = @import("commands.zig");
const display = @import("display.zig");
pub fn move(self: *Editor, snapshot: text.Snapshot, request: commands.Move) !void {
    for (self.selections.items.items) |*item| {
        var head = item.head;
        const point = try snapshot.pointAt(head);
        if (!request.extend and !item.empty() and (request.direction == .left or request.direction == .right)) head = if (request.direction == .left) item.range().start else item.range().end else head = switch (request.direction) {
            .left => if (request.word) try wordBoundary(snapshot, head, false) else try snapshot.previousBoundary(head),
            .right => if (request.word) try wordBoundary(snapshot, head, true) else try snapshot.nextBoundary(head),
            .home => (try snapshot.lineRange(point.line)).start,
            .end => (try snapshot.lineRange(point.line)).end,
            .document_start => 0,
            .document_end => snapshot.byteLen(),
            .up, .down, .page_up, .page_down => blk: {
                const count: usize = if (request.direction == .page_up or request.direction == .page_down) @max(1, @as(usize, @intFromFloat(self.last_viewport.height / self.line_height))) else 1;
                const row = if (request.direction == .up or request.direction == .page_up) point.line -| count else @min(snapshot.lineCount() - 1, point.line +| count);
                const range = try snapshot.lineRange(row);
                var destination = range.start + @min(point.byte_column, range.end - range.start);
                while (!snapshot.isBoundary(destination)) destination -= 1;
                break :blk destination;
            },
        };
        item.head = head;
        if (!request.extend) item.anchor = head;
    }
    self.selections.normalize();
}
pub fn vertical(self: *Editor, snapshot: text.Snapshot, e: *ui.Event(ui.Input), key: ui.Key, extend: bool) !void {
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    var fixed: ui.layout.FixedMetrics = .{ .advance = self.font_size * 0.6, .line_height = self.line_height };
    const metrics = if (e._surface != null) try e.textMetrics() else fixed.measurer();
    const style: ui.TextStyle = .{ .size = self.font_size, .mono = true };
    for (self.selections.items.items, 0..) |*item, i| {
        const point = try snapshot.pointAt(item.head);
        const current_range = try snapshot.lineRange(point.line);
        const amount: usize = if (key == .page_up or key == .page_down) @max(1, @as(usize, @intFromFloat(e.bounds.height / self.line_height))) else 1;
        const wrapped = self.projected() and self.wrap_cache.valid(snapshot.revision());
        const current_visual = if (wrapped) self.wrap_cache.atOffset(item.head) else 0;
        const target_visual = if (key == .up or key == .page_up) current_visual -| amount else @min(self.wrap_cache.rows.items.len -| 1, current_visual +| amount);
        const row = if (wrapped) self.wrap_cache.rows.items[target_visual].line else if (key == .up or key == .page_up) point.line -| amount else @min(snapshot.lineCount() - 1, point.line +| amount);
        const target_range = try snapshot.lineRange(row);
        if (current_range.end - current_range.start > 64 * 1024 or target_range.end - target_range.start > 64 * 1024) continue;
        const current = try display.Line.build(arena.allocator(), try snapshot.copy(arena.allocator(), current_range), self.tab_width);
        const target = try display.Line.build(arena.allocator(), try snapshot.copy(arena.allocator(), target_range), self.tab_width);
        const origin = if (wrapped) self.wrap_cache.rows.items[current_visual].x else 0;
        const x = if (i == 0) self.preferred_x orelse current.caret(metrics, style, @min(point.byte_column, current_range.end - current_range.start)) - origin else current.caret(metrics, style, @min(point.byte_column, current_range.end - current_range.start)) - origin;
        if (i == 0) self.preferred_x = x;
        const target_origin = if (wrapped) self.wrap_cache.rows.items[target_visual].x else 0;
        item.head = target_range.start + target.index(metrics, style, x + target_origin);
        if (wrapped) item.head = std.math.clamp(item.head, self.wrap_cache.rows.items[target_visual].start, self.wrap_cache.rows.items[target_visual].end);
        if (!extend) item.anchor = item.head;
    }
    self.selections.normalize();
    self.typing_group = 0;
    self.reveal(snapshot);
}
pub fn position(self: *Editor, snapshot: text.Snapshot, e: *ui.Event(ui.Input), point: ui.Point) !usize {
    const metrics = try e.textMetrics();
    const relative = @max(0, point.y - e.bounds.y + self.scroll.offset);
    const wrapped = self.projected() and self.wrap_cache.valid(snapshot.revision());
    const part = if (wrapped) self.wrap_cache.rows.items[self.wrap_cache.visualAt(relative, self.line_height, self.visibleChanges(snapshot.revision()))] else null;
    const row = @min(snapshot.lineCount() - 1, self.rowAt(relative, snapshot.revision()));
    const range = try snapshot.lineRange(row);
    if (range.end - range.start > 64 * 1024) return range.start;
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const line = try display.Line.build(arena.allocator(), try snapshot.copy(arena.allocator(), range), self.tab_width);
    const gutter = if (self.show_line_numbers) @import("canvas.zig").gutterWidth(snapshot.lineCount(), self.font_size) else 20;
    const at = range.start + line.index(metrics, .{ .size = self.font_size, .mono = true }, point.x - e.bounds.x - gutter + (if (part) |segment| segment.x else self.horizontal));
    return if (part) |segment| std.math.clamp(at, segment.start, segment.end) else at;
}
fn wordCharacter(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte >= 0x80;
}
pub fn wordBoundary(snapshot: text.Snapshot, from: usize, forward: bool) !usize {
    var at = from;
    if (forward) {
        while (at < snapshot.byteLen() and wordCharacter(try snapshot.byteAt(at))) at = try snapshot.nextBoundary(at);
        while (at < snapshot.byteLen() and !wordCharacter(try snapshot.byteAt(at))) at = try snapshot.nextBoundary(at);
    } else {
        while (at > 0) {
            const previous = try snapshot.previousBoundary(at);
            if (wordCharacter(try snapshot.byteAt(previous))) break;
            at = previous;
        }
        while (at > 0) {
            const previous = try snapshot.previousBoundary(at);
            if (!wordCharacter(try snapshot.byteAt(previous))) break;
            at = previous;
        }
    }
    return at;
}
pub fn wordRange(snapshot: text.Snapshot, at: usize) !text.Range {
    if (snapshot.byteLen() == 0) return .{ .start = 0, .end = 0 };
    var left = if (at == snapshot.byteLen()) try snapshot.previousBoundary(at) else at;
    var right = left;
    const word = wordCharacter(try snapshot.byteAt(left));
    while (left > 0) {
        const previous = try snapshot.previousBoundary(left);
        if (wordCharacter(try snapshot.byteAt(previous)) != word) break;
        left = previous;
    }
    while (right < snapshot.byteLen() and wordCharacter(try snapshot.byteAt(right)) == word) right = try snapshot.nextBoundary(right);
    return .{ .start = left, .end = right };
}

/// Reveals the primary caret horizontally after navigation/editing. Metric
/// allocation failure leaves the previous scroll value and document untouched.
pub fn revealHorizontal(self: *Editor, snapshot: text.Snapshot, event: *ui.Event(ui.Input)) !void {
    if (self.soft_wrap != .none) {
        self.horizontal = 0;
        self.reveal(snapshot);
        return;
    }
    const point = try snapshot.pointAt(if (self.vim.enabled and self.vim.visual()) self.vim.cursor else self.primary().head);
    const range = try snapshot.lineRange(point.line);
    if (range.end - range.start > 64 * 1024) return;
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const line = try display.Line.build(arena.allocator(), try snapshot.copy(arena.allocator(), range), self.tab_width);
    const metrics = try event.textMetrics();
    const x = line.caret(metrics, .{ .size = self.font_size, .mono = true }, @min(point.byte_column, range.end - range.start));
    const gutter = if (self.show_line_numbers) @import("canvas.zig").gutterWidth(snapshot.lineCount(), self.font_size) else 20;
    const available = @max(20, event.bounds.width - gutter - 20);
    if (x < self.horizontal) self.horizontal = @max(0, x - 12);
    if (x > self.horizontal + available) self.horizontal = x - available;
}
