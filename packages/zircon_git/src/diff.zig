//! Unified patch parsing and bounded line diff for unsaved-buffer gutters.
const std = @import("std");
pub const Line = struct { kind: enum { context, addition, deletion, metadata }, text: []const u8, old_line: ?usize = null, new_line: ?usize = null };
pub const OriginalRange = struct { old_start: usize, old_count: usize, new_start: usize, new_count: usize };
pub const Hunk = struct { old_start: usize, old_count: usize, new_start: usize, new_count: usize, header: []const u8, lines: []const Line, path: []const u8 = "", original: ?OriginalRange = null };
pub const ContextSource = struct { path: []const u8, bytes: []const u8, lines: []const []const u8 };
pub const Diff = struct {
    arena: std.heap.ArenaAllocator,
    text: []const u8,
    hunks: []const Hunk,
    context_sources: []ContextSource = &.{},
    pub fn deinit(self: *Diff) void {
        self.arena.deinit();
        self.* = undefined;
    }
};
pub fn parse(a: std.mem.Allocator, bytes: []const u8) !Diff {
    var arena = std.heap.ArenaAllocator.init(a);
    errdefer arena.deinit();
    const owned = try arena.allocator().dupe(u8, bytes);
    const al = arena.allocator();
    var hunks: std.ArrayList(Hunk) = .empty;
    var lines: std.ArrayList(Line) = .empty;
    var current: ?Hunk = null;
    var old: usize = 0;
    var new: usize = 0;
    var path: []const u8 = "";
    var iterator = std.mem.splitScalar(u8, owned, '\n');
    while (iterator.next()) |line| {
        if (current == null and std.mem.startsWith(u8, line, "Binary files ")) {
            const rest = line[13..];
            const separator = std.mem.indexOf(u8, rest, " and ") orelse return error.InvalidGitDiff;
            const target_start = separator + 5;
            const target_end = std.mem.indexOfPos(u8, rest, target_start, " differ") orelse return error.InvalidGitDiff;
            const binary_path = try decodePath(al, rest[target_start..target_end]);
            path = if (std.mem.startsWith(u8, binary_path, "b/")) binary_path[2..] else binary_path;
            const binary_lines = try al.alloc(Line, 1);
            binary_lines[0] = .{ .kind = .metadata, .text = line };
            try hunks.append(al, .{ .old_start = 0, .old_count = 0, .new_start = 0, .new_count = 0, .header = line, .lines = binary_lines, .path = path });
        } else if (std.mem.startsWith(u8, line, "@@ -")) {
            if (current) |*h| {
                h.lines = lines.items;
                try hunks.append(al, h.*);
                lines = .empty;
            }
            var fields = std.mem.tokenizeScalar(u8, line, ' ');
            _ = fields.next();
            const previous = try range(fields.next() orelse return error.InvalidGitDiff);
            const next = try range(fields.next() orelse return error.InvalidGitDiff);
            current = .{ .old_start = previous.start, .old_count = previous.count, .new_start = next.start, .new_count = next.count, .header = line, .lines = &.{}, .path = path };
            old = previous.start;
            new = next.start;
        } else if (std.mem.startsWith(u8, line, "diff --git ")) {
            if (current) |*h| {
                h.lines = lines.items;
                try hunks.append(al, h.*);
                current = null;
                lines = .empty;
            }
            path = "";
        } else if (current == null and (std.mem.startsWith(u8, line, "--- ") or std.mem.startsWith(u8, line, "+++ "))) {
            const name = try decodePath(al, line[4..]);
            if (!std.mem.eql(u8, name, "/dev/null")) path = if (std.mem.startsWith(u8, name, "a/") or std.mem.startsWith(u8, name, "b/")) name[2..] else name;
        } else if (current != null and line.len > 0) {
            const item: Line = switch (line[0]) {
                ' ' => blk: {
                    const l: Line = .{ .kind = .context, .text = line[1..], .old_line = old, .new_line = new };
                    old += 1;
                    new += 1;
                    break :blk l;
                },
                '+' => blk: {
                    const l: Line = .{ .kind = .addition, .text = line[1..], .new_line = new };
                    new += 1;
                    break :blk l;
                },
                '-' => blk: {
                    const l: Line = .{ .kind = .deletion, .text = line[1..], .old_line = old };
                    old += 1;
                    break :blk l;
                },
                else => .{ .kind = .metadata, .text = line },
            };
            try lines.append(al, item);
        }
    }
    if (current) |*h| {
        h.lines = lines.items;
        try hunks.append(al, h.*);
    }
    return .{ .arena = arena, .text = owned, .hunks = hunks.items };
}

fn decodePath(a: std.mem.Allocator, raw: []const u8) ![]const u8 {
    const name = if (raw.len >= 2 and raw[0] == '"' and raw[raw.len - 1] == '"') raw[1 .. raw.len - 1] else raw[0 .. std.mem.indexOfScalar(u8, raw, '\t') orelse raw.len];
    var decoded: std.ArrayList(u8) = .empty;
    errdefer decoded.deinit(a);
    var i: usize = 0;
    while (i < name.len) : (i += 1) {
        if (name[i] != '\\' or i + 1 >= name.len) {
            try decoded.append(a, name[i]);
            continue;
        }
        i += 1;
        const byte = switch (name[i]) {
            'a' => 0x07,
            'b' => 0x08,
            'f' => 0x0c,
            'n' => 0x0a,
            'r' => 0x0d,
            't' => 0x09,
            'v' => 0x0b,
            '\\' => '\\',
            '"' => '"',
            else => if (name[i] >= '0' and name[i] <= '7') blk: {
                var value: u8 = name[i] - '0';
                var count: usize = 1;
                while (count < 3 and i + 1 < name.len and name[i + 1] >= '0' and name[i + 1] <= '7') : (count += 1) {
                    i += 1;
                    value = value * 8 + name[i] - '0';
                }
                break :blk value;
            } else name[i],
        };
        try decoded.append(a, byte);
    }
    return decoded.toOwnedSlice(a);
}
fn range(value: []const u8) !struct { start: usize, count: usize } {
    if (value.len < 2 or (value[0] != '-' and value[0] != '+')) return error.InvalidGitDiff;
    var it = std.mem.splitScalar(u8, value[1..], ',');
    const start = std.fmt.parseInt(usize, it.next().?, 10) catch return error.InvalidGitDiff;
    const count = if (it.next()) |n| std.fmt.parseInt(usize, n, 10) catch return error.InvalidGitDiff else 1;
    return .{ .start = start, .count = count };
}
pub const LineChange = struct { kind: enum { added, modified, deleted }, start: usize, end: usize, old_start: usize, old_end: usize };
/// Half-open zero-based row ranges. A deletion attaches to start, possibly EOF.
/// LCS work is bounded at 2M cells after equal prefix/suffix trimming; larger
/// ambiguous blocks conservatively become one modified range rather than
/// freezing the UI or allocating quadratic memory.
pub fn diffLines(a: std.mem.Allocator, base: []const u8, current: []const u8) ![]LineChange {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const al = arena.allocator();
    const before = try split(al, base);
    const after = try split(al, current);
    var prefix: usize = 0;
    while (prefix < before.len and prefix < after.len and std.mem.eql(u8, before[prefix], after[prefix])) : (prefix += 1) {}
    var m = before.len;
    var n = after.len;
    while (m > prefix and n > prefix and std.mem.eql(u8, before[m - 1], after[n - 1])) {
        m -= 1;
        n -= 1;
    }
    if (m == prefix and n == prefix) return a.alloc(LineChange, 0);
    const rows = m - prefix;
    const cols = n - prefix;
    var changes: std.ArrayList(LineChange) = .empty;
    errdefer changes.deinit(a);
    const cells = std.math.mul(usize, rows + 1, cols + 1) catch std.math.maxInt(usize);
    if (cells > 2_000_000) {
        try changes.append(a, make(prefix, n, prefix, m));
        return changes.toOwnedSlice(a);
    }
    const table = try al.alloc(u32, cells);
    @memset(table, 0);
    var i = rows;
    while (i > 0) {
        i -= 1;
        var j = cols;
        while (j > 0) {
            j -= 1;
            table[i * (cols + 1) + j] = if (std.mem.eql(u8, before[prefix + i], after[prefix + j])) 1 + table[(i + 1) * (cols + 1) + j + 1] else @max(table[(i + 1) * (cols + 1) + j], table[i * (cols + 1) + j + 1]);
        }
    }
    i = 0;
    var j: usize = 0;
    var begin: ?struct { old: usize, new: usize } = null;
    while (i < rows or j < cols) {
        if (i < rows and j < cols and std.mem.eql(u8, before[prefix + i], after[prefix + j])) {
            if (begin) |b| {
                try changes.append(a, make(prefix + b.new, prefix + j, prefix + b.old, prefix + i));
                begin = null;
            }
            i += 1;
            j += 1;
        } else {
            if (begin == null) begin = .{ .old = i, .new = j };
            if (j < cols and (i == rows or table[i * (cols + 1) + j + 1] >= table[(i + 1) * (cols + 1) + j])) j += 1 else i += 1;
        }
    }
    if (begin) |b| try changes.append(a, make(prefix + b.new, prefix + j, prefix + b.old, prefix + i));
    return changes.toOwnedSlice(a);
}
fn make(start: usize, end: usize, old_start: usize, old_end: usize) LineChange {
    return .{ .kind = if (start == end) .deleted else if (old_start == old_end) .added else .modified, .start = start, .end = end, .old_start = old_start, .old_end = old_end };
}
fn split(a: std.mem.Allocator, bytes: []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var begin: usize = 0;
    for (bytes, 0..) |byte, i| if (byte == '\n') {
        try list.append(a, bytes[begin .. i + 1]);
        begin = i + 1;
    };
    if (begin < bytes.len) try list.append(a, bytes[begin..]);
    return list.items;
}
