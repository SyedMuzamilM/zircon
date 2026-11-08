//! Rectangular registers paste once per source row in a single transaction.
const std = @import("std");
const text = @import("zircon_text");
const ui = @import("zircon_ui");
const editor = @import("editor.zig");
const vim_geometry = @import("vim_geometry.zig");
const Editor = editor.Editor;
const Outcome = editor.Outcome;
pub fn block(self: *Editor, doc: *text.Document, before: bool, count: usize, event: *ui.Event(ui.Input)) !Outcome {
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = doc.snapshot();
    defer s.deinit();
    var parts: std.ArrayList([]const u8) = .empty;
    var rows = std.mem.splitScalar(u8, self.vim.register, '\n');
    while (rows.next()) |row| try parts.append(a, row);
    var edits: std.ArrayList(text.Edit) = .empty;
    if (self.vim.mode == .visual_block) {
        for (self.selections.items.items, 0..) |item, i| {
            var bytes: std.ArrayList(u8) = .empty;
            for (0..count) |_| try bytes.appendSlice(a, parts.items[i % parts.items.len]);
            try edits.append(a, .{ .range = item.range(), .text = bytes.items });
        }
    } else {
        const point = try s.pointAt(self.vim.cursor);
        const line = try s.lineRange(point.line);
        const base = if (!before and self.vim.cursor < line.end) try s.nextBoundary(self.vim.cursor) else self.vim.cursor;
        self.preferred_x = null;
        for (parts.items, 0..) |part, i| {
            const row = point.line + i;
            var bytes: std.ArrayList(u8) = .empty;
            if (row >= s.lineCount()) {
                try bytes.append(a, '\n');
                // Source byte columns are used only for padding brand-new ASCII spaces.
                const col = (try s.pointAt(base)).byte_column;
                try bytes.appendNTimes(a, ' ', col);
            }
            for (0..count) |_| try bytes.appendSlice(a, part);
            const at = if (row < s.lineCount()) try vim_geometry.vertical(self, s, base, row, event) else s.byteLen();
            if (edits.items.len > 0 and edits.items[edits.items.len - 1].range.start == at) {
                const last = &edits.items[edits.items.len - 1];
                last.text = try std.mem.concat(a, u8, &.{ last.text, bytes.items });
            } else try edits.append(a, .{ .range = .{ .start = at, .end = at }, .text = bytes.items });
        }
    }
    self.typing_group = 0;
    return self.applyEdits(doc, edits.items, 0);
}
