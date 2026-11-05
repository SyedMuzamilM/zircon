//! Streaming KMP literal search, including matches crossing rope leaf edges.
//! Case-insensitive matching explicitly uses ASCII folding, not Unicode folding.
const std = @import("std");
const types = @import("types.zig");
fn fold(byte: u8, sensitive: bool) u8 {
    return if (sensitive) byte else std.ascii.toLower(byte);
}
pub fn find(snapshot: anytype, needle: []const u8, from: usize, direction: types.Direction, sensitive: bool) !?types.Range {
    if (!snapshot.isBoundary(from)) return error.InvalidOffset;
    if (!std.unicode.utf8ValidateSlice(needle)) return error.InvalidUtf8;
    if (needle.len == 0) return null;
    var local: [256]usize = undefined;
    const table = if (needle.len <= local.len) local[0..needle.len] else try std.heap.page_allocator.alloc(usize, needle.len);
    defer if (needle.len > local.len) std.heap.page_allocator.free(table);
    table[0] = 0;
    var matched: usize = 0;
    for (1..needle.len) |i| {
        const byte = fold(needle[i], sensitive);
        while (matched > 0 and byte != fold(needle[matched], sensitive)) matched = table[matched - 1];
        if (byte == fold(needle[matched], sensitive)) matched += 1;
        table[i] = matched;
    }
    const start = if (direction == .forward) from else 0;
    const end = if (direction == .forward) snapshot.byteLen() else from;
    var iterator = try snapshot.chunks(.{ .start = start, .end = end });
    var absolute = start;
    matched = 0;
    var last: ?types.Range = null;
    while (iterator.next()) |part| for (part) |original| {
        const byte = fold(original, sensitive);
        while (matched > 0 and byte != fold(needle[matched], sensitive)) matched = table[matched - 1];
        if (byte == fold(needle[matched], sensitive)) matched += 1;
        absolute += 1;
        if (matched == needle.len) {
            const range: types.Range = .{ .start = absolute - needle.len, .end = absolute };
            if (direction == .forward) return range;
            last = range;
            matched = table[matched - 1];
        }
    };
    return last;
}
