//! Line commenting shares the normal editor transaction and preserves selections.
const std = @import("std");
const text = @import("zircon_text");
const editor = @import("editor.zig");
const profile = @import("profile.zig");
const selections_module = @import("selections.zig");
const Editor = editor.Editor;
const Outcome = editor.Outcome;
pub fn toggle(self: *Editor, document: *text.Document, snapshot: text.Snapshot) !Outcome {
    const prefix = if (self.language_profile) |p| p.line_comment else switch (self.language) {
        .zig, .rust => @as(?[]const u8, "//"),
        else => null,
    };
    const block: ?profile.Block = if (self.language_profile) |p| p.block_comment else if (self.language == .markdown) .{ .start = "<!--", .end = "-->" } else null;
    if (prefix == null and block == null) return error.CommentNotSupported;
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var rows: std.ArrayList(struct { at: usize, end: usize }) = .empty;
    self.selections.normalize();
    var last: ?usize = null;
    var remove = true;
    const open = std.mem.trimEnd(u8, prefix orelse block.?.start, " \t");
    if (open.len == 0) return error.CommentNotSupported;
    for (self.selections.items.items) |item| {
        const first = (try snapshot.pointAt(item.range().start)).line;
        var end = (try snapshot.pointAt(item.range().end)).line;
        if (!item.empty() and item.range().end == try snapshot.lineStart(end)) end -|= 1;
        for (first..end + 1) |row| {
            if (last != null and row <= last.?) continue;
            last = row;
            const range = try snapshot.lineRange(row);
            const bytes = try snapshot.copy(a, range);
            const leading = bytes.len - std.mem.trimStart(u8, bytes, " \t").len;
            const trimmed = std.mem.trimEnd(u8, bytes[leading..], " \t");
            const commented = std.mem.startsWith(u8, trimmed, open) and (prefix != null or std.mem.endsWith(u8, trimmed, block.?.end));
            remove = remove and commented;
            try rows.append(a, .{ .at = range.start + leading, .end = range.start + leading + trimmed.len });
        }
    }
    var edits: std.ArrayList(text.Edit) = .empty;
    for (rows.items) |row| {
        var n = open.len;
        if (remove and row.at + n < row.end and try snapshot.byteAt(row.at + n) == ' ') n += 1;
        try edits.append(a, .{ .range = .{ .start = row.at, .end = row.at + if (remove) n else @as(usize, 0) }, .text = if (remove) "" else try std.mem.concat(a, u8, &.{ open, " " }) });
        if (prefix == null) {
            var close = row.end -| block.?.end.len;
            if (remove and close > row.at + n and try snapshot.byteAt(close - 1) == ' ') close -= 1;
            try edits.append(a, .{ .range = .{ .start = if (remove) close else row.end, .end = row.end }, .text = if (remove) "" else try std.mem.concat(a, u8, &.{ " ", block.?.end }) });
        }
    }
    const previous = try a.dupe(selections_module.Selection, self.selections.items.items);
    const restored = try self.allocator.alloc(selections_module.Selection, previous.len);
    errdefer self.allocator.free(restored);
    const result = try self.applyEdits(document, edits.items, 0);
    if (result.change) |change| {
        for (previous, restored) |old, *mapped| mapped.* = .{ .anchor = change.map(old.anchor, .after), .head = change.map(old.head, .after) };
        self.selections.items.clearRetainingCapacity();
        self.selections.items.appendSliceAssumeCapacity(restored);
        self.allocator.free(self.history.items[self.history.items.len - 1].items);
        self.history.items[self.history.items.len - 1].items = restored;
        self.vim.cursor = change.map(self.vim.cursor, .after);
    } else self.allocator.free(restored);
    self.typing_group = 0;
    return result;
}
