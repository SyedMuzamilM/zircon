//! Merges neighboring context blocks while retaining exact source byte ranges.
const std = @import("std");
const text = @import("zircon_text");
const types = @import("types.zig");
pub fn build(a: std.mem.Allocator, snapshot: text.Snapshot, matches: []const types.Match, context: usize, cancel: types.Cancellation) ![]const types.Excerpt {
    var result: std.ArrayList(types.Excerpt) = .empty;
    var first: usize = 0;
    while (first < matches.len) {
        try cancel.check();
        const begin = matches[first].line -| context;
        var end = try endLine(snapshot, matches[first], context);
        var last = first + 1;
        while (last < matches.len and matches[last].line -| context <= end) : (last += 1) end = @max(end, try endLine(snapshot, matches[last], context));
        const range: text.Range = .{ .start = try snapshot.lineStart(begin), .end = if (end == snapshot.lineCount()) snapshot.byteLen() else try snapshot.lineStart(end) };
        const ranges = try a.alloc(text.Range, last - first);
        for (matches[first..last], 0..) |match, i| ranges[i] = .{ .start = match.range.start - range.start, .end = match.range.end - range.start };
        try result.append(a, .{ .start_line = begin, .end_line = end, .source_range = range, .bytes = try snapshot.copy(a, range), .match_ranges = ranges });
        first = last;
    }
    return result.items;
}
fn endLine(snapshot: text.Snapshot, match: types.Match, context: usize) !usize {
    const last = if (match.range.end > match.range.start) try snapshot.previousBoundary(match.range.end) else match.range.end;
    return @min(snapshot.lineCount(), (try snapshot.pointAt(last)).line +| 1 +| context);
}
