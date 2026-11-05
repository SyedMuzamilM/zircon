//! Stable bounded disk reads. A result records metadata plus a content hash so
//! activating an old match can refuse offsets after another writer changes it.
const std = @import("std");
const types = @import("types.zig");
pub const Loaded = struct { bytes: []u8, stamp: types.DiskStamp };
pub fn read(a: std.mem.Allocator, io: std.Io, path: []const u8, limit: usize, cancel: types.Cancellation) !Loaded {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const before = try file.stat(io);
    if (before.kind != .file) return error.NotRegularFile;
    if (before.size > limit) return error.FileTooLarge;
    const bytes = try a.alloc(u8, @intCast(before.size));
    errdefer a.free(bytes);
    var at: usize = 0;
    while (at < bytes.len) {
        try cancel.check();
        const count = @min(32 * 1024, bytes.len - at);
        if (try file.readPositionalAll(io, bytes[at..][0..count], at) != count) return error.DiskChanged;
        at += count;
    }
    const after = try file.stat(io);
    const at_path = try std.Io.Dir.cwd().statFile(io, path, .{});
    if (!same(before, after) or !same(after, at_path)) return error.DiskChanged;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return .{ .bytes = bytes, .stamp = .{ .inode = after.inode, .size = after.size, .modified = after.mtime.nanoseconds, .fingerprint = digest } };
}
pub fn isCurrent(io: std.Io, path: []const u8, stamp: types.DiskStamp) !bool {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer file.close(io);
    const before = try file.stat(io);
    if (before.kind != .file or before.inode != stamp.inode or before.size != stamp.size or before.mtime.nanoseconds != stamp.modified) return false;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [32 * 1024]u8 = undefined;
    var offset: u64 = 0;
    while (offset < before.size) {
        const count: usize = @intCast(@min(buffer.len, before.size - offset));
        if (try file.readPositionalAll(io, buffer[0..count], offset) != count) return false;
        hasher.update(buffer[0..count]);
        offset += count;
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const after = try file.stat(io);
    const at_path = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return same(before, after) and same(after, at_path) and std.mem.eql(u8, &digest, &stamp.fingerprint);
}
fn same(a: std.Io.File.Stat, b: std.Io.File.Stat) bool {
    return a.kind == b.kind and a.inode == b.inode and a.size == b.size and a.mtime.nanoseconds == b.mtime.nanoseconds and a.ctime.nanoseconds == b.ctime.nanoseconds;
}
pub fn canonical(a: std.mem.Allocator, io: std.Io, cwd: []const u8, path: []const u8) ![]u8 {
    if (path.len == 0 or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;
    const result = std.Io.Dir.cwd().realPathFileAlloc(io, path, a) catch |err| switch (err) {
        error.FileNotFound => return std.fs.path.resolve(a, &.{ cwd, path }),
        else => return err,
    };
    defer a.free(result);
    return a.dupe(u8, result);
}
