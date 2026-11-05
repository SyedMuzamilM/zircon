//! Document-revision-bound decorations. Inline blocks participate in vertical
//! geometry instead of covering source text; input uses the same row mapping.
const std = @import("std");
pub const GitChange = struct { kind: enum { added, modified, deleted }, start: usize, end: usize };
pub const Blame = struct {
    line: usize,
    revision: u64,
    author: []const u8,
    summary: []const u8,
    oid: []const u8,
    timestamp: i64,
    pub fn copy(value: Blame, a: std.mem.Allocator) !Blame {
        const author = try a.dupe(u8, value.author);
        errdefer a.free(author);
        const summary = try a.dupe(u8, value.summary);
        errdefer a.free(summary);
        const oid = try a.dupe(u8, value.oid);
        var result = value;
        result.author = author;
        result.summary = summary;
        result.oid = oid;
        return result;
    }
    pub fn deinit(value: *Blame, a: std.mem.Allocator) void {
        a.free(value.author);
        a.free(value.summary);
        a.free(value.oid);
        value.* = undefined;
    }
};
pub const blame_height: f32 = 88;
pub fn rowY(row: usize, height: f32, blame: ?Blame) f32 {
    return @as(f32, @floatFromInt(row)) * height + if (blame != null and row > blame.?.line) blame_height else @as(f32, 0);
}
pub fn sourceRow(y: f32, height: f32, blame: ?Blame) usize {
    var position = @max(0, y);
    if (blame) |value| {
        const top = @as(f32, @floatFromInt(value.line + 1)) * height;
        if (position >= top + blame_height) position -= blame_height else if (position >= top) return value.line;
    }
    return @intFromFloat(@floor(position / height));
}
