//! Porcelain v1 -z parsing preserves arbitrary path bytes, including newlines.
const std = @import("std");
const numstat = @import("numstat.zig");
pub const Change = enum { clean, added, modified, deleted, renamed, copied, unmerged, untracked, ignored, type_changed, unknown };
pub const Entry = struct { path: []const u8, old_path: ?[]const u8 = null, index: Change, worktree: Change, staged: bool, unstaged: bool, conflicted: bool = false, stats: ?numstat.LineStats = null };
pub const Status = struct {
    arena: std.heap.ArenaAllocator,
    branch: []const u8,
    entries: []const Entry,
    unborn: bool = false,
    detached: bool = false,
    pub fn deinit(self: *Status) void {
        self.arena.deinit();
        self.* = undefined;
    }
};
pub fn parse(a: std.mem.Allocator, bytes: []const u8) !Status {
    var arena = std.heap.ArenaAllocator.init(a);
    errdefer arena.deinit();
    const owned = try arena.allocator().dupe(u8, bytes);
    var entries: std.ArrayList(Entry) = .empty;
    var tokens = std.mem.splitScalar(u8, owned, 0);
    var branch: []const u8 = "";
    var unborn = false;
    var detached = false;
    while (tokens.next()) |token| {
        if (token.len == 0) continue;
        if (std.mem.startsWith(u8, token, "## ")) {
            const header = token[3..];
            unborn = std.mem.startsWith(u8, header, "No commits yet on ") or std.mem.startsWith(u8, header, "Initial commit on ");
            detached = std.mem.startsWith(u8, header, "HEAD (");
            branch = if (std.mem.startsWith(u8, header, "No commits yet on ")) header[18..] else if (std.mem.startsWith(u8, header, "Initial commit on ")) header[18..] else if (detached) "HEAD" else header;
            if (std.mem.indexOf(u8, branch, "...")) |at| branch = branch[0..at];
            if (std.mem.indexOf(u8, branch, " [")) |at| branch = branch[0..at];
            continue;
        }
        if (token.len < 4 or token[2] != ' ') return error.InvalidGitStatus;
        const x = decode(token[0]);
        const y = decode(token[1]);
        var entry: Entry = .{ .path = token[3..], .index = x, .worktree = y, .staged = x != .clean and x != .untracked and x != .ignored, .unstaged = y != .clean or x == .untracked };
        entry.conflicted = x == .unmerged or y == .unmerged or (token[0] == 'A' and token[1] == 'A') or (token[0] == 'D' and token[1] == 'D');
        if (x == .renamed or x == .copied or y == .renamed or y == .copied) entry.old_path = tokens.next() orelse return error.InvalidGitStatus;
        try entries.append(arena.allocator(), entry);
    }
    return .{ .arena = arena, .branch = branch, .entries = entries.items, .unborn = unborn, .detached = detached };
}
fn decode(byte: u8) Change {
    return switch (byte) {
        ' ' => .clean,
        'A' => .added,
        'M' => .modified,
        'D' => .deleted,
        'R' => .renamed,
        'C' => .copied,
        'U' => .unmerged,
        '?' => .untracked,
        '!' => .ignored,
        'T' => .type_changed,
        else => .unknown,
    };
}
