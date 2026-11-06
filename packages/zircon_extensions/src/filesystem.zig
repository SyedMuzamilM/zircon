//! Managed bundle I/O. A package is bounded regular files/directories; symlinks
//! are refused throughout the bundle rather than resolving outside ownership.
const std = @import("std");
pub const max_bundle_bytes = 128 * 1024 * 1024;
const Usage = struct { bytes: u64 = 0, entries: usize = 0 };
pub fn validateRelative(path: []const u8) !void {
    if (path.len == 0 or path.len > 4096 or std.fs.path.isAbsolute(path) or std.mem.indexOfAny(u8, path, "\\\x00") != null) return error.InvalidContributionPath;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.InvalidContributionPath;
}
pub fn validateBundle(a: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    var usage: Usage = .{};
    try walk(a, io, path, null, 0, &usage);
}
pub fn copyBundle(a: std.mem.Allocator, io: std.Io, source: []const u8, destination: []const u8) !void {
    var usage: Usage = .{};
    try walk(a, io, source, destination, 0, &usage);
}
fn walk(a: std.mem.Allocator, io: std.Io, path: []const u8, destination: ?[]const u8, depth: usize, usage: *Usage) anyerror!void {
    if (depth > 16) return error.BundleTooDeep;
    const stat = try std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false });
    if (stat.kind == .sym_link) return error.SymlinkNotAllowed;
    if (stat.kind != .directory) return error.InvalidBundleDirectory;
    const dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);
    if (destination) |target| try std.Io.Dir.cwd().createDirPath(io, target);
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        usage.entries += 1;
        if (usage.entries > 16384) return error.BundleTooManyFiles;
        const metadata = try dir.statFile(io, entry.name, .{ .follow_symlinks = false });
        if (metadata.kind == .sym_link) return error.SymlinkNotAllowed;
        const next = try std.fs.path.join(a, &.{ path, entry.name });
        defer a.free(next);
        const target = if (destination) |base| try std.fs.path.join(a, &.{ base, entry.name }) else null;
        defer if (target) |value| a.free(value);
        if (metadata.kind == .directory) {
            try walk(a, io, next, target, depth + 1, usage);
        } else if (metadata.kind == .file) {
            usage.bytes = std.math.add(u64, usage.bytes, metadata.size) catch return error.BundleTooLarge;
            if (usage.bytes > max_bundle_bytes) return error.BundleTooLarge;
            if (target) |value| try std.Io.Dir.cwd().copyFile(next, std.Io.Dir.cwd(), value, io, .{});
        } else return error.UnsupportedBundleFile;
    }
}
pub fn persist(a: std.mem.Allocator, io: std.Io, home: []const u8, entries: anytype) !void {
    const bytes = try std.json.Stringify.valueAlloc(a, .{ .schema_version = @as(u32, 1), .extensions = entries }, .{ .whitespace = .indent_2 });
    defer a.free(bytes);
    const path = try std.fs.path.join(a, &.{ home, "state.json" });
    defer a.free(path);
    var atomic = try std.Io.Dir.cwd().createFileAtomic(io, path, .{ .replace = true });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, bytes);
    try atomic.file.sync(io);
    try atomic.replace(io);
}
