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
    bytes: usize = 0,
    hits: usize = 0,
    misses: usize = 0,
    pub const max_bytes = 8 * 1024 * 1024;
    pub const max_entries = 4096;

    pub fn init(allocator: std.mem.Allocator) SceneCache {
        return .{ .allocator = allocator };
    }
    pub fn deinit(cache: *SceneCache) void {
        var values = cache.entries.valueIterator();
        while (values.next()) |entry| cache.releaseItems(entry.items, entry.items);
        cache.entries.deinit(cache.allocator);
        cache.* = undefined;
    }
    pub fn lookup(cache: *const SceneCache, key: u64, fingerprint: u64, bounds: geometry.Rect, clip: geometry.Rect) ?[]const scene.Primitive {
        const entry = cache.entries.get(key) orelse return null;
        if (entry.fingerprint != fingerprint or !std.meta.eql(entry.bounds, bounds) or !std.meta.eql(entry.clip, clip)) return null;
        return entry.items;
    }
    pub fn put(cache: *SceneCache, key: u64, fingerprint: u64, bounds: geometry.Rect, clip: geometry.Rect, source: []const scene.Primitive) !void {
        var size = source.len * @sizeOf(scene.Primitive);
        for (source) |item| {
            if (item.kind == .image or !std.meta.eql(item.transform, scene.Transform.identity)) return error.UncacheableScene;
            size += item.text.len;
        }
        if (size > max_bytes) return;
        const copied = try cache.allocator.alloc(scene.Primitive, source.len);
        var initialized: usize = 0;
        errdefer cache.releaseItems(copied[0..initialized], copied);
        for (source, copied) |item, *out| {
            const text = if (item.kind == .text) try cache.allocator.dupe(u8, item.text) else item.text;
            out.* = item;
            out.text = text;
            initialized += 1;
        }
        try cache.entries.ensureUnusedCapacity(cache.allocator, 1);
        if (cache.entries.fetchRemove(key)) |old| cache.releaseEntry(old.value);
        while (cache.bytes + size > max_bytes or cache.entries.count() >= max_entries) {
            var iterator = cache.entries.keyIterator();
            const evicted = iterator.next().?.*;
            cache.releaseEntry(cache.entries.fetchRemove(evicted).?.value);
        }
        cache.entries.putAssumeCapacity(key, .{ .fingerprint = fingerprint, .bounds = bounds, .clip = clip, .items = copied });
        cache.bytes += size;
    }
    fn releaseEntry(cache: *SceneCache, entry: Entry) void {
        cache.bytes -= entry.items.len * @sizeOf(scene.Primitive);
        for (entry.items) |item| cache.bytes -= item.text.len;
        cache.releaseItems(entry.items, entry.items);
    }
    fn releaseItems(cache: *SceneCache, items: []scene.Primitive, allocation: []scene.Primitive) void {
        for (items) |item| if (item.kind == .text) cache.allocator.free(item.text);
        cache.allocator.free(allocation);
    }
};
