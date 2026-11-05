//! The GPU-independent application runtime. Entity access is callback-scoped;
//! notifications and deferred destruction settle when the outer transaction ends.
const std = @import("std");
const identities = @import("../entity/entity.zig");
const Store = @import("../entity/store.zig").Store;
const Scope = @import("../entity/scope.zig").Scope;
var next_id = std.atomic.Value(u32).init(1);
const State = struct { allocator: std.mem.Allocator, store: Store, thread: std.Thread.Id, depth: usize = 0, dirty: bool = false, scheduled_frames: u64 = 0 };
pub const Options = struct { allocator: std.mem.Allocator };
pub const App = struct {
    state: *State,
    pub fn init(options: Options) !App {
        const app_id = try reserveId();
        const state = try options.allocator.create(State);
        state.* = .{ .allocator = options.allocator, .store = .init(options.allocator, app_id), .thread = std.Thread.getCurrentId() };
        return .{ .state = state };
    }
    pub fn deinit(app: *App) void {
        std.debug.assert(app.state.thread == std.Thread.getCurrentId() and app.state.depth == 0);
        const allocator = app.state.allocator;
        app.state.store.deinit();
        allocator.destroy(app.state);
        app.* = undefined;
    }
    fn check(app: App) !void {
        if (app.state.thread != std.Thread.getCurrentId()) return error.WrongThread;
        if (app.state.store.destroying) return error.AppIsDestroying;
    }
    pub fn createEntity(app: *App, comptime T: type, value: T) !identities.Entity(T) {
        try app.check();
        return app.state.store.create(T, value, .application);
    }
    pub fn createScope(app: *App) !Scope {
        try app.check();
        return app.state.store.createScope();
    }
    pub fn createInScope(app: *App, scope: Scope, comptime T: type, value: T) !identities.Entity(T) {
        try app.check();
        return app.state.store.create(T, value, .{ .scope = scope });
    }
    pub fn destroyEntity(app: *App, handle: anytype) !void {
        try app.check();
        try app.state.store.destroy(handle);
    }
    pub fn destroyScope(app: *App, scope: Scope) !void {
        try app.check();
        try app.state.store.destroyScope(scope);
    }
    pub fn read(app: *App, handle: anytype, comptime function: anytype, args: anytype) Result(@TypeOf(function)) {
        try app.check();
        const T = @TypeOf(handle).State;
        comptime {
            requireFirst(@TypeOf(function), *const T);
            requireSnapshot(Payload(@TypeOf(function)));
        }
        const access = try app.state.store.acquire(handle, false);
        app.state.depth += 1;
        defer {
            app.state.store.release(handle.token(), false);
            app.finishTransaction();
        }
        const object: *const T = @ptrCast(@alignCast(access.pointer));
        return @call(.auto, function, .{object} ++ args);
    }
    pub fn update(app: *App, handle: anytype, comptime function: anytype, args: anytype) Result(@TypeOf(function)) {
        try app.check();
        const T = @TypeOf(handle).State;
        comptime {
            requireFirst(@TypeOf(function), *T);
            const parameters = @typeInfo(@TypeOf(function)).@"fn".param_types;
            if (parameters.len < 2 or parameters[1] != *Context(T)) @compileError("entity update must receive (*Self, *Context(Self), ...)");
            requireSnapshot(Payload(@TypeOf(function)));
        }
        const access = try app.state.store.acquire(handle, true);
        app.state.depth += 1;
        defer {
            app.state.store.release(handle.token(), true);
            app.finishTransaction();
        }
        const object: *T = @ptrCast(@alignCast(access.pointer));
        var context: Context(T) = .{ .app = app.*, .owner = handle, .lease = access.lease };
        return @call(.auto, function, .{ object, &context } ++ args);
    }
    fn finishTransaction(app: *App) void {
        app.state.depth -= 1;
        if (app.state.depth != 0) return;
        app.state.store.flushDestruction();
        if (app.state.store.flushNotifications() and !app.state.dirty) {
            app.state.dirty = true;
            app.state.scheduled_frames += 1;
        }
    }
    pub fn version(app: *App, handle: anytype) !u64 {
        try app.check();
        return app.state.store.version(handle);
    }
    /// Consumes a coalesced request; it does not render synchronously.
    pub fn takeFrameRequest(app: *App) !bool {
        try app.check();
        const dirty = app.state.dirty;
        app.state.dirty = false;
        return dirty;
    }
    pub fn scheduledFrameCount(app: *App) !u64 {
        try app.check();
        return app.state.scheduled_frames;
    }
};
pub fn Context(comptime T: type) type {
    return struct {
        app: App,
        owner: identities.Entity(T),
        lease: u64,
        fn check(cx: *const @This()) !void {
            try cx.app.check();
            if (!cx.app.state.store.contextValid(cx.owner.token(), cx.lease)) return error.InvalidContext;
        }
        /// Valid only during this callback. Repeated notifications are coalesced.
        pub fn notify(cx: *@This()) void {
            std.debug.assert(cx.app.state.thread == std.Thread.getCurrentId());
            cx.app.state.store.notify(cx.owner.token(), cx.lease);
        }
        pub fn read(cx: *@This(), handle: anytype, comptime function: anytype, args: anytype) Result(@TypeOf(function)) {
            try cx.check();
            return cx.app.read(handle, function, args);
        }
        pub fn update(cx: *@This(), handle: anytype, comptime function: anytype, args: anytype) Result(@TypeOf(function)) {
            try cx.check();
            return cx.app.update(handle, function, args);
        }
        pub fn createChild(cx: *@This(), comptime U: type, value: U) !identities.Entity(U) {
            try cx.check();
            return cx.app.state.store.create(U, value, .{ .entity = cx.owner.token() });
        }
        /// Destruction is deferred until all active callbacks have returned.
        pub fn destroy(cx: *@This(), handle: anytype) !void {
            try cx.check();
            try cx.app.state.store.requestDestroy(handle);
        }
    };
}
fn reserveId() !u32 {
    var current = next_id.load(.monotonic);
    while (true) {
        if (current == std.math.maxInt(u32)) return error.ApplicationIdExhausted;
        if (next_id.cmpxchgWeak(current, current + 1, .monotonic, .monotonic)) |actual| current = actual else return current;
    }
}
fn Payload(comptime F: type) type {
    const R = @typeInfo(F).@"fn".return_type.?;
    return if (@typeInfo(R) == .error_union) @typeInfo(R).error_union.payload else R;
}
fn Result(comptime F: type) type {
    return anyerror!Payload(F);
}
fn requireFirst(comptime F: type, comptime First: type) void {
    const info = @typeInfo(F);
    if (info != .@"fn") @compileError("entity access requires a function");
    if (info.@"fn".param_types.len == 0 or info.@"fn".param_types[0] != First) @compileError("entity callback has incompatible self parameter");
}
fn requireSnapshot(comptime T: type) void {
    switch (@typeInfo(T)) {
        .pointer => @compileError("read/update results cannot borrow pointers or slices; copy into a caller-owned output argument"),
        .@"struct" => |info| {
            for (info.field_types) |Field| requireSnapshot(Field);
        },
        .@"union" => |info| {
            for (info.field_types) |Field| requireSnapshot(Field);
        },
        .array => |info| requireSnapshot(info.child),
        .optional => |info| requireSnapshot(info.child),
        else => {},
    }
}
