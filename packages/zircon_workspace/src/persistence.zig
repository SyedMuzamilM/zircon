//! Synchronous file I/O with bounded reads and atomic sibling publication.
//! Existing-file conflict checks are optimistic: another writer can race the
//! final check and rename. New files use no-clobber publication instead.
const std = @import("std");
pub const max_file_bytes = 64 * 1024 * 1024;
pub const DiskStamp = struct {
    inode: std.Io.File.INode,
    size: u64,
    modified: i96,
    permissions: std.Io.File.Permissions,
    digest: [32]u8,
    pub fn eql(a: DiskStamp, b: DiskStamp) bool {
        return a.inode == b.inode and a.size == b.size and a.modified == b.modified and a.permissions == b.permissions and std.mem.eql(u8, &a.digest, &b.digest);
    }
};
pub const Loaded = struct { bytes: []u8, stamp: DiskStamp };
pub fn read(a: std.mem.Allocator, io: std.Io, path: []const u8) !Loaded {
    const before = try std.Io.Dir.cwd().statFile(io, path, .{});
    if (before.kind != .file) return error.NotRegularFile;
    if (before.size > max_file_bytes) return error.FileTooLarge;
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(max_file_bytes + 1)) catch |err| switch (err) {
        error.StreamTooLong => return error.FileTooLarge,
        else => return err,
    };
    errdefer a.free(bytes);
    const after = try std.Io.Dir.cwd().statFile(io, path, .{});
    if (!sameMetadata(before, after) or after.size != bytes.len) return error.DiskChanged;
    return .{ .bytes = bytes, .stamp = stamp(after, bytes) };
}
pub fn stampAt(io: std.Io, path: []const u8) !?DiskStamp {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(io);
    const before = try file.stat(io);
    if (before.kind != .file) return error.NotRegularFile;
    if (before.size > max_file_bytes) return error.FileTooLarge;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [32 * 1024]u8 = undefined;
    var offset: u64 = 0;
    while (offset < before.size) {
        const length: usize = @intCast(@min(buffer.len, before.size - offset));
        const count = try file.readPositionalAll(io, buffer[0..length], offset);
        if (count != length) return error.DiskChanged;
        hasher.update(buffer[0..count]);
        offset += count;
    }
    const after = try file.stat(io);
    const at_path = try std.Io.Dir.cwd().statFile(io, path, .{});
    if (!sameMetadata(before, after) or !sameMetadata(after, at_path)) return error.DiskChanged;
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return stampWithDigest(after, digest);
}
pub fn save(io: std.Io, path: []const u8, bytes: []const u8, expected: ?DiskStamp) !DiskStamp {
    if (bytes.len > max_file_bytes) return error.FileTooLarge;
    try checkExpected(io, path, expected);
    const permissions = if (expected) |old| old.permissions else std.Io.File.Permissions.default_file;
    var atomic = try std.Io.Dir.cwd().createFileAtomic(io, path, .{ .permissions = permissions, .replace = expected != null });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, bytes);
    if (expected != null) try atomic.file.setPermissions(io, permissions);
    try atomic.file.sync(io);
    const stat = try atomic.file.stat(io);
    const saved = stamp(stat, bytes);
    try checkExpected(io, path, expected);
    if (expected != null) try atomic.replace(io) else try atomic.link(io);
    return saved;
}
fn checkExpected(io: std.Io, path: []const u8, expected: ?DiskStamp) !void {
    const actual = try stampAt(io, path);
    if (expected) |old| {
        if (actual == null or !old.eql(actual.?)) return error.DiskConflict;
    } else if (actual != null) return error.PathAlreadyExists;
}
fn stamp(stat: std.Io.File.Stat, bytes: []const u8) DiskStamp {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return stampWithDigest(stat, digest);
}
fn sameMetadata(a: std.Io.File.Stat, b: std.Io.File.Stat) bool {
    return a.kind == b.kind and a.inode == b.inode and a.size == b.size and a.mtime.nanoseconds == b.mtime.nanoseconds and a.ctime.nanoseconds == b.ctime.nanoseconds;
}

fn stampWithDigest(stat: std.Io.File.Stat, digest: [32]u8) DiskStamp {
    return .{ .inode = stat.inode, .size = stat.size, .modified = stat.mtime.nanoseconds, .permissions = stat.permissions, .digest = digest };
}
