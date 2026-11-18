//! Cached visual rows. Source offsets never change when a viewport wraps.

const std = @import("std");
const text = @import("zircon_text");
const ui = @import("zircon_ui");
const annotations = @import("annotations.zig");
const display = @import("display.zig");
const folding_module = @import("folding.zig");
const index = @import("wrap_index.zig");
pub const Mode = enum { none, editor_width };
// Subtract x from shaped source positions to get row-local positions. For a
// continuation it includes the repeated indentation, without inserting bytes.
pub const Row = index.Row;
const Patch = struct { start: usize, end: usize, new_end_offset: usize };
const LineRange = struct { first: usize, end: usize };

pub const Cache = struct {
    allocator: std.mem.Allocator,
    refs: usize = 1,
    revision: ?u64 = null,
    state_id: u64 = 0,
    width: f32 = 0,
    font_size: f32 = 0,
    tab_width: usize = 0,
    folding: folding_module.State = .{},
    root: ?*index.Node = null,
    builds: usize = 0,
    shaped_lines: usize = 0,
    excerpt_ranges: ?std.ArrayList(text.Range) = null,
    patches: std.ArrayList(Patch) = .empty,
    pending: ?struct { revision: u64, state_id: u64 } = null,

    /// Composite editors shape only their displayed source ranges.
    pub fn setExcerpts(self: *Cache, ranges: []const text.Range) !void {
        if (self.excerpt_ranges) |*old| {
            if (old.items.len == ranges.len) {
                for (old.items, ranges) |left, right| {
                    if (!std.meta.eql(left, right)) break;
                } else return;
            }
            try old.ensureTotalCapacity(self.allocator, ranges.len);
            old.clearRetainingCapacity();
            old.appendSliceAssumeCapacity(ranges);
        } else {
            var list: std.ArrayList(text.Range) = .empty;
            try list.appendSlice(self.allocator, ranges);
            self.excerpt_ranges = list;
        }
        self.revision = null;
        self.pending = null;
    }

    pub fn noteChange(self: *Cache, change: *const text.Change) void {
        if (self.excerpt_ranges) |*ranges| for (ranges.items) |*range| {
            range.start = change.map(range.start, .before);
            range.end = change.map(range.end, .after);
        };
        self.folding.noteChange(change);
        self.pending = null;
        self.patches.clearRetainingCapacity();
        if (self.folding.collapsed.items.len > 0 or self.revision != change.before or change.mappings.len == 0) return;
        const root = self.root orelse return;
        self.patches.ensureTotalCapacity(self.allocator, change.mappings.len) catch return;
        var old_end: usize = 0;
        var new_end: usize = 0;
        for (change.mappings) |mapping| {
            new_end += mapping.range.start - old_end + mapping.inserted;
            old_end = mapping.range.end;
            const start = index.lineAtOffset(root, mapping.range.start);
            const end = index.lineAtOffset(root, old_end) + 1;
            if (self.patches.getLastOrNull()) |previous_patch| {
                if (start < previous_patch.end) {
                    self.patches.items[self.patches.items.len - 1] = .{ .start = previous_patch.start, .end = end, .new_end_offset = new_end };
                    continue;
                }
            }
            self.patches.appendAssumeCapacity(.{ .start = start, .end = end, .new_end_offset = new_end });
        }
        self.pending = .{ .revision = change.after, .state_id = change.state };
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
            index.release(a, self.root);
            self.patches.deinit(a);
            if (self.excerpt_ranges) |*ranges| ranges.deinit(a);
            a.destroy(self);
        }
    }

    pub fn ensure(self: *Cache, s: text.Snapshot, width: f32, font_size: f32, tabs: usize, metrics: ui.layout.Measurer) !void {
        const available = @max(font_size * 2, width);
        const same_geometry = self.width == available and self.font_size == font_size and self.tab_width == tabs;
        if (self.revision == s.revision() and self.state_id == s.stateId() and same_geometry) return;
        const a = self.allocator;
        if (self.excerpt_ranges == null and self.folding.collapsed.items.len > 0) try self.folding.ensure(a, s, tabs);

        const excerpts = if (self.excerpt_ranges) |ranges| ranges.items else &.{};
        const excerpt_rows = try a.alloc(LineRange, excerpts.len);
        defer a.free(excerpt_rows);
        for (excerpts, excerpt_rows) |range, *rows_range| {
            const first = try s.pointAt(range.start);
            const last = try s.pointAt(range.end);
            rows_range.* = .{ .first = first.line, .end = last.line + @as(usize, @intFromBool(range.start == range.end or last.byte_column != 0)) };
        }

        var builder: Builder = .{
            .snapshot = s,
            .allocator = a,
            .arena = .init(a),
            .width = available,
            .font_size = font_size,
            .tabs = tabs,
            .metrics = metrics,
            .excerpts = if (self.excerpt_ranges != null) excerpt_rows else null,
            .folds = self.folding.collapsed.items,
        };
        defer builder.arena.deinit();
        defer builder.segments.deinit(a);
        const can_patch = if (self.pending) |pending|
            self.revision != null and same_geometry and pending.revision == s.revision() and pending.state_id == s.stateId()
        else
            false;
        const next = if (can_patch) try self.patch(&builder) else try builder.build(0, s.lineCount());
        index.release(a, self.root);
        self.root = next;
        self.revision = s.revision();
        self.state_id = s.stateId();
        self.width = available;
        self.font_size = font_size;
        self.tab_width = tabs;
        self.builds += 1;
        self.shaped_lines += builder.shaped_lines;
        self.pending = null;
    }

    fn patch(self: *const Cache, builder: *Builder) !?*index.Node {
        const a = self.allocator;
        var result: ?*index.Node = null;
        defer index.release(a, result);
        var old_at: usize = 0;
        var new_at: usize = 0;
        for (self.patches.items) |delta| {
            const unchanged = try index.slice(a, self.root, old_at, delta.start);
            defer index.release(a, unchanged);
            const prefix = try index.join(a, result, unchanged);
            defer index.release(a, prefix);
            const new_start = new_at + delta.start - old_at;
            const new_end = (try builder.snapshot.pointAt(delta.new_end_offset)).line + 1;
            const changed = try builder.build(new_start, new_end);
            defer index.release(a, changed);
            const next = try index.join(a, prefix, changed);
            index.release(a, result);
            result = next;
            old_at = delta.end;
            new_at = new_end;
        }
        const suffix = try index.slice(a, self.root, old_at, index.measure(self.root).lines);
        defer index.release(a, suffix);
        return index.join(a, result, suffix);
    }

    pub fn valid(self: *const Cache, revision: u64) bool {
        return self.revision == revision and self.rowCount() > 0;
    }

    pub fn rowCount(self: *const Cache) usize {
        return index.measure(self.root).rows;
    }

    pub fn rowAt(self: *const Cache, row: usize) Row {
        return index.rowAt(self.root.?, row);
    }

    pub fn rowStart(self: *const Cache, line: usize) usize {
        return index.rowStart(self.root, line);
    }

    pub fn atOffset(self: *const Cache, offset: usize) usize {
        return if (self.root) |root| index.rowAtOffset(root, offset) else 0;
    }

    pub fn y(self: *const Cache, line: usize, height: f32, changes: []const annotations.GitChange) f32 {
        return @as(f32, @floatFromInt(self.rowStart(line) + annotations.insertedRows(changes, line))) * height;
    }

    pub fn visualAt(self: *const Cache, y_position: f32, height: f32, changes: []const annotations.GitChange) usize {
        const count = self.rowCount();
        if (count == 0 or !(y_position > 0)) return 0;
        if (changes.len == 0) {
            const quotient = @floor(y_position / height);
            const row = if (quotient >= @as(f32, @floatFromInt(count - 1))) count - 1 else @as(usize, @intFromFloat(quotient));
            // The screen coordinate was rounded when its row was multiplied
            // by height, so division can land on the neighboring row.
            if (@as(f32, @floatFromInt(row)) * height > y_position) return row -| 1;
            if (row + 1 < count and @as(f32, @floatFromInt(row + 1)) * height <= y_position) return row + 1;
            return row;
        }
        for (changes) |change| if (change.expanded and change.old_count > 0 and change.start < index.measure(self.root).lines) {
            const bottom = self.y(change.start, height, changes);
            const top = bottom - @as(f32, @floatFromInt(change.old_count)) * height;
            if (y_position >= top and y_position < bottom) return @min(self.rowStart(change.start), count - 1);
        };
        var lo: usize = 0;
        var hi = count;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.rowY(mid, height, changes) <= y_position) lo = mid + 1 else hi = mid;
        }
        return lo -| 1;
    }

    pub fn rowY(self: *const Cache, row: usize, height: f32, changes: []const annotations.GitChange) f32 {
        return @as(f32, @floatFromInt(row + annotations.insertedRows(changes, self.rowAt(row).line))) * height;
    }
};

const Builder = struct {
    snapshot: text.Snapshot,
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    width: f32,
    font_size: f32,
    tabs: usize,
    metrics: ui.layout.Measurer,
    excerpts: ?[]const LineRange,
    folds: []const text.Range,
    excerpt_index: usize = 0,
    fold_index: usize = 0,
    hidden_end: ?usize = null,
    segments: std.ArrayList(index.Segment) = .empty,
    shaped_lines: usize = 0,

    fn build(self: *Builder, first: usize, end: usize) error{ OutOfMemory, InvalidUtf8, InvalidTabWidth }!?*index.Node {
        std.debug.assert(end >= first);
        const count = end - first;
        const a = self.allocator;
        if (count == 0) return null;
        if (count > index.leaf_lines) {
            const mid = first + count / 2;
            const left = (try self.build(first, mid)).?;
            defer index.release(a, left);
            const right = (try self.build(mid, end)).?;
            defer index.release(a, right);
            return try index.branch(a, left, right);
        }

        var lines: [index.leaf_lines]index.Line = undefined;
        self.segments.clearRetainingCapacity();
        var start = self.snapshot.lineStart(first) catch unreachable;
        for (first..end, lines[0..count]) |line, *entry| {
            const next = if (line + 1 == self.snapshot.lineCount()) self.snapshot.byteLen() else self.snapshot.lineStart(line + 1) catch unreachable;
            entry.* = .{ .bytes = next - start, .rows = 0 };
            const line_start = start;
            start = next;
            if (!self.visible(line, line_start)) continue;
            if (self.tabs == 0) return error.InvalidTabWidth;

            _ = self.arena.reset(.retain_capacity);
            const scratch = self.arena.allocator();
            self.shaped_lines += 1;
            var content_end = if (line + 1 == self.snapshot.lineCount()) next else next - 1;
            if (content_end < next and content_end > line_start and (self.snapshot.byteAt(content_end - 1) catch unreachable) == '\r') content_end -= 1;
            const content_len = content_end - line_start;
            if (content_len == 0 or content_len > 64 * 1024) {
                try self.segments.append(a, .{ .start = 0, .end = content_len, .x = 0 });
                entry.rows = 1;
                continue;
            }
            const original = self.snapshot.copy(scratch, .{ .start = line_start, .end = content_end }) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => unreachable,
            };
            const pieces = try segments(scratch, original, 0, self.width, self.font_size, self.tabs, self.metrics);
            try self.segments.ensureUnusedCapacity(a, pieces.len);
            for (pieces) |piece| self.segments.appendAssumeCapacity(.{ .start = piece.start, .end = piece.end, .x = piece.x });
            entry.rows = pieces.len;
        }
        return try index.leaf(a, lines[0..count], self.segments.items);
    }

    fn visible(self: *Builder, line: usize, start: usize) bool {
        if (self.excerpts) |excerpts| {
            while (self.excerpt_index < excerpts.len and line >= excerpts[self.excerpt_index].end) : (self.excerpt_index += 1) {}
            if (self.excerpt_index == excerpts.len or line < excerpts[self.excerpt_index].first) return false;
        }
        while (self.fold_index < self.folds.len and self.folds[self.fold_index].start < start) : (self.fold_index += 1)
            self.hidden_end = @max(self.hidden_end orelse 0, self.folds[self.fold_index].end);
        return if (self.hidden_end) |end| start > end else true;
    }
};

fn previous(bytes: []const u8, at: usize) usize {
    var i = at -| 1;
    while (i > 0 and bytes[i] & 0xc0 == 0x80) i -= 1;
    return i;
}

/// Shape one logical line using the same wrapping rules as a source editor.
pub fn segments(a: std.mem.Allocator, original: []const u8, source_start: usize, width: f32, font_size: f32, tabs: usize, metrics: ui.layout.Measurer) ![]Row {
    const available = @max(font_size * 2, width);
    const style: ui.TextStyle = .{ .size = font_size, .mono = true };
    var rows: std.ArrayList(Row) = .empty;
    errdefer rows.deinit(a);
    const expanded = try display.Line.build(a, original, tabs);
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
        try rows.append(a, .{ .line = 0, .start = source_start + start, .end = if (original.len == 0) source_start + original.len else source_start + end, .x = x - hanging, .first = start == 0 });
        if (end >= original.len) break;
        start = end;
    }
    return try rows.toOwnedSlice(a);
}
