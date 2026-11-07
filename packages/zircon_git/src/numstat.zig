//! NUL-delimited Git line counts. Paths borrow the command output until release.
const std = @import("std");
pub const LineStats = struct { added: u64 = 0, deleted: u64 = 0, binary: bool = false };
pub const Record = struct { path: []const u8, stats: LineStats };

pub fn parse(a: std.mem.Allocator, bytes: []const u8) ![]Record {
    var rows: std.ArrayList(Record) = .empty;
    errdefer rows.deinit(a);
    var offset: usize = 0;
    while (offset < bytes.len) {
        const added = try field(bytes, &offset, '\t');
        const deleted = try field(bytes, &offset, '\t');
        var path = try field(bytes, &offset, 0);
        // With -z, renamed paths occupy two following NUL-delimited fields.
        if (path.len == 0) {
            const old = try field(bytes, &offset, 0);
            if (old.len == 0) return error.InvalidGitNumstat;
            path = try field(bytes, &offset, 0);
        }
        if (path.len == 0) return error.InvalidGitNumstat;
        const binary = std.mem.eql(u8, added, "-") and std.mem.eql(u8, deleted, "-");
        try rows.append(a, .{ .path = path, .stats = if (binary) .{ .binary = true } else .{
            .added = std.fmt.parseInt(u64, added, 10) catch return error.InvalidGitNumstat,
            .deleted = std.fmt.parseInt(u64, deleted, 10) catch return error.InvalidGitNumstat,
        } });
    }
    return rows.toOwnedSlice(a);
}
fn field(bytes: []const u8, offset: *usize, delimiter: u8) ![]const u8 {
    const end = std.mem.indexOfScalarPos(u8, bytes, offset.*, delimiter) orelse return error.InvalidGitNumstat;
    const value = bytes[offset.*..end];
    offset.* = end + 1;
    return value;
}

test "numstat preserves tabs newlines rename targets and binary markers" {
    const rows = try parse(std.testing.allocator, "2\t1\t日本\tfile\n.txt\x00-\t-\timage.bin\x000\t0\t\x00old\tname\x00new\nname\x00");
    defer std.testing.allocator.free(rows);
    try std.testing.expectEqual(@as(usize, 3), rows.len);
    try std.testing.expectEqualStrings("日本\tfile\n.txt", rows[0].path);
    try std.testing.expectEqual(LineStats{ .added = 2, .deleted = 1 }, rows[0].stats);
    try std.testing.expect(rows[1].stats.binary);
    try std.testing.expectEqualStrings("new\nname", rows[2].path);
}
test "numstat rejects truncated records invalid counts and half binary markers" {
    for ([_][]const u8{ "1\t0\tfile", "1\t0\t\x00old\x00", "-\t1\tfile\x00", "18446744073709551616\t0\tf\x00" }) |bytes| {
        try std.testing.expectError(error.InvalidGitNumstat, parse(std.testing.allocator, bytes));
    }
}
