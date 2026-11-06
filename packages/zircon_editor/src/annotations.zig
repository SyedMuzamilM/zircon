//! Document-revision-bound decorations. Inline blocks participate in vertical
//! geometry instead of covering source text; input uses the same row mapping.
const std = @import("std");
pub const GitChange = struct {
    kind: enum { added, modified, deleted },
    start: usize,
    end: usize,
    old_start: usize = 0,
    old_count: usize = 0,
    removed: []const u8 = "",
    expanded: bool = false,
};
pub fn insertedRows(changes: []const GitChange, before: usize) usize {
    var count: usize = 0;
    for (changes) |change| if (change.expanded and before >= change.start) {
        count += change.old_count;
    };
    return count;
}
pub fn changeY(change: GitChange, height: f32, changes: []const GitChange) f32 {
    return rowY(change.start, height, changes) - if (change.expanded) @as(f32, @floatFromInt(change.old_count)) * height else 0;
}
pub fn marker(change: GitChange, changes: []const GitChange, height: f32, bounds: @import("zircon_ui").Rect, scroll: f32) @import("zircon_ui").Rect {
    const rows = change.end -| change.start;
    const old_rows = if (change.expanded) change.old_count else 0;
    return .{ .x = bounds.x, .y = bounds.y + changeY(change, height, changes) - scroll - if (rows + old_rows == 0) @as(f32, 2) else 0, .width = 6, .height = if (rows + old_rows == 0) 4 else @as(f32, @floatFromInt(rows + old_rows)) * height };
}
pub const Blame = struct {
    line: usize,
    revision: u64,
    author: []const u8,
    summary: []const u8,
    oid: []const u8,
    timestamp: i64,
    email: []const u8 = "",
    message: []const u8 = "",
    uncommitted: bool = false,
    expanded: bool = true,
    pub fn copy(value: Blame, a: std.mem.Allocator) !Blame {
        const author = try a.dupe(u8, value.author);
        errdefer a.free(author);
        const summary = try a.dupe(u8, value.summary);
        errdefer a.free(summary);
        const oid = try a.dupe(u8, value.oid);
        errdefer a.free(oid);
        const email = try a.dupe(u8, value.email);
        errdefer a.free(email);
        const message = try a.dupe(u8, value.message);
        var result = value;
        result.email = email;
        result.message = message;
        result.author = author;
        result.summary = summary;
        result.oid = oid;
        return result;
    }
    pub fn deinit(value: *Blame, a: std.mem.Allocator) void {
        a.free(value.email);
        a.free(value.message);
        a.free(value.author);
        a.free(value.summary);
        a.free(value.oid);
        value.* = undefined;
    }
};
pub fn rowY(row: usize, height: f32, changes: []const GitChange) f32 {
    return @as(f32, @floatFromInt(row + insertedRows(changes, row))) * height;
}
pub fn sourceRow(y: f32, height: f32, changes: []const GitChange) usize {
    var position = @max(0, y);
    var removed: usize = 0;
    for (changes) |change| if (change.expanded) {
        const top = @as(f32, @floatFromInt(change.start + removed)) * height;
        const length = @as(f32, @floatFromInt(change.old_count)) * height;
        if (y >= top and y < top + length) return change.start;
        if (y >= top + length) position -= length;
        removed += change.old_count;
    };
    return @intFromFloat(@floor(@max(0, position) / height));
}

pub fn contains(rect: @import("zircon_ui").Rect, point: @import("zircon_ui").Point) bool {
    return point.x >= rect.x and point.x < rect.x + rect.width and point.y >= rect.y and point.y < rect.y + rect.height;
}

pub fn date(a: std.mem.Allocator, timestamp: i64) ![]const u8 {
    if (timestamp < 0 or timestamp > 253402300799) return "Date unavailable";
    const seconds: std.time.epoch.EpochSeconds = .{ .secs = @intCast(timestamp) };
    const year = seconds.getEpochDay().calculateYearDay();
    const month = year.calculateMonthDay();
    return std.fmt.allocPrint(a, "{d}-{d:0>2}-{d:0>2} UTC", .{ year.year, @backingInt(month.month), @as(u16, month.day_index) + 1 });
}

/// Shared byte range for stronger intraline highlighting. Endpoints stay on
/// UTF-8 boundaries even when equal byte prefixes stop inside a code point.
pub fn changedColumns(previous: []const u8, current: []const u8) struct { start: usize, end: usize } {
    var start: usize = 0;
    while (start < previous.len and start < current.len and previous[start] == current[start]) start += 1;
    while (start > 0 and start < current.len and current[start] & 0xc0 == 0x80) start -= 1;
    var old_end = previous.len;
    var end = current.len;
    while (old_end > start and end > start and previous[old_end - 1] == current[end - 1]) {
        old_end -= 1;
        end -= 1;
    }
    while (end < current.len and current[end] & 0xc0 == 0x80) end += 1;
    return .{ .start = start, .end = end };
}
pub fn lineAt(bytes: []const u8, row: usize) []const u8 {
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var i: usize = 0;
    while (lines.next()) |line| : (i += 1) if (i == row) return std.mem.trimEnd(u8, line, "\r");
    return "";
}
