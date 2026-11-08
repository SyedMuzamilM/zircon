//! Stable Git list rows, independent of layout. Paths borrow the installed
//! status snapshot; only collapsed directory identities own persistent bytes.
const std = @import("std");
const git = @import("zircon_git");
pub const Mode = enum { tree, list };
pub const Group = enum { conflicts, tracked, untracked };
pub const Row = union(enum) {
    section: struct { group: Group, count: usize },
    directory: struct { path: []const u8, label: []const u8, depth: usize, entry: u32, group: Group },
    file: struct { index: u32, depth: usize },
};
pub const Tree = struct {
    mode: Mode = .tree,
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
                    var group_indices: std.ArrayList(u32) = .empty;
                    defer group_indices.deinit(a);
                    for (indices) |index| if (groupFor(entries[index]) == group) try group_indices.append(a, index);
                    if (self.mode == .list) {
                        for (group_indices.items) |index| try result.append(a, .{ .file = .{ .index = index, .depth = 0 } });
                    } else try self.appendDirectory(a, &result, entries, group_indices.items, group, 0, 0);
                }
            }
        }
        return result.toOwnedSlice(a);
    }

    fn appendDirectory(self: *const Tree, a: std.mem.Allocator, result: *std.ArrayList(Row), entries: []const git.Entry, indices: []const u32, group: Group, prefix: usize, depth: usize) !void {
        var index: usize = 0;
        while (index < indices.len) {
            const entry = indices[index];
            const path = entries[entry].path;
            const slash = std.mem.indexOfScalarPos(u8, path, prefix, '/') orelse {
                try result.append(a, .{ .file = .{ .index = entry, .depth = depth } });
                index += 1;
                continue;
            };
            var end = index + 1;
            while (end < indices.len and std.mem.startsWith(u8, entries[indices[end]].path, path[0 .. slash + 1])) : (end += 1) {}
            // Shared directory prefixes represent chains with no file or sibling
            // at intermediate levels, so they can occupy a single disclosure row.
            var common = std.mem.lastIndexOfScalar(u8, path, '/').?;
            for (indices[index + 1 .. end]) |other| {
                const other_path = entries[other].path;
                while (!std.mem.startsWith(u8, other_path, path[0 .. common + 1])) {
                    common = std.mem.lastIndexOfScalar(u8, path[0..common], '/').?;
                }
            }
            var compact_end = slash;
            while (compact_end < common and !self.directories.contains(path[0..compact_end])) {
                compact_end = std.mem.indexOfScalarPos(u8, path, compact_end + 1, '/').?;
            }
            const directory = path[0..compact_end];
            try result.append(a, .{ .directory = .{ .path = directory, .label = path[prefix..compact_end], .depth = depth, .entry = entry, .group = group } });
            if (!self.directories.contains(directory)) try self.appendDirectory(a, result, entries, indices[index..end], group, compact_end + 1, depth + 1);
            index = end;
        }
    }
};
pub fn groupFor(entry: git.Entry) Group {
    return if (entry.conflicted) .conflicts else if (entry.index == .untracked or entry.worktree == .untracked) .untracked else .tracked;
}
