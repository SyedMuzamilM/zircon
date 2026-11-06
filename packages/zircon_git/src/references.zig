//! NUL-separated Git reference records own all borrowed strings in one arena.
const std = @import("std");
pub const Branch = struct { name: []const u8, oid: []const u8, subject: []const u8, author: []const u8, upstream: []const u8, tracking: []const u8, remote: bool };
pub const Stash = struct { reference: []const u8, oid: []const u8, subject: []const u8 };
pub const References = struct {
    arena: std.heap.ArenaAllocator,
    branches: []const Branch,
    remotes: []const []const u8,
    stashes: []const Stash,
    pub fn deinit(self: *References) void {
        self.arena.deinit();
        self.* = undefined;
    }
};
pub fn parse(a: std.mem.Allocator, branch_bytes: []const u8, remote_bytes: []const u8, stash_bytes: []const u8) !References {
    var arena = std.heap.ArenaAllocator.init(a);
    errdefer arena.deinit();
    const al = arena.allocator();
    var branches: std.ArrayList(Branch) = .empty;
    var fields = std.mem.splitScalar(u8, try al.dupe(u8, branch_bytes), 0);
    while (fields.next()) |raw| {
        const ref = std.mem.trimStart(u8, raw, "\n\r");
        if (ref.len == 0) continue;
        const oid = fields.next() orelse return error.InvalidGitReferences;
        const subject = fields.next() orelse return error.InvalidGitReferences;
        const author = fields.next() orelse return error.InvalidGitReferences;
        const upstream = fields.next() orelse return error.InvalidGitReferences;
        const tracking = fields.next() orelse return error.InvalidGitReferences;
        if (!@import("history.zig").validOid(oid)) return error.InvalidGitReferences;
        const remote = std.mem.startsWith(u8, ref, "refs/remotes/");
        if (remote and std.mem.endsWith(u8, ref, "/HEAD")) continue;
        const prefix: usize = if (remote) 13 else 11;
        if (ref.len <= prefix) return error.InvalidGitReferences;
        try branches.append(al, .{ .name = ref[prefix..], .oid = oid, .subject = subject, .author = author, .upstream = upstream, .tracking = tracking, .remote = remote });
    }
    var remotes: std.ArrayList([]const u8) = .empty;
    var remote_lines = std.mem.tokenizeAny(u8, try al.dupe(u8, remote_bytes), "\r\n");
    while (remote_lines.next()) |remote| try remotes.append(al, remote);
    var stashes: std.ArrayList(Stash) = .empty;
    fields = std.mem.splitScalar(u8, try al.dupe(u8, stash_bytes), 0);
    while (fields.next()) |raw| {
        const ref = std.mem.trimStart(u8, raw, "\r\n");
        if (ref.len == 0) continue;
        const oid = fields.next() orelse return error.InvalidGitReferences;
        const subject = fields.next() orelse return error.InvalidGitReferences;
        if (!@import("history.zig").validOid(oid)) return error.InvalidGitReferences;
        try stashes.append(al, .{ .reference = ref, .oid = oid, .subject = subject });
    }
    return .{ .arena = arena, .branches = branches.items, .remotes = remotes.items, .stashes = stashes.items };
}
