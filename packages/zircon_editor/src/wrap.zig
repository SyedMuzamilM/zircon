//! Cached visual rows. Source offsets never change when a viewport wraps.
const std = @import("std");
const text = @import("zircon_text");
const ui = @import("zircon_ui");
const display = @import("display.zig");
const annotations = @import("annotations.zig");
pub const Mode = enum { none, editor_width };
// Subtract x from shaped source positions to get row-local positions. For a
// continuation it includes the repeated indentation, without inserting bytes.
pub const Row = struct { line: usize, start: usize, end: usize, x: f32, first: bool };
pub const Cache = struct {
    allocator: std.mem.Allocator,
    refs: usize = 1,
    revision: ?u64 = null,
    state_id: u64 = 0,
    width: f32 = 0,
    font_size: f32 = 0,
    tab_width: usize = 0,
    folding: @import("folding.zig").State = .{},
    rows: std.ArrayList(Row) = .empty,
    starts: std.ArrayList(usize) = .empty,
    builds: usize = 0,
    shaped_lines: usize = 0,
    pending: ?struct { after: u64, first: usize, end_after: usize, delta: i64 } = null,
    pub fn noteChange(self: *Cache, change: *const text.Change) void {
        self.folding.noteChange(change);
        if (self.folding.collapsed.items.len > 0 or self.revision != change.before or self.rows.items.len == 0 or change.mappings.len == 0) {
            self.pending = null;
            return;
        }
        var delta: i64 = 0;
        for (change.mappings) |mapping| delta += @as(i64, @intCast(mapping.inserted)) - @as(i64, @intCast(mapping.range.end - mapping.range.start));
        const first = change.mappings[0].range.start;
        const last = change.mappings[change.mappings.len - 1].range.end;
        self.pending = .{ .after = change.after, .first = self.rows.items[self.atOffset(first)].line, .end_after = change.map(last, .after), .delta = delta };
    }
    pub fn init(a: std.mem.Allocator) !*Cache {
        const value = try a.create(Cache);
        value.* = .{ .allocator = a };
        return value;
    }
    pub fn retain(self: *Cache) *Cache {
        self.refs += 1;
        return self;
    }
    pub fn release(self: *Cache) void {
        self.refs -= 1;
        if (self.refs == 0) {
            const a = self.allocator;
            self.folding.deinit(a);
            self.rows.deinit(a);
            self.starts.deinit(a);
            a.destroy(self);
        }
    }
    pub fn ensure(self: *Cache, s: text.Snapshot, width: f32, font_size: f32, tabs: usize, metrics: ui.layout.Measurer) !void {
        const available = @max(font_size * 2, width);
        if (self.revision == s.revision() and self.state_id == s.stateId() and self.width == available and self.font_size == font_size and self.tab_width == tabs) return;
        var rows: std.ArrayList(Row) = .empty;
        errdefer rows.deinit(self.allocator);
        var starts: std.ArrayList(usize) = .empty;
        errdefer starts.deinit(self.allocator);
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const pending = if (self.revision != null and self.pending != null and self.pending.?.after == s.revision() and self.width == available and self.font_size == font_size and self.tab_width == tabs) self.pending else null;
        const new_last = if (pending) |change| (try s.pointAt(change.end_after)).line else 0;
        const delta_lines = @as(i64, @intCast(s.lineCount())) - @as(i64, @intCast(self.starts.items.len -| 1));
        const style: ui.TextStyle = .{ .size = font_size, .mono = true };
        try self.folding.ensure(self.allocator, s, tabs);
        var fold_index: usize = 0;
        var hidden_end: ?usize = null;
        for (0..s.lineCount()) |line| {
            _ = arena.reset(.retain_capacity);
            try starts.append(self.allocator, rows.items.len);
            const line_start = try s.lineStart(line);
            while (fold_index < self.folding.collapsed.items.len and self.folding.collapsed.items[fold_index].start < line_start) : (fold_index += 1) hidden_end = @max(hidden_end orelse 0, self.folding.collapsed.items[fold_index].end);
            if (hidden_end != null and line_start <= hidden_end.?) continue;
            if (pending) |change| {
                if (line < change.first or line > new_last) {
                    const old_line: usize = if (line < change.first) line else @intCast(@as(i64, @intCast(line)) - delta_lines);
                    for (self.rows.items[self.starts.items[old_line]..self.starts.items[old_line + 1]]) |old| {
                        var copied = old;
                        if (line > new_last) {
                            copied.line = line;
                            copied.start = @intCast(@as(i64, @intCast(old.start)) + change.delta);
                            copied.end = @intCast(@as(i64, @intCast(old.end)) + change.delta);
                        }
                        try rows.append(self.allocator, copied);
                    }
                    continue;
                }
            }
            self.shaped_lines += 1;
            const range = try s.lineRange(line);
            // Retain the existing oversized-line policy rather than shaping an
            // unbounded source line on the UI thread.
            const original = if (range.end - range.start > 64 * 1024) "" else try s.copy(arena.allocator(), range);
            const expanded = try display.Line.build(arena.allocator(), original, tabs);
            var leading: usize = 0;
            while (leading < original.len and (original[leading] == ' ' or original[leading] == '\t')) leading += 1;
            const indent = if (leading == original.len) 0 else @min(expanded.caret(metrics, style, leading), available / 2);
            var start: usize = 0;
            while (true) {
                const x = expanded.caret(metrics, style, start);
                const hanging = if (start == 0) 0 else indent;
                const row_width = available - hanging;
                var end = expanded.index(metrics, style, x + row_width);
                end = @min(original.len, end);
                // Hit testing chooses nearest; wrapping needs the last fitting
                // boundary, otherwise a glyph can cross the pane edge.
                while (end > start and expanded.caret(metrics, style, end) - x > row_width) end = previous(original, end);
                if (end <= start and start < original.len) end = start + (std.unicode.utf8ByteSequenceLength(original[start]) catch 1);
                if (end < original.len) {
                    var word = end;
                    while (word > start and original[word - 1] != ' ' and original[word - 1] != '\t') word = previous(original, word);
                    if (word > @max(start, leading)) end = word;
                }
                try rows.append(self.allocator, .{ .line = line, .start = range.start + start, .end = if (original.len == 0) range.end else range.start + end, .x = x - hanging, .first = start == 0 });
                if (end >= original.len) break;
                start = end;
            }
        }
        try starts.append(self.allocator, rows.items.len);
        self.rows.deinit(self.allocator);
        self.starts.deinit(self.allocator);
        self.rows = rows;
        self.starts = starts;
        self.revision = s.revision();
        self.state_id = s.stateId();
        self.width = available;
        self.font_size = font_size;
        self.tab_width = tabs;
        self.builds += 1;
        self.pending = null;
    }
    pub fn valid(self: *const Cache, revision: u64) bool {
        return self.revision == revision and self.rows.items.len > 0;
    }
    pub fn atOffset(self: *const Cache, offset: usize) usize {
        var lo: usize = 0;
        var hi = self.rows.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.rows.items[mid].start <= offset) lo = mid + 1 else hi = mid;
        }
        return lo -| 1;
    }
    pub fn y(self: *const Cache, line: usize, height: f32, changes: []const annotations.GitChange) f32 {
        const index = self.starts.items[@min(line, self.starts.items.len - 1)];
        return @as(f32, @floatFromInt(index + annotations.insertedRows(changes, line))) * height;
    }
    pub fn visualAt(self: *const Cache, y_position: f32, height: f32, changes: []const annotations.GitChange) usize {
        for (changes) |change| if (change.expanded and change.old_count > 0 and change.start + 1 < self.starts.items.len) {
            const bottom = self.y(change.start, height, changes);
            const top = bottom - @as(f32, @floatFromInt(change.old_count)) * height;
            if (y_position >= top and y_position < bottom) return self.starts.items[change.start];
        };
        var lo: usize = 0;
        var hi = self.rows.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const top = self.rowY(mid, height, changes);
            if (top <= y_position) lo = mid + 1 else hi = mid;
        }
        return lo -| 1;
    }
    pub fn rowY(self: *const Cache, index: usize, height: f32, changes: []const annotations.GitChange) f32 {
        return @as(f32, @floatFromInt(index + annotations.insertedRows(changes, self.rows.items[index].line))) * height;
    }
};
fn previous(bytes: []const u8, at: usize) usize {
    var i = at -| 1;
    while (i > 0 and bytes[i] & 0xc0 == 0x80) i -= 1;
    return i;
}
