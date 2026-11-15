const std = @import("std");
const text = @import("zircon_text");
pub fn cells(bytes: []const u8, tabs: usize) usize {
    var count: usize = 0;
    for (bytes) |byte| {
        if (byte == ' ') count += 1 else if (byte == '\t') count += tabs - count % tabs else break;
    }
    return count;
}

pub fn blank(bytes: []const u8) bool {
    return std.mem.trim(u8, bytes, " \t\r").len == 0;
}

pub fn between(before: []const u8, after: []const u8, tabs: usize) usize {
    const next = std.mem.trimStart(u8, after, " \t");
    const closing = next.len > 0 and std.mem.indexOfScalar(u8, "}])", next[0]) != null;
    return @min(cells(before, tabs), cells(after, tabs) + if (closing) tabs else @as(usize, 0));
}

/// Look through blank rows without letting an unbounded whitespace file turn
/// one visible row into a whole-document scan.
pub fn blankCells(snapshot: text.Snapshot, row: usize, tabs: usize, a: std.mem.Allocator) !usize {
    var before: ?[]const u8 = null;
    var after: ?[]const u8 = null;
    var budget: usize = 64 * 1024;
    for (0..1024) |distance| {
        if (before == null and row > distance) {
            const range = try snapshot.lineRange(row - distance - 1);
            if (range.end - range.start > budget) break;
            budget -= range.end - range.start;
            const bytes = try snapshot.copy(a, range);
            if (!blank(bytes)) before = bytes;
        }
        if (after == null and row + distance + 1 < snapshot.lineCount()) {
            const range = try snapshot.lineRange(row + distance + 1);
            if (range.end - range.start > budget) break;
            budget -= range.end - range.start;
            const bytes = try snapshot.copy(a, range);
            if (!blank(bytes)) after = bytes;
        }
        if (before != null and after != null) return between(before.?, after.?, tabs);
        if (row <= distance and row + distance + 1 >= snapshot.lineCount()) break;
    }
    return 0;
}
