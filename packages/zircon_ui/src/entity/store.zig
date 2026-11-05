//! Stable allocations behind a generational slab. No GPU or native dependency.
//! Destruction preflights borrows before touching an ownership subtree. Destructors
//! run child-first and may free their own resources, but cannot reenter this store.
const std = @import("std");
const entity = @import("entity.zig");
const scope = @import("scope.zig");
const Borrow = @import("borrow.zig").Borrow;
const Allocator = std.mem.Allocator;
const VTable = struct { destroy: *const fn (*anyopaque, Allocator) void };
const Slot = struct {
    generation: u32 = 1,
    retired: bool = false,
    type_tag: usize = 0,
    pointer: ?*anyopaque = null,
    vtable: ?*const VTable = null,
    owner: scope.Owner = .application,
    depth: u16 = 0,
    borrow: Borrow = .{},
    lease: u64 = 0,
    version: u64 = 0,
    pending_notify: bool = false,
    pending_destroy: bool = false,
};
const ScopeSlot = struct { generation: u32 = 1, alive: bool = false, retired: bool = false };
pub const Store = struct {
    allocator: Allocator,
    app_id: u32,
    slots: std.ArrayList(Slot) = .empty,
    scopes: std.ArrayList(ScopeSlot) = .empty,
    destroying: bool = false,
    next_lease: u64 = 1,
    destruction_version: u64 = 0,
    pub fn init(a: Allocator, app_id: u32) Store {
        return .{ .allocator = a, .app_id = app_id };
    }
    pub fn deinit(s: *Store) void {
        std.debug.assert(!s.destroying);
        for (s.slots.items) |slot| std.debug.assert(!slot.borrow.active());
        s.destroying = true;
        for (0..s.slots.items.len) |i| if (s.slots.items[i].pointer != null) s.destroyRecursive(@intCast(i));
        s.slots.deinit(s.allocator);
        s.scopes.deinit(s.allocator);
    }
    pub fn create(s: *Store, comptime T: type, value: T, owner: scope.Owner) !entity.Entity(T) {
        if (s.destroying) return error.AppIsDestroying;
        var depth: u16 = 0;
        switch (owner) {
            .application => {},
            .scope => |handle| {
                _ = try s.resolveScope(handle);
            },
            .entity => |token| {
                const parent = try s.resolve(token, null);
                if (parent.pending_destroy) return error.EntityNotFound;
                if (parent.depth >= 128) return error.ScopeDepthExceeded;
                depth = parent.depth + 1;
            },
        }
        const pointer = try s.allocator.create(T);
        errdefer s.allocator.destroy(pointer);
        var index: ?u32 = null;
        for (s.slots.items, 0..) |slot, i| if (slot.pointer == null and !slot.retired) {
            index = @intCast(i);
            break;
        };
        if (index == null) {
            if (s.slots.items.len >= std.math.maxInt(u32)) return error.EntityCapacityExceeded;
            try s.slots.append(s.allocator, .{});
            index = @intCast(s.slots.items.len - 1);
        }
        const Adapter = struct {
            const vtable: VTable = .{ .destroy = destroyObject };
            fn destroyObject(raw: *anyopaque, a: Allocator) void {
                const object: *T = @ptrCast(@alignCast(raw));
                if (comptime hasDeinit(T)) {
                    if (@TypeOf(T.deinit) != fn (*T, Allocator) void) @compileError(@typeName(T) ++ ".deinit must have signature fn (*Self, std.mem.Allocator) void");
                    object.deinit(a);
                }
                a.destroy(object);
            }
        };
        pointer.* = value;
        const generation = s.slots.items[index.?].generation;
        s.slots.items[index.?] = .{ .generation = generation, .type_tag = entity.typeTag(T), .pointer = pointer, .vtable = &Adapter.vtable, .owner = owner, .depth = depth };
        return entity.typed(T, .{ .app_id = s.app_id, .slot = index.?, .generation = generation });
    }
    pub fn createScope(s: *Store) !scope.Scope {
        if (s.destroying) return error.AppIsDestroying;
        var index: ?u32 = null;
        for (s.scopes.items, 0..) |slot, i| if (!slot.alive and !slot.retired) {
            index = @intCast(i);
            break;
        };
        if (index == null) {
            if (s.scopes.items.len >= std.math.maxInt(u32)) return error.ScopeCapacityExceeded;
            try s.scopes.append(s.allocator, .{});
            index = @intCast(s.scopes.items.len - 1);
        }
        const slot = &s.scopes.items[index.?];
        slot.alive = true;
        return .{ .app_id = s.app_id, .slot = index.?, .generation = slot.generation };
    }
    fn resolveScope(s: *Store, handle: scope.Scope) !*ScopeSlot {
        if (handle.app_id != s.app_id) return error.WrongApplication;
        if (handle.slot >= s.scopes.items.len) return error.ScopeNotFound;
        const slot = &s.scopes.items[handle.slot];
        if (!slot.alive or slot.generation != handle.generation) return error.ScopeNotFound;
        return slot;
    }
    fn resolve(s: *Store, token: entity.Token, tag: ?usize) !*Slot {
        if (s.destroying) return error.AppIsDestroying;
        if (token.app_id != s.app_id) return error.WrongApplication;
        if (token.slot >= s.slots.items.len) return error.EntityNotFound;
        const slot = &s.slots.items[token.slot];
        if (slot.pointer == null or slot.generation != token.generation) return error.EntityNotFound;
        if (tag) |expected| if (slot.type_tag != expected) return error.WrongEntityType;
        return slot;
    }
    pub fn acquire(s: *Store, handle: anytype, mutable: bool) !struct { pointer: *anyopaque, lease: u64 } {
        const T = @TypeOf(handle).State;
        const slot = try s.resolve(handle.token(), entity.typeTag(T));
        if (slot.pending_destroy) return error.EntityNotFound;
        if (mutable) {
            if (s.next_lease == std.math.maxInt(u64)) return error.ContextLeaseExhausted;
            try slot.borrow.write();
            slot.lease = s.next_lease;
            s.next_lease += 1;
        } else try slot.borrow.read();
        return .{ .pointer = slot.pointer.?, .lease = slot.lease };
    }
    pub fn release(s: *Store, token: entity.Token, mutable: bool) void {
        // Resolve again: user callbacks may grow the slab while the object stays stable.
        const slot = &s.slots.items[token.slot];
        std.debug.assert(slot.generation == token.generation);
        if (mutable) {
            slot.borrow.releaseWrite();
            slot.lease = 0;
        } else slot.borrow.releaseRead();
    }
    pub fn contextValid(s: *Store, token: entity.Token, lease: u64) bool {
        const slot = s.resolve(token, null) catch return false;
        return slot.borrow.writer and slot.lease == lease and lease != 0;
    }
    pub fn notify(s: *Store, token: entity.Token, lease: u64) void {
        std.debug.assert(s.contextValid(token, lease));
        s.slots.items[token.slot].pending_notify = true;
    }
    pub fn flushNotifications(s: *Store) bool {
        var changed = false;
        for (s.slots.items) |*slot| if (slot.pointer != null and slot.pending_notify) {
            std.debug.assert(!slot.borrow.active());
            slot.pending_notify = false;
            slot.version +%= 1;
            changed = true;
        };
        return changed;
    }
    pub fn version(s: *Store, handle: anytype) !u64 {
        return (try s.resolve(handle.token(), entity.typeTag(@TypeOf(handle).State))).version;
    }
    /// Untyped identities are used only for lifecycle checks and dependency
    /// versions. Access to entity storage still requires a typed handle.
    pub fn rawVersion(s: *Store, token: entity.Token) !u64 {
        const slot = try s.resolve(token, null);
        if (slot.pending_destroy) return error.EntityNotFound;
        return slot.version;
    }
    pub fn isAlive(s: *Store, token: entity.Token) bool {
        _ = s.rawVersion(token) catch return false;
        return true;
    }
    pub fn requestDestroy(s: *Store, handle: anytype) !void {
        const slot = try s.resolve(handle.token(), entity.typeTag(@TypeOf(handle).State));
        slot.pending_destroy = true;
    }
    pub fn destroy(s: *Store, handle: anytype) !void {
        _ = try s.resolve(handle.token(), entity.typeTag(@TypeOf(handle).State));
        try s.preflight(handle.token().slot);
        s.destroying = true;
        defer s.destroying = false;
        s.destroyRecursive(handle.slot);
    }
    pub fn destroyScope(s: *Store, handle: scope.Scope) !void {
        _ = try s.resolveScope(handle);
        for (s.slots.items, 0..) |slot, i| if (slot.pointer != null and slot.owner == .scope and sameScope(slot.owner.scope, handle)) try s.preflight(@intCast(i));
        s.destroying = true;
        defer s.destroying = false;
        for (0..s.slots.items.len) |i| {
            const slot = s.slots.items[i];
            if (slot.pointer != null and slot.owner == .scope and sameScope(slot.owner.scope, handle)) s.destroyRecursive(@intCast(i));
        }
        const slot = &s.scopes.items[handle.slot];
        slot.alive = false;
        retire(&slot.generation, &slot.retired);
    }
    fn preflight(s: *Store, index: u32) anyerror!void {
        if (s.slots.items[index].borrow.active()) return error.BorrowConflict;
        const token = entity.Token{ .app_id = s.app_id, .slot = index, .generation = s.slots.items[index].generation };
        for (s.slots.items, 0..) |slot, i| if (slot.pointer != null and slot.owner == .entity and sameEntity(slot.owner.entity, token)) try s.preflight(@intCast(i));
    }
    fn destroyRecursive(s: *Store, index: u32) void {
        const token = entity.Token{ .app_id = s.app_id, .slot = index, .generation = s.slots.items[index].generation };
        for (0..s.slots.items.len) |i| {
            const child = s.slots.items[i];
            if (child.pointer != null and child.owner == .entity and sameEntity(child.owner.entity, token)) s.destroyRecursive(@intCast(i));
        }
        const slot = &s.slots.items[index];
        const pointer = slot.pointer.?;
        const vtable = slot.vtable.?;
        slot.pointer = null;
        slot.pending_destroy = false;
        slot.pending_notify = false;
        s.destruction_version +%= 1;
        retire(&slot.generation, &slot.retired);
        vtable.destroy(pointer, s.allocator);
    }
    pub fn flushDestruction(s: *Store) void {
        s.destroying = true;
        defer s.destroying = false;
        for (0..s.slots.items.len) |i| if (s.slots.items[i].pointer != null and s.slots.items[i].pending_destroy) {
            s.preflight(@intCast(i)) catch unreachable;
            s.destroyRecursive(@intCast(i));
        };
    }
};
fn retire(generation: *u32, retired: *bool) void {
    if (generation.* == std.math.maxInt(u32)) retired.* = true else generation.* += 1;
}
fn sameEntity(a: entity.Token, b: entity.Token) bool {
    return a.app_id == b.app_id and a.slot == b.slot and a.generation == b.generation;
}
fn sameScope(a: scope.Scope, b: scope.Scope) bool {
    return a.app_id == b.app_id and a.slot == b.slot and a.generation == b.generation;
}
fn hasDeinit(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(T, "deinit"),
        else => false,
    };
}
