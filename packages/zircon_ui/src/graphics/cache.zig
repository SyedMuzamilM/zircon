//! Persistent scene ranges for explicitly cached, keyed subtrees. Entries are
//! limited to CPU-owned primitives; image lifetimes stay with the frame.

const std = @import("std");
const geometry = @import("../layout/geometry.zig");
const scene = @import("scene.zig");
const Entry = struct {
    fingerprint: u64,
    bounds: geometry.Rect,
    clip: geometry.Rect,
    items: []scene.Primitive,
};

pub const SceneCache = struct {
    allocator: std.mem.Allocator,
    entries: std.AutoHashMapUnmanaged(u64, Entry) = .empty,

    pub fn init(allocator: std.mem.Allocator) SceneCache {
        return .{ .allocator = allocator };
    }
    pub fn deinit(cache: *SceneCache) void {
        var values = cache.entries.valueIterator();
        while (values.next()) |entry| cache.releaseItems(entry.items);
        cache.entries.deinit(cache.allocator);
        cache.* = undefined;
    }
    pub fn lookup(cache: *const SceneCache, key: u64, fingerprint: u64, bounds: geometry.Rect, clip: geometry.Rect) ?[]const scene.Primitive {
        const entry = cache.entries.get(key) orelse return null;
        if (entry.fingerprint != fingerprint or !std.meta.eql(entry.bounds, bounds) or !std.meta.eql(entry.clip, clip)) return null;
        return entry.items;
    }
    pub fn put(cache: *SceneCache, key: u64, fingerprint: u64, bounds: geometry.Rect, clip: geometry.Rect, source: []const scene.Primitive) !void {
        const copied = try cache.allocator.alloc(scene.Primitive, source.len);
        errdefer cache.releaseItems(copied);
        for (copied) |*item| item.* = .{ .kind = .rect, .rect = .{}, .clip = .{}, .color = .transparent };
        for (source, copied) |item, *out| {
            if (item.kind == .image or !std.meta.eql(item.transform, scene.Transform.identity)) return error.UncacheableScene;
            out.* = item;
            if (item.kind == .text) out.text = try cache.allocator.dupe(u8, item.text);
        }
        if (cache.entries.fetchRemove(key)) |old| cache.releaseItems(old.value.items);
        try cache.entries.put(cache.allocator, key, .{ .fingerprint = fingerprint, .bounds = bounds, .clip = clip, .items = copied });
    }
    fn releaseItems(cache: *SceneCache, items: []scene.Primitive) void {
        for (items) |item| if (item.kind == .text) cache.allocator.free(item.text);
        cache.allocator.free(items);
    }
};

pub fn keyHash(key: anytype) u64 {
    return switch (key) {
        .string => |value| std.hash.Wyhash.hash(0, value),
        .number => |value| std.hash.Wyhash.hash(0, std.mem.asBytes(&value)),
    };
}
