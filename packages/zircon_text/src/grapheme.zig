//! Extended grapheme boundaries, Unicode 17.0 (UAX #29).
const std = @import("std");
const data = @import("grapheme_data.zig");
const rope = @import("rope.zig");
const types = @import("types.zig");
const Range = types.Range;

const Class = enum(u4) {
    other,
    cr,
    lf,
    control,
    extend,
    zwj,
    regional_indicator,
    prepend,
    spacing_mark,
    l,
    v,
    t,
    lv,
    lvt,
};
const Indic = enum(u2) { none, consonant, extend, linker };
const Properties = struct {
    class: Class = .other,
    pictographic: bool = false,
    indic: Indic = .none,
};

fn properties(point: u21) Properties {
    if (point < 128) return .{ .class = switch (point) {
        '\r' => .cr,
        '\n' => .lf,
        0...9, 11, 12, 14...31, 127 => .control,
        else => .other,
    } };
    if (point >= 0xac00 and point <= 0xd7a3) {
        return .{ .class = if ((point - 0xac00) % 28 == 0) .lv else .lvt };
    }
    var first: usize = 0;
    var last: usize = data.ranges.len;
    while (first < last) {
        const middle = first + (last - first) / 2;
        const entry = data.ranges[middle];
        if (point < entry.first) {
            last = middle;
        } else if (point > entry.last) {
            first = middle + 1;
        } else {
            return .{
                .class = @fromBackingInt(@intCast(entry.bits & 0xf)),
                .pictographic = entry.bits & 0x10 != 0,
                .indic = @fromBackingInt(@intCast(entry.bits >> 5)),
            };
        }
    }
    return .{};
}

const CodePoint = struct { start: usize, end: usize, value: Properties };
const Reader = struct {
    root: *const rope.Node,
    bytes: []const u8 = &.{},
    base: usize = 0,

    fn seek(self: *Reader, offset: usize) usize {
        if (offset < self.base or offset - self.base >= self.bytes.len) {
            const leaf = rope.leafAt(self.root, offset);
            self.bytes = leaf.bytes;
            self.base = leaf.start;
        }
        return offset - self.base;
    }

    fn init(root: *const rope.Node, offset: usize) !Reader {
        var reader: Reader = .{ .root = root };
        if (offset > root.summary.bytes) return error.InvalidOffset;
        if (offset < root.summary.bytes) {
            const local = reader.seek(offset);
            if (reader.bytes[local] & 0xc0 == 0x80) return error.InvalidOffset;
        }
        return reader;
    }

    fn after(self: *Reader, offset: usize) CodePoint {
        const at = self.seek(offset);
        const length = std.unicode.utf8ByteSequenceLength(self.bytes[at]) catch unreachable;
        const point = if (length == 1) self.bytes[at] else std.unicode.utf8Decode(self.bytes[at..][0..length]) catch unreachable;
        return .{ .start = offset, .end = offset + length, .value = properties(point) };
    }

    fn before(self: *Reader, offset: usize) CodePoint {
        const last = self.seek(offset - 1);
        var start = last;
        while (self.bytes[start] & 0xc0 == 0x80) start -= 1;
        const point = if (start == last) self.bytes[start] else std.unicode.utf8Decode(self.bytes[start .. last + 1]) catch unreachable;
        return .{ .start = self.base + start, .end = offset, .value = properties(point) };
    }

    fn boundary(self: *Reader, left: CodePoint, right: CodePoint) bool {
        const a = left.value.class;
        const b = right.value.class;
        if (a == .cr and b == .lf) return false;
        if (isControl(a) or isControl(b)) return true;
        if (a == .l and (b == .l or b == .v or b == .lv or b == .lvt)) return false;
        if ((a == .lv or a == .v) and (b == .v or b == .t)) return false;
        if ((a == .lvt or a == .t) and b == .t) return false;
        if (b == .extend or b == .zwj or b == .spacing_mark or a == .prepend) return false;
        if (right.value.indic == .consonant and self.indicConjunct(left)) return false;
        if (right.value.pictographic and a == .zwj and self.emojiPrefix(left.start)) return false;
        if (a == .regional_indicator and b == .regional_indicator) {
            var odd = true;
            var start = left.start;
            while (start != 0) {
                const preceding = self.before(start);
                if (preceding.value.class != .regional_indicator) break;
                odd = !odd;
                start = preceding.start;
            }
            return !odd;
        }
        return true;
    }

    fn indicConjunct(self: *Reader, left: CodePoint) bool {
        var point = left;
        var has_linker = false;
        while (true) {
            switch (point.value.indic) {
                .consonant => return has_linker,
                .none => return false,
                .linker => has_linker = true,
                .extend => {},
            }
            if (point.start == 0) return false;
            point = self.before(point.start);
        }
    }

    fn emojiPrefix(self: *Reader, offset: usize) bool {
        var at = offset;
        while (at != 0) {
            const preceding = self.before(at);
            if (preceding.value.class != .extend) return preceding.value.pictographic;
            at = preceding.start;
        }
        return false;
    }

    fn startOfCluster(self: *Reader, point: CodePoint) usize {
        var right = point;
        while (right.start > 0) {
            const left = self.before(right.start);
            if (self.boundary(left, right)) break;
            right = left;
        }
        return right.start;
    }

    fn endOfCluster(self: *Reader, point: CodePoint) usize {
        var left = point;
        while (left.end < self.root.summary.bytes) {
            const right = self.after(left.end);
            if (self.boundary(left, right)) break;
            left = right;
        }
        return left.end;
    }
};

fn isControl(class: Class) bool {
    return class == .cr or class == .lf or class == .control;
}

pub fn previous(root: ?*const rope.Node, offset: usize) !usize {
    if (offset == 0) return 0;
    var reader = try Reader.init(root orelse return error.InvalidOffset, offset);
    return reader.startOfCluster(reader.before(offset));
}

pub fn next(root: ?*const rope.Node, offset: usize) !usize {
    if (offset == rope.summary(root).bytes) return offset;
    var reader = try Reader.init(root orelse return error.InvalidOffset, offset);
    return reader.endOfCluster(reader.after(offset));
}

pub fn deletion(root: ?*const rope.Node, offset: usize, backward: bool) !Range {
    const len = rope.summary(root).bytes;
    if ((offset == 0 and backward) or (offset == len and !backward)) return .{ .start = offset, .end = offset };
    var reader = try Reader.init(root orelse return error.InvalidOffset, offset);
    const left = if (offset != 0) reader.before(offset) else null;
    const right = if (offset < len) reader.after(offset) else null;
    const inside = left != null and right != null and !reader.boundary(left.?, right.?);
    const start = if (inside or backward) reader.startOfCluster(left.?) else offset;
    const end = if (inside or !backward) reader.endOfCluster(right.?) else offset;
    return .{ .start = start, .end = end };
}
