//! Immutable borrowed reads with one owned rope-root reference. clone/deinit
//! change UI-thread reference counts; read-only operations may run on a worker
//! while that owner retains the snapshot until the worker has joined.

const std = @import("std");
const grapheme = @import("grapheme.zig");
const rope = @import("rope.zig");
const search = @import("search.zig");
const types = @import("types.zig");
/// Borrowed iteration over consecutive line ranges without repeatedly seeking
/// the same rope leaves. The source snapshot must outlive the iterator.
pub const LineIterator = struct {
    pub const Line = struct {
        range: types.Range,
        /// Borrowed directly from the rope when the content fits one leaf.
        bytes: ?[]const u8 = null,
    };

    leaves: rope.Iterator,
    remaining: []const u8 = &.{},
    offset: usize,
    done: bool = false,

    pub fn next(self: *LineIterator) ?Line {
        if (self.done) return null;
        const start = self.offset;
        var previous_cr = false;
        while (true) {
            if (self.remaining.len == 0) self.remaining = self.leaves.next() orelse {
                self.done = true;
                return .{ .range = .{ .start = start, .end = self.offset } };
            };
            if (std.mem.indexOfScalar(u8, self.remaining, '\n')) |lf| {
                const cr = if (lf == 0) previous_cr else self.remaining[lf - 1] == '\r';
                const end = self.offset + lf - @intFromBool(cr);
                const bytes = if (self.offset == start) self.remaining[0 .. end - start] else null;
                self.offset += lf + 1;
                self.remaining = self.remaining[lf + 1 ..];
                return .{ .range = .{ .start = start, .end = end }, .bytes = bytes };
            }
            previous_cr = self.remaining[self.remaining.len - 1] == '\r';
            self.offset += self.remaining.len;
            self.remaining = &.{};
        }
    }
};

pub const Snapshot = struct {
    allocator: std.mem.Allocator,
    root: ?*rope.Node,
    revision_value: u64,
    state_value: u64,
    owner: std.Thread.Id,
    pub fn clone(self: Snapshot) Snapshot {
        std.debug.assert(self.owner == std.Thread.getCurrentId());
        var result = self;
        result.root = rope.retain(self.root);
        return result;
    }
    pub fn deinit(self: *Snapshot) void {
        std.debug.assert(self.owner == std.Thread.getCurrentId());
        rope.release(self.allocator, self.root);
        self.* = undefined;
    }
    pub fn revision(self: Snapshot) u64 {
        return self.revision_value;
    }
    pub fn stateId(self: Snapshot) u64 {
        return self.state_value;
    }
    pub fn byteLen(self: Snapshot) usize {
        return rope.summary(self.root).bytes;
    }
    pub fn lineCount(self: Snapshot) usize {
        return rope.summary(self.root).lines + 1;
    }
    /// True when CR introduces a line without a following LF. Protocol clients
    /// use this to select universal-line coordinates without scanning LF/CRLF text.
    pub fn hasBareCarriageReturn(self: Snapshot) bool {
        return rope.summary(self.root).bare_cr != 0;
    }
    pub fn utf16Len(self: Snapshot) usize {
        return rope.summary(self.root).utf16;
    }
    pub fn isBoundary(self: Snapshot, offset: usize) bool {
        return rope.isBoundary(self.root, offset);
    }
    pub fn byteAt(self: Snapshot, offset: usize) !u8 {
        if (offset >= self.byteLen()) return error.InvalidOffset;
        return rope.byteAt(self.root.?, offset);
    }
    pub fn validateRange(self: Snapshot, range: types.Range) !void {
        if (range.start > range.end or !self.isBoundary(range.start) or !self.isBoundary(range.end)) return error.InvalidRange;
    }
    pub fn lineStart(self: Snapshot, line: usize) !usize {
        if (line >= self.lineCount()) return error.InvalidLine;
        return if (line == 0) 0 else rope.newline(self.root.?, line - 1) + 1;
    }
    /// Display content excludes LF and the CR immediately before that LF.
    pub fn lineRange(self: Snapshot, line: usize) !types.Range {
        const start = try self.lineStart(line);
        var end = if (line + 1 < self.lineCount()) rope.newline(self.root.?, line) else self.byteLen();
        if (line + 1 < self.lineCount() and end > start and rope.byteAt(self.root.?, end - 1) == '\r') end -= 1;
        return .{ .start = start, .end = end };
    }
    pub fn linesFrom(self: Snapshot, line: usize) !LineIterator {
        const start = try self.lineStart(line);
        return .{ .leaves = rope.Iterator.init(self.root, start, self.byteLen()), .offset = start };
    }
    /// Includes the original CRLF or LF bytes when this line has an ending.
    pub fn lineRangeIncludingEnding(self: Snapshot, line: usize) !types.Range {
        const start = try self.lineStart(line);
        return .{ .start = start, .end = if (line + 1 < self.lineCount()) rope.newline(self.root.?, line) + 1 else self.byteLen() };
    }
    pub fn pointAt(self: Snapshot, offset: usize) !types.Point {
        if (!self.isBoundary(offset)) return error.InvalidOffset;
        const line = rope.prefixMetrics(self.root, offset).lines;
        return .{ .line = line, .byte_column = offset - try self.lineStart(line) };
    }
    /// Byte columns may reach the LF position, including an existing CR. They
    /// may not cross into the next line or split a UTF-8 code point.
    pub fn offsetAt(self: Snapshot, point: types.Point) !usize {
        const start = try self.lineStart(point.line);
        const end = if (point.line + 1 < self.lineCount()) rope.newline(self.root.?, point.line) else self.byteLen();
        if (point.byte_column > end - start) return error.InvalidPoint;
        const offset = start + point.byte_column;
        if (!self.isBoundary(offset)) return error.InvalidPoint;
        return offset;
    }
    pub fn utf16Offset(self: Snapshot, offset: usize) !usize {
        if (!self.isBoundary(offset)) return error.InvalidOffset;
        return rope.prefixMetrics(self.root, offset).utf16;
    }
    pub fn byteOffsetFromUtf16(self: Snapshot, units: usize) !usize {
        return rope.offsetFromUtf16(self.root, units);
    }
    pub fn chunks(self: Snapshot, range: types.Range) !rope.Iterator {
        try self.validateRange(range);
        return rope.Iterator.init(self.root, range.start, range.end);
    }
    pub fn copy(self: Snapshot, a: std.mem.Allocator, range: types.Range) ![]u8 {
        var iterator = try self.chunks(range);
        const result = try a.alloc(u8, range.end - range.start);
        var at: usize = 0;
        while (iterator.next()) |part| {
            @memcpy(result[at..][0..part.len], part);
            at += part.len;
        }
        std.debug.assert(at == result.len);
        return result;
    }
    /// Moves one code point, treating CRLF as one line-ending step. This is not
    /// Unicode grapheme segmentation for combining marks or emoji sequences.
    pub fn previousBoundary(self: Snapshot, offset: usize) !usize {
        if (!self.isBoundary(offset)) return error.InvalidOffset;
        if (offset == 0) return 0;
        if (offset >= 2 and rope.byteAt(self.root.?, offset - 1) == '\n' and rope.byteAt(self.root.?, offset - 2) == '\r') return offset - 2;
        var previous = offset - 1;
        while (rope.byteAt(self.root.?, previous) & 0xc0 == 0x80) previous -= 1;
        return previous;
    }
    pub fn nextBoundary(self: Snapshot, offset: usize) !usize {
        if (!self.isBoundary(offset)) return error.InvalidOffset;
        if (offset == self.byteLen()) return offset;
        if (rope.byteAt(self.root.?, offset) == '\r' and offset + 1 < self.byteLen() and rope.byteAt(self.root.?, offset + 1) == '\n') return offset + 2;
        const length = std.unicode.utf8ByteSequenceLength(rope.byteAt(self.root.?, offset)) catch unreachable;
        return offset + length;
    }
    pub fn previousGraphemeBoundary(self: Snapshot, offset: usize) !usize {
        return grapheme.previous(self.root, offset);
    }
    pub fn nextGraphemeBoundary(self: Snapshot, offset: usize) !usize {
        return grapheme.next(self.root, offset);
    }
    /// Selects one grapheme in the requested direction, or the full grapheme
    /// if a code-point-indexed caller placed the caret inside one.
    pub fn graphemeDeletionRange(self: Snapshot, offset: usize, backward: bool) !types.Range {
        return grapheme.deletion(self.root, offset, backward);
    }
    /// Literal search streams chunks. Insensitive search folds ASCII only.
    /// Scratch for long needles uses page_allocator, safe for read-only workers.
    pub fn find(self: Snapshot, needle: []const u8, from: usize, direction: types.Direction, case_sensitive: bool) !?types.Range {
        return search.find(self, needle, from, direction, case_sensitive);
    }
    pub fn debugValidate(self: Snapshot) !rope.Stats {
        std.debug.assert(self.owner == std.Thread.getCurrentId());
        return rope.validate(self.root);
    }
};
