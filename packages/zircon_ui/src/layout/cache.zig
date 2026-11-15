//! Bounded subtree measurements and arranged bounds, copied in preorder so
//! fresh frame indices can reuse them after sibling insertions or removals.

const std = @import("std");
const geometry = @import("geometry.zig");
const Entry = struct {
    fingerprint: u64,
    available: geometry.Size,
    sizes: []geometry.Size,
    rect: ?geometry.Rect = null,
    bounds: []geometry.Rect = &.{},
};
pub const LayoutCache = struct {
    allocator: std.mem.Allocator,
    entries: std.AutoHashMapUnmanaged(u64, Entry) = .empty,
    bytes: usize = 0,
    measurement_hits: usize = 0,
    arrangement_hits: usize = 0,
    pub const max_bytes = 8 * 1024 * 1024;
    pub const max_entries = 4096;

    pub fn init(allocator: std.mem.Allocator) LayoutCache {
        return .{ .allocator = allocator };
    }
    pub fn deinit(cache: *LayoutCache) void {
        var values = cache.entries.valueIterator();
        while (values.next()) |entry| cache.release(entry.*);
        cache.entries.deinit(cache.allocator);
        cache.* = undefined;
    }
    pub fn lookup(cache: *LayoutCache, key: u64, fingerprint: u64, available: geometry.Size) ?[]const geometry.Size {
        const entry = cache.entries.get(key) orelse return null;
        if (entry.fingerprint != fingerprint or !std.meta.eql(entry.available, available)) return null;
        cache.measurement_hits += 1;
        return entry.sizes;
    }
    pub fn put(cache: *LayoutCache, key: u64, fingerprint: u64, available: geometry.Size, sizes: []const geometry.Size) !void {
        const bytes = sizes.len * (@sizeOf(geometry.Size) + @sizeOf(geometry.Rect));
        if (bytes > max_bytes) return;
        const copied = try cache.allocator.dupe(geometry.Size, sizes);
        errdefer cache.allocator.free(copied);
        try cache.entries.ensureUnusedCapacity(cache.allocator, 1);
        if (cache.entries.fetchRemove(key)) |old| cache.release(old.value);
        while (cache.bytes + bytes > max_bytes or cache.entries.count() >= max_entries) {
            var keys = cache.entries.keyIterator();
            const remove_key = keys.next().?.*;
            cache.release(cache.entries.fetchRemove(remove_key).?.value);
        }
        cache.entries.putAssumeCapacity(key, .{ .fingerprint = fingerprint, .available = available, .sizes = copied });
        cache.bytes += bytes;
    }
    pub fn arranged(cache: *LayoutCache, key: u64, fingerprint: u64, rect: geometry.Rect) ?[]const geometry.Rect {
        const entry = cache.entries.get(key) orelse return null;
        if (entry.fingerprint != fingerprint or entry.rect == null or !std.meta.eql(entry.rect.?, rect)) return null;
        cache.arrangement_hits += 1;
        return entry.bounds;
    }
    pub fn putArrangement(cache: *LayoutCache, key: u64, fingerprint: u64, rect: geometry.Rect, bounds: []const geometry.Rect) !void {
        const entry = cache.entries.getPtr(key) orelse return;
        if (entry.fingerprint != fingerprint or bounds.len != entry.sizes.len) return;
        const copied = try cache.allocator.dupe(geometry.Rect, bounds);
        cache.allocator.free(entry.bounds);
        entry.bounds = copied;
        entry.rect = rect;
    }
    fn release(cache: *LayoutCache, entry: Entry) void {
        cache.bytes -= entry.sizes.len * (@sizeOf(geometry.Size) + @sizeOf(geometry.Rect));
        cache.allocator.free(entry.sizes);
        cache.allocator.free(entry.bounds);
    }
};
