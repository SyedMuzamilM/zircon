//! Immutable, selectable patch text. The ordinary editor owns selection and
//! navigation; rows map its byte coordinates back to displayed Git lines.

const std = @import("std");
const editing = @import("zircon_editor");
const git = @import("zircon_git");
const text = @import("zircon_text");
const ui = @import("zircon_ui");
const layout = @import("layout.zig");
pub const Side = enum { unified, old, new };
pub const Row = struct {
    segments: []const editing.wrap.Row = &.{},
    visual_lines: usize = 1,
    hunk: usize,
    line: usize,
    path: []const u8,
    original: git.Line,
    range: text.Range,
    fixed_top: f32,
    code_before: usize,
    pub fn top(self: Row, line_height: f32) f32 {
        return self.fixed_top + @as(f32, @floatFromInt(self.code_before)) * line_height;
    }
};

pub const Review = struct {
    arena: std.heap.ArenaAllocator,
    document: text.Document,
    editor: editing.Editor,
    rows: []Row,
    side: Side,
    focused: bool = false,

    pub fn init(a: std.mem.Allocator, diff: git.Diff, projection: layout.Projection, state: *const layout.State, side: Side) !Review {
        var arena = std.heap.ArenaAllocator.init(a);
        errdefer arena.deinit();
        const aa = arena.allocator();
        var bytes: std.ArrayList(u8) = .empty;
        var rows: std.ArrayList(Row) = .empty;
        var fixed: f32 = 0;
        var codes: usize = 0;
        for (projection.files) |file| {
            fixed += layout.file_height;
            if (state.collapsed.contains(file.path)) continue;
            const path = try aa.dupe(u8, file.path);
            for (file.rows(state.mode)) |row| switch (row.kind) {
                .hunk => fixed += layout.context_height,
                .code => |code| {
                    defer codes += 1;
                    const at = (switch (side) {
                        .unified => code.new orelse code.old,
                        .old => code.old,
                        .new => code.new,
                    }) orelse continue;
                    const lines = diff.hunks[code.hunk].lines;
                    const original = lines[at];
                    if (original.kind == .metadata) continue;
                    if (bytes.items.len > 0 and bytes.items[bytes.items.len - 1] != '\n') try bytes.append(aa, '\n');
                    const start = bytes.items.len;
                    // Invalid byte sequences remain visible metadata, never an
                    // editable source mapping into a UTF-8 document.
                    var owned = original;
                    owned.text = try aa.dupe(u8, if (std.unicode.utf8ValidateSlice(original.text)) original.text else "[Non-UTF-8 source line]");
                    if (!std.unicode.utf8ValidateSlice(original.text)) owned.new_line = null;
                    try bytes.appendSlice(aa, owned.text);
                    const no_newline = at + 1 < lines.len and lines[at + 1].kind == .metadata and std.mem.indexOf(u8, lines[at + 1].text, "No newline") != null;
                    if (!no_newline) try bytes.append(aa, '\n');
                    try rows.append(aa, .{ .hunk = code.hunk, .line = at, .path = path, .original = owned, .range = .{ .start = start, .end = bytes.items.len }, .fixed_top = fixed, .code_before = codes });
                },
            };
        }
        var document = try text.Document.init(a, bytes.items);
        errdefer document.deinit();
        document.setHistoryLimit(0);
        var editor = try editing.Editor.init(a);
        errdefer editor.deinit();
        editor.show_fold_controls = false;
        editor.show_git_gutters = false;
        editor.show_line_numbers = false;
        editor.show_indent_guides = false;
        editor.auto_close_pairs = false;
        var result: Review = .{ .arena = arena, .document = document, .editor = editor, .rows = rows.items, .side = side };
        result.reflow(projection, state);
        return result;
    }

    pub fn deinit(self: *Review) void {
        self.editor.deinit();
        self.document.deinit();
        self.arena.deinit();
    }

    pub fn rowAt(self: *const Review, at: usize) ?usize {
        if (self.rows.len == 0) return null;
        var lo: usize = 0;
        var hi = self.rows.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.rows[mid].range.start <= at) lo = mid + 1 else hi = mid;
        }
        return lo -| 1;
    }

    pub fn reflow(self: *const Review, projection: layout.Projection, state: *const layout.State) void {
        var fixed: f32 = 0;
        var codes: usize = 0;
        var index: usize = 0;
        for (projection.files) |file| {
            fixed += layout.file_height;
            if (state.collapsed.contains(file.path)) continue;
            for (file.rows(state.mode)) |row| switch (row.kind) {
                .hunk => fixed += layout.context_height,
                .code => |code| {
                    const visual = row.visual.?;
                    const at = (switch (self.side) {
                        .unified => code.new orelse code.old,
                        .old => code.old,
                        .new => code.new,
                    }) orelse {
                        codes += visual.lines;
                        continue;
                    };
                    if (index < self.rows.len and self.rows[index].hunk == code.hunk and self.rows[index].line == at) {
                        const item = &self.rows[index];
                        item.fixed_top = fixed;
                        item.code_before = codes;
                        item.visual_lines = visual.lines;
                        item.segments = if (self.side == .old or code.new == null) visual.old else visual.new;
                        index += 1;
                    }
                    codes += visual.lines;
                },
            };
        }
    }

    /// During a drag, headers and split alignment padding resolve to the
    /// nearest text row. A new click must hit actual code.
    pub fn hit(self: *const Review, y: f32, line_height: f32, dragging: bool) ?usize {
        if (self.rows.len == 0) return null;
        var lo: usize = 0;
        var hi = self.rows.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.rows[mid].top(line_height) + @as(f32, @floatFromInt(self.rows[mid].visual_lines)) * line_height <= y) lo = mid + 1 else hi = mid;
        }
        if (lo == self.rows.len) return if (dragging) lo - 1 else null;
        if (!dragging and y < self.rows[lo].top(line_height)) return null;
        if (!dragging and self.rows[lo].segments.len > 0 and y >= self.rows[lo].top(line_height) + @as(f32, @floatFromInt(self.rows[lo].segments.len)) * line_height) return null;
        return lo;
    }

    fn segmentAt(row: Row, offset: usize) usize {
        var index: usize = 0;
        for (row.segments, 0..) |part, at| {
            if (part.start > offset -| row.range.start) break;
            index = at;
        }
        return index;
    }

    pub fn caretY(self: *const Review) ?f32 {
        const row = self.rows[self.rowAt(self.editor.primary().head) orelse return null];
        return row.top(self.editor.line_height) + @as(f32, @floatFromInt(segmentAt(row, self.editor.primary().head))) * self.editor.line_height;
    }

    /// Move through visible wrapped text, skipping file headers and split padding.
    pub fn vertical(self: *Review, event: *ui.Event(ui.Input), key: ui.Key, extend: bool) !void {
        var at = self.rowAt(self.editor.primary().head) orelse return;
        const current = self.rows[at];
        var segment = segmentAt(current, self.editor.primary().head);
        const metrics = try event.textMetrics();
        var arena = std.heap.ArenaAllocator.init(self.editor.allocator);
        defer arena.deinit();
        const style: ui.TextStyle = .{ .size = self.editor.font_size, .mono = true };
        const source = try editing.display.Line.build(arena.allocator(), current.original.text, self.editor.tab_width);
        const origin = if (current.segments.len > 0) current.segments[segment].x else 0;
        const x = self.editor.preferred_x orelse source.caret(metrics, style, @min(current.original.text.len, self.editor.primary().head - current.range.start)) - origin;
        const amount: usize = if (key == .page_up or key == .page_down) @max(1, @as(usize, @intFromFloat(event.bounds.height / self.editor.line_height))) else 1;
        const forward = key == .down or key == .page_down;
        for (0..amount) |_| {
            if (forward) {
                if (segment + 1 < self.rows[at].segments.len) segment += 1 else if (at + 1 < self.rows.len) {
                    at += 1;
                    segment = 0;
                } else break;
            } else {
                if (segment > 0) segment -= 1 else if (at > 0) {
                    at -= 1;
                    segment = self.rows[at].segments.len -| 1;
                } else break;
            }
        }
        const target = self.rows[at];
        const target_line = try editing.display.Line.build(arena.allocator(), target.original.text, self.editor.tab_width);
        const part = if (target.segments.len > 0) target.segments[segment] else null;
        var column = target_line.index(metrics, style, x + if (part) |value| value.x else 0);
        if (part) |value| column = std.math.clamp(column, value.start, value.end);
        const head = target.range.start + column;
        self.editor.selections.single(.{ .anchor = if (extend) self.editor.primary().anchor else head, .head = head });
        self.editor.preferred_x = x;
        self.editor.typing_group = 0;
    }

    pub fn selected(self: *const Review, hunk: usize, line: usize, side: Side) ?text.Range {
        if (!self.focused or self.side != side) return null;
        const range = self.editor.primary().range();
        var lo: usize = 0;
        var hi = self.rows.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const row = self.rows[mid];
            if (row.hunk < hunk or (row.hunk == hunk and row.line < line)) lo = mid + 1 else hi = mid;
        }
        if (lo < self.rows.len) {
            const row = self.rows[lo];
            if (row.hunk != hunk or row.line != line) return null;
            const start = @max(range.start, row.range.start);
            const end = @min(range.end, row.range.end);
            if (start >= end) return null;
            return .{ .start = start - row.range.start, .end = end - row.range.start };
        }
        return null;
    }

    /// Preserve selection across a refreshed patch only when both endpoints
    /// still identify the same text. Never reuse offsets against another file.
    pub fn retainSelection(self: *Review, before: *const Review) void {
        if (!before.focused or self.side != before.side) return;
        const previous = before.editor.primary();
        const anchor = self.remap(before, previous.anchor) orelse return;
        const head = self.remap(before, previous.head) orelse return;
        self.editor.selections.single(.{ .anchor = anchor, .head = head });
        self.editor.dragging = before.editor.dragging;
        self.focused = true;
    }

    fn remap(self: *const Review, before: *const Review, at: usize) ?usize {
        const old = before.rows[before.rowAt(at) orelse return null];
        var match: ?Row = null;
        var matches: usize = 0;
        for (self.rows) |row| {
            if (!std.mem.eql(u8, row.path, old.path) or row.original.kind != old.original.kind or !std.mem.eql(u8, row.original.text, old.original.text)) continue;
            if (row.original.new_line == old.original.new_line and row.original.old_line == old.original.old_line) return row.range.start + @min(at - old.range.start, row.range.end - row.range.start);
            match = row;
            matches += 1;
        }
        if (matches != 1) return null;
        const row = match orelse return null;
        return row.range.start + @min(at - old.range.start, row.range.end - row.range.start);
    }
};
