//! Intrinsic measurement cache for explicitly keyed leaf subtrees.

const std = @import("std");
const geometry = @import("geometry.zig");
const Entry = struct { fingerprint: u64, available: geometry.Size, intrinsic: geometry.Size };

pub const LayoutCache = struct {
    allocator: std.mem.Allocator,
    entries: std.AutoHashMapUnmanaged(u64, Entry) = .empty,
    pub fn init(allocator: std.mem.Allocator) LayoutCache {
        return .{ .allocator = allocator };
    }
    pub fn deinit(cache: *LayoutCache) void {
        cache.entries.deinit(cache.allocator);
        cache.* = undefined;
    }
    pub fn lookup(cache: *const LayoutCache, key: u64, fingerprint: u64, available: geometry.Size) ?geometry.Size {
        const entry = cache.entries.get(key) orelse return null;
        if (entry.fingerprint != fingerprint or !std.meta.eql(entry.available, available)) return null;
        return entry.intrinsic;
    }
    pub fn put(cache: *LayoutCache, key: u64, fingerprint: u64, available: geometry.Size, intrinsic: geometry.Size) !void {
        try cache.entries.put(cache.allocator, key, .{ .fingerprint = fingerprint, .available = available, .intrinsic = intrinsic });
    }
};

pub fn keyHash(key: anytype) u64 {
    return switch (key) {
        .string => |value| std.hash.Wyhash.hash(0, value),
        .number => |value| std.hash.Wyhash.hash(0, std.mem.asBytes(&value)),
    };
}
