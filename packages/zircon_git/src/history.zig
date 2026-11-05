//! Machine-formatted log and line-porcelain blame, with explicitly owned data.
const std = @import("std");
pub const Commit = struct {
    oid: []u8,
    author: []u8,
    email: []u8,
    timestamp: i64,
    subject: []u8,
    pub fn deinit(self: *Commit, a: std.mem.Allocator) void {
        a.free(self.oid);
        a.free(self.author);
        a.free(self.email);
        a.free(self.subject);
        self.* = undefined;
    }
};
pub fn deinitHistory(a: std.mem.Allocator, commits: []Commit) void {
    for (commits) |*commit| commit.deinit(a);
    a.free(commits);
}
pub fn parse(a: std.mem.Allocator, bytes: []const u8) ![]Commit {
    var list: std.ArrayList(Commit) = .empty;
    errdefer {
        for (list.items) |*commit| commit.deinit(a);
        list.deinit(a);
    }
    var fields = std.mem.splitScalar(u8, bytes, 0);
    while (fields.next()) |raw_oid| {
        const oid = std.mem.trimStart(u8, raw_oid, "\r\n");
        if (oid.len == 0) continue;
        if (!validOid(oid)) return error.InvalidGitHistory;
        const author = fields.next() orelse return error.InvalidGitHistory;
        const email = fields.next() orelse return error.InvalidGitHistory;
        const timestamp = fields.next() orelse return error.InvalidGitHistory;
        const subject = fields.next() orelse return error.InvalidGitHistory;
        const time = std.fmt.parseInt(i64, timestamp, 10) catch return error.InvalidGitHistory;
        var entry: Commit = .{ .oid = try a.dupe(u8, oid), .author = &.{}, .email = &.{}, .timestamp = time, .subject = &.{} };
        errdefer entry.deinit(a);
        entry.author = try a.dupe(u8, author);
        entry.email = try a.dupe(u8, email);
        entry.subject = try a.dupe(u8, subject);
        try list.append(a, entry);
    }
    return list.toOwnedSlice(a);
}
pub fn validOid(oid: []const u8) bool {
    if (oid.len != 40 and oid.len != 64) return false;
    for (oid) |byte| if (!std.ascii.isHex(byte)) return false;
    return true;
}
pub const Blame = struct {
    arena: std.heap.ArenaAllocator,
    oid: []const u8,
    author: []const u8,
    email: []const u8,
    summary: []const u8,
    timestamp: i64 = 0,
    line: usize,
    original_line: usize,
    contents: []const u8,
    uncommitted: bool,
    pub fn deinit(self: *Blame) void {
        self.arena.deinit();
        self.* = undefined;
    }
};
pub fn parseBlame(a: std.mem.Allocator, bytes: []const u8) !Blame {
    var arena = std.heap.ArenaAllocator.init(a);
    errdefer arena.deinit();
    const owned = try arena.allocator().dupe(u8, bytes);
    var rows = std.mem.splitScalar(u8, owned, '\n');
    const header = rows.next() orelse return error.InvalidGitBlame;
    var fields = std.mem.tokenizeScalar(u8, header, ' ');
    const oid = fields.next() orelse return error.InvalidGitBlame;
    if (!validOid(oid)) return error.InvalidGitBlame;
    const original = std.fmt.parseInt(usize, fields.next() orelse return error.InvalidGitBlame, 10) catch return error.InvalidGitBlame;
    const line = std.fmt.parseInt(usize, fields.next() orelse return error.InvalidGitBlame, 10) catch return error.InvalidGitBlame;
    var author: []const u8 = "";
    var email: []const u8 = "";
    var summary: []const u8 = "";
    var timestamp: i64 = 0;
    var contents: []const u8 = "";
    while (rows.next()) |row| {
        if (std.mem.startsWith(u8, row, "author ")) author = row[7..] else if (std.mem.startsWith(u8, row, "author-mail ")) email = std.mem.trim(u8, row[12..], "<>") else if (std.mem.startsWith(u8, row, "author-time ")) timestamp = std.fmt.parseInt(i64, row[12..], 10) catch return error.InvalidGitBlame else if (std.mem.startsWith(u8, row, "summary ")) summary = row[8..] else if (row.len > 0 and row[0] == '\t') {
            contents = row[1..];
            break;
        }
    }
    var uncommitted = true;
    for (oid) |byte| if (byte != '0') {
        uncommitted = false;
        break;
    };
    return .{ .arena = arena, .oid = oid, .author = author, .email = email, .summary = summary, .timestamp = timestamp, .line = line, .original_line = original, .contents = contents, .uncommitted = uncommitted };
}
