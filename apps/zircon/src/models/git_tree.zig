//! Stable Git list rows, independent of layout. Paths borrow the installed
//! status snapshot; only collapsed directory identities own persistent bytes.
const std = @import("std");
const git = @import("zircon_git");
pub const Group = enum { conflicts, tracked, untracked };
pub const Row = union(enum) {
    section: struct { group: Group, count: usize },
    directory: struct { path: []const u8, depth: usize, entry: u32, group: Group },
    file: struct { index: u32, depth: usize },
};
pub const Tree = struct {
    sections: [3]bool = @splat(false),
    directories: std.StringHashMapUnmanaged(void) = .empty,
    pub fn deinit(self: *Tree, a: std.mem.Allocator) void {
        var keys = self.directories.keyIterator();
        while (keys.next()) |key| a.free(key.*);
        self.directories.deinit(a);
    }
    pub fn toggleDirectory(self: *Tree, a: std.mem.Allocator, path: []const u8) !void {
        if (self.directories.fetchRemove(path)) |entry| {
            a.free(entry.key);
        } else {
            const owned = try a.dupe(u8, path);
            errdefer a.free(owned);
            try self.directories.put(a, owned, {});
        }
    }
    pub fn rows(self: *const Tree, a: std.mem.Allocator, entries: []const git.Entry) ![]Row {
        const indices = try a.alloc(u32, entries.len);
        defer a.free(indices);
        for (indices, 0..) |*value, index| value.* = @intCast(index);
        std.mem.sort(u32, indices, entries, struct {
            fn less(items: []const git.Entry, lhs: u32, rhs: u32) bool {
                return std.mem.order(u8, items[lhs].path, items[rhs].path) == .lt;
            }
        }.less);
        var result: std.ArrayList(Row) = .empty;
        errdefer result.deinit(a);
        inline for (std.meta.tags(Group)) |group| {
            var count: usize = 0;
            for (entries) |entry| if (groupFor(entry) == group) {
                count += 1;
            };
            if (count > 0) {
                try result.append(a, .{ .section = .{ .group = group, .count = count } });
                if (!self.sections[@backingInt(group)]) {
                    var previous: []const u8 = "";
                    for (indices) |index| {
                        const entry = entries[index];
                        if (groupFor(entry) != group) continue;
                        var depth: usize = 0;
                        var hidden = false;
                        for (entry.path, 0..) |char, end| {
                            if (char != '/') continue;
                            const directory = entry.path[0..end];
                            if (!(previous.len > end and previous[end] == '/' and std.mem.eql(u8, previous[0..end], directory))) try result.append(a, .{ .directory = .{ .path = directory, .depth = depth, .entry = index, .group = group } });
                            depth += 1;
                            if (self.directories.contains(directory)) {
                                hidden = true;
                                break;
                            }
                        }
                        if (!hidden) try result.append(a, .{ .file = .{ .index = index, .depth = depth } });
                        previous = entry.path;
                    }
                }
            }
        }
        return result.toOwnedSlice(a);
    }
};
pub fn groupFor(entry: git.Entry) Group {
    return if (entry.conflicted) .conflicts else if (entry.index == .untracked or entry.worktree == .untracked) .untracked else .tracked;
}
