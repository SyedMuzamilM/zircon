//! Observations, owned typed events and post-borrow effect delivery. Registry
//! slots are generational; callbacks never retain pointers into growable arrays.
const std = @import("std");
const identities = @import("../entity/entity.zig");
const app_module = @import("app.zig");
const App = app_module.App;
const Context = app_module.Context;
/// A subscription is non-owning. Owner/target destruction automatically disables
/// it; a reused registry slot receives a new generation.
pub const Subscription = struct { app_id: u32, slot: u32, generation: u32 };
const Registration = struct {
    owner: identities.Token,
    target: identities.Token,
    generation: u32 = 1,
    active: bool = true,
    retired: bool = false,
    created: u64,
    kind: union(enum) {
        observation: struct { seen: u64, invoke: *const fn (*App, identities.Token, identities.Token) anyerror!void },
        event: struct { type_tag: usize, invoke: *const fn (*App, identities.Token, identities.Token, *const anyopaque) anyerror!void },
    },
};
const QueuedEvent = struct {
    source: identities.Token,
    type_tag: usize,
    through: u64,
    value: *anyopaque,
    destroy: *const fn (*anyopaque, std.mem.Allocator) void,
};
pub const Reactivity = struct {
    registrations: std.ArrayList(Registration) = .empty,
    events: std.ArrayList(QueuedEvent) = .empty,
    event_cursor: usize = 0,
    next_registration: u64 = 1,
    settling: bool = false,
    effect_error: ?anyerror = null,
    destruction_version: u64 = 0,
    pub fn deinit(self: *Reactivity, allocator: std.mem.Allocator) void {
        std.debug.assert(!self.settling);
        self.discardEvents(allocator);
        self.events.deinit(allocator);
        self.registrations.deinit(allocator);
        self.* = undefined;
    }
    pub fn takeError(self: *Reactivity) ?anyerror {
        const result = self.effect_error;
        self.effect_error = null;
        return result;
    }
    pub fn observe(self: *Reactivity, app: *App, owner: anytype, target: anytype, comptime callback: anytype) !Subscription {
        _ = try app.version(owner);
        _ = try app.version(target);
        const Owner = @TypeOf(owner).State;
        const Target = @TypeOf(target).State;
        const Adapter = struct {
            fn invoke(runtime: *App, owner_token: identities.Token, target_token: identities.Token) !void {
                try runtime.update(identities.typed(Owner, owner_token), call, .{identities.typed(Target, target_token)});
            }
            fn call(owner_state: *Owner, cx: *Context(Owner), source: identities.Entity(Target)) !void {
                return @call(.auto, callback, .{ owner_state, cx, source });
            }
        };
        return self.register(app, .{ .owner = owner.token(), .target = target.token(), .created = 0, .kind = .{ .observation = .{ .seen = try app.rawVersion(target.token()), .invoke = Adapter.invoke } } });
    }
    pub fn subscribe(self: *Reactivity, app: *App, owner: anytype, target: anytype, comptime E: type, comptime callback: anytype) !Subscription {
        _ = try app.version(owner);
        _ = try app.version(target);
        const Owner = @TypeOf(owner).State;
        const Target = @TypeOf(target).State;
        const Adapter = struct {
            fn invoke(runtime: *App, owner_token: identities.Token, target_token: identities.Token, raw: *const anyopaque) !void {
                const value: *const E = @ptrCast(@alignCast(raw));
                try runtime.update(identities.typed(Owner, owner_token), call, .{ identities.typed(Target, target_token), value });
            }
            fn call(owner_state: *Owner, cx: *Context(Owner), source: identities.Entity(Target), value: *const E) !void {
                return @call(.auto, callback, .{ owner_state, cx, source, value });
            }
        };
        return self.register(app, .{ .owner = owner.token(), .target = target.token(), .created = 0, .kind = .{ .event = .{ .type_tag = identities.typeTag(E), .invoke = Adapter.invoke } } });
    }
    pub fn emit(self: *Reactivity, app: *App, source: anytype, value: anytype) !void {
        _ = try app.version(source);
        _ = try app.rawVersion(source.token());
        const E = @TypeOf(value);
        const owned = comptime eventHasOwnership(E);
        comptime if (!owned) requireEvent(E);
        const object = try app.state.allocator.create(E);
        errdefer app.state.allocator.destroy(object);
        object.* = if (owned) try value.clone(app.state.allocator) else value;
        errdefer if (owned) object.deinit(app.state.allocator);
        const Adapter = struct {
            fn destroy(raw: *anyopaque, allocator: std.mem.Allocator) void {
                const event: *E = @ptrCast(@alignCast(raw));
                if (owned) event.deinit(allocator);
                allocator.destroy(event);
            }
        };
        try self.events.append(app.state.allocator, .{ .source = source.token(), .type_tag = identities.typeTag(E), .through = self.next_registration - 1, .value = object, .destroy = Adapter.destroy });
        if (app.state.depth == 0) self.settle(app);
    }
    pub fn unsubscribe(self: *Reactivity, app: *App, subscription: Subscription) !void {
        if (subscription.app_id != app.state.store.app_id) return error.WrongApplication;
        if (subscription.slot >= self.registrations.items.len) return error.SubscriptionNotFound;
        const record = &self.registrations.items[subscription.slot];
        if (!record.active or record.generation != subscription.generation) return error.SubscriptionNotFound;
        record.active = false;
    }
    fn register(self: *Reactivity, app: *App, value: Registration) !Subscription {
        if (!app.isAlive(value.owner) or !app.isAlive(value.target)) return error.EntityNotFound;
        if (self.next_registration == std.math.maxInt(u64)) return error.SubscriptionSequenceExhausted;
        var entry = value;
        entry.created = self.next_registration;
        var index: ?u32 = null;
        for (self.registrations.items, 0..) |*record, i| if (!record.active and !record.retired) {
            if (record.generation == std.math.maxInt(u32)) {
                record.retired = true;
                continue;
            }
            entry.generation = record.generation + 1;
            index = @intCast(i);
            break;
        };
        if (index) |slot| self.registrations.items[slot] = entry else {
            if (self.registrations.items.len >= std.math.maxInt(u32)) return error.SubscriptionCapacityExceeded;
            index = @intCast(self.registrations.items.len);
            try self.registrations.append(app.state.allocator, entry);
        }
        self.next_registration += 1;
        return .{ .app_id = app.state.store.app_id, .slot = index.?, .generation = entry.generation };
    }
    fn rememberError(self: *Reactivity, err: anyerror) void {
        if (self.effect_error == null) self.effect_error = err;
    }
    fn flushChanges(self: *Reactivity, app: *App) bool {
        app.state.store.flushDestruction();
        const destroyed = self.destruction_version != app.state.store.destruction_version;
        self.destruction_version = app.state.store.destruction_version;
        const changed = app.state.store.flushNotifications() or destroyed;
        if (changed and !app.state.dirty) {
            app.state.dirty = true;
            app.state.scheduled_frames += 1;
        }
        return changed;
    }
    fn discardEvents(self: *Reactivity, allocator: std.mem.Allocator) void {
        for (self.events.items[self.event_cursor..]) |event| event.destroy(event.value, allocator);
        self.events.clearRetainingCapacity();
        self.event_cursor = 0;
    }
    pub fn settle(self: *Reactivity, app: *App) void {
        if (self.settling or app.state.depth != 0) return;
        self.settling = true;
        defer self.settling = false;
        if (!self.flushChanges(app) and self.events.items.len == 0) return;
        var budget: usize = 4096;
        while (true) {
            var delivered = false;
            const limit = self.registrations.items.len;
            for (0..limit) |i| {
                // Copy before calling user code: callbacks may grow or reuse the
                // registry, unsubscribe themselves, or destroy either entity.
                const record = self.registrations.items[i];
                if (!record.active) continue;
                if (!app.isAlive(record.owner) or !app.isAlive(record.target)) {
                    self.registrations.items[i].active = false;
                    continue;
                }
                if (record.kind != .observation) continue;
                const current_version = app.state.store.rawVersion(record.target) catch continue;
                if (record.kind.observation.seen == current_version) continue;
                if (budget == 0) {
                    self.stopEffectCycle(app);
                    return;
                }
                budget -= 1;
                self.registrations.items[i].kind.observation.seen = current_version;
                record.kind.observation.invoke(app, record.owner, record.target) catch |err| self.rememberError(err);
                delivered = true;
            }
            if (self.event_cursor < self.events.items.len) {
                if (budget == 0) {
                    self.stopEffectCycle(app);
                    return;
                }
                budget -= 1;
                const event = self.events.items[self.event_cursor];
                self.event_cursor += 1;
                const event_limit = self.registrations.items.len;
                for (0..event_limit) |i| {
                    const record = self.registrations.items[i];
                    if (!record.active or record.created > event.through or record.kind != .event or record.kind.event.type_tag != event.type_tag or !std.meta.eql(record.target, event.source)) continue;
                    if (!app.isAlive(record.owner) or !app.isAlive(record.target)) {
                        self.registrations.items[i].active = false;
                        continue;
                    }
                    record.kind.event.invoke(app, record.owner, record.target, event.value) catch |err| self.rememberError(err);
                }
                event.destroy(event.value, app.state.allocator);
                delivered = true;
            }
            if (!delivered) break;
            _ = self.flushChanges(app);
        }
        self.discardEvents(app.state.allocator);
    }
    fn stopEffectCycle(self: *Reactivity, app: *App) void {
        self.rememberError(error.EffectCycle);
        _ = self.flushChanges(app);
        self.discardEvents(app.state.allocator);
        // Terminate this delivery wave. The latest state is retained; future
        // explicit mutations can notify again after the caller handles the error.
        for (self.registrations.items) |*record| if (record.active and record.kind == .observation) {
            record.kind.observation.seen = app.state.store.rawVersion(record.target) catch 0;
        };
    }
};

fn eventHasOwnership(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum" => @hasDecl(T, "clone") and @hasDecl(T, "deinit"),
        else => false,
    };
}

fn requireEvent(comptime T: type) void {
    switch (@typeInfo(T)) {
        .pointer => @compileError("event payloads with pointers require clone(Allocator)!Self and deinit(*Self, Allocator)"),
        .@"struct" => |info| for (info.field_types) |Field| {
            requireEvent(Field);
        },
        .@"union" => |info| for (info.field_types) |Field| {
            requireEvent(Field);
        },
        .array => |info| requireEvent(info.child),
        .optional => |info| requireEvent(info.child),
        else => {},
    }
}
