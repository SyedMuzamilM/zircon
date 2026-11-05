//! One-directory-at-a-time navigation. Entries own their copied names and paths;
//! expanding a directory does not recursively walk the project.
const std = @import("std");
pub const Entry = struct {
    name: []u8,
    path: []u8,
    kind: enum { file, directory },
    pub fn deinit(entry: *Entry, a: std.mem.Allocator) void {
        a.free(entry.name);
        a.free(entry.path);
        entry.* = undefined;
    }
};
pub fn children(a: std.mem.Allocator, io: std.Io, directory: []const u8) ![]Entry {
    const dir = try std.Io.Dir.cwd().openDir(io, directory, .{ .iterate = true });
    defer dir.close(io);
    var result: std.ArrayList(Entry) = .empty;
    errdefer {
        for (result.items) |*entry| entry.deinit(a);
        result.deinit(a);
    }
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (ignored(entry.name)) continue;
        const joined = try std.fs.path.join(a, &.{ directory, entry.name });
        errdefer a.free(joined);
        var kind = entry.kind;
        if (kind == .sym_link or kind == .unknown) {
            const stat = dir.statFile(io, entry.name, .{}) catch {
                a.free(joined);
                continue;
            };
            kind = stat.kind;
        }
        if (kind != .directory and kind != .file) {
            a.free(joined);
            continue;
        }
        const name = try a.dupe(u8, entry.name);
        errdefer a.free(name);
        try result.append(a, .{ .name = name, .path = joined, .kind = if (kind == .directory) .directory else .file });
    }
    std.mem.sort(Entry, result.items, {}, less);
    return result.toOwnedSlice(a);
}
pub fn deinitEntries(entries: []Entry, a: std.mem.Allocator) void {
    for (entries) |*entry| entry.deinit(a);
    a.free(entries);
}
fn ignored(name: []const u8) bool {
    for ([_][]const u8{ ".git", ".zig-cache", ".tools", "zig-out", "node_modules", ".DS_Store" }) |excluded| if (std.mem.eql(u8, name, excluded)) return true;
    return false;
}
fn less(_: void, a: Entry, b: Entry) bool {
    if (a.kind != b.kind) return a.kind == .directory;
    return std.ascii.orderIgnoreCase(a.name, b.name) == .lt;
}
