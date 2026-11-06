//! The GPU-independent application runtime. Entity access is callback-scoped;
//! notifications and deferred destruction settle when the outer transaction ends.
const std = @import("std");
const identities = @import("../entity/entity.zig");
const Store = @import("../entity/store.zig").Store;
const Scope = @import("../entity/scope.zig").Scope;
const windows = @import("window.zig");
const reactivity = @import("reactivity.zig");
const task_module = @import("tasks.zig");
const OwnedTasks = @import("owned_tasks.zig").OwnedTasks;
pub const Subscription = reactivity.Subscription;
var next_id = std.atomic.Value(u32).init(1);
const External = struct { owner: identities.Token, invoke: *const fn (*App, identities.Token) anyerror!void };
const State = struct {
    allocator: std.mem.Allocator,
    store: Store,
    thread: std.Thread.Id,
    depth: usize = 0,
    dirty: bool = false,
    scheduled_frames: u64 = 0,
    windows: std.ArrayList(?*windows.Window) = .empty,
    reactive: reactivity.Reactivity = .{},
    jobs: OwnedTasks,
    close_requests: std.ArrayList(windows.Handle) = .empty,
    external: std.ArrayList(External) = .empty,
    typography: @import("../text/typography.zig").Typography = .{},
};
pub const Options = struct { allocator: std.mem.Allocator };
pub const App = struct {
    state: *State,
    pub fn init(options: Options) !App {
        const app_id = try reserveId();
        const state = try options.allocator.create(State);
        state.* = .{ .allocator = options.allocator, .store = .init(options.allocator, app_id), .thread = std.Thread.getCurrentId(), .jobs = .init(options.allocator) };
        return .{ .state = state };
    }
    pub fn deinit(app: *App) void {
        std.debug.assert(app.state.thread == std.Thread.getCurrentId() and app.state.depth == 0 and !app.state.reactive.settling);
        const allocator = app.state.allocator;
        var remaining = app.state.windows.items.len;
        while (remaining > 0) {
            remaining -= 1;
            if (app.state.windows.items[remaining]) |w| w.deinit();
        }
        app.state.windows.deinit(allocator);
        app.state.jobs.deinit();
        app.state.close_requests.deinit(allocator);
        app.state.external.deinit(allocator);
        app.state.reactive.deinit(allocator);
        app.state.store.deinit();
        allocator.destroy(app.state);
        app.* = undefined;
    }
    fn check(app: App) !void {
        if (app.state.thread != std.Thread.getCurrentId()) return error.WrongThread;
        if (app.state.store.destroying) return error.AppIsDestroying;
    }
    pub fn beginTransaction(app: *App) !void {
        try app.check();
        app.state.depth += 1;
    }
    /// Native lifecycle callbacks can arrive synchronously while a view action
    /// owns an entity borrow. Those notifications drain at the next app step.
    pub fn transactionActive(app: *const App) bool {
        std.debug.assert(app.state.thread == std.Thread.getCurrentId());
        return app.state.depth != 0 or app.state.reactive.settling;
    }
    pub fn endTransaction(app: *App) void {
        std.debug.assert(app.state.depth > 0);
        app.finishTransaction();
    }
    pub fn openWindow(app: *App, comptime T: type, options: windows.Options, value: T) !windows.Handle {
        try app.check();
        const slot = app.state.windows.items.len;
        if (slot >= std.math.maxInt(u32)) return error.WindowCapacityExceeded;
        try app.state.windows.ensureUnusedCapacity(app.state.allocator, 1);
        const record = try windows.Window.create(app.*, app.state.allocator, T, options, value);
        record.surface.?.setTypography(app.state.typography);
        errdefer record.deinit();
        app.state.windows.appendAssumeCapacity(record);
        return .{ .app_id = app.state.store.app_id, .slot = @intCast(slot) };
    }
    pub fn window(app: *App, handle: windows.Handle) !*windows.Window {
        try app.check();
        if (handle.app_id != app.state.store.app_id) return error.WrongApplication;
        if (handle.generation != 1 or handle.slot >= app.state.windows.items.len) return error.WindowNotFound;
        const w = app.state.windows.items[handle.slot] orelse return error.WindowNotFound;
        if (w.closed) return error.WindowNotFound;
        return w;
    }
    pub fn openChildWindow(app: *App, parent: windows.Handle, comptime T: type, options: windows.Options, value: T) !windows.Handle {
        const parent_window = try app.window(parent);
        const child = try app.openWindow(T, options, value);
        const w = app.state.windows.items[child.slot].?;
        w.parent = parent;
        w.surface.?.setParent(parent_window.surface);
        return child;
    }
    pub fn raiseWindow(app: *App, handle: windows.Handle) !void {
        (try app.window(handle)).surface.?.raise();
    }
    pub fn windowEntity(app: *App, comptime T: type, handle: windows.Handle) !identities.Entity(T) {
        const w = try app.window(handle);
        const result = identities.typed(T, w.root);
        _ = try app.state.store.version(result);
        return result;
    }
    pub fn closeWindow(app: *App, handle: windows.Handle) !void {
        try (try app.window(handle)).dispatch(.close);
    }
    /// A handler can request close without reborrowing its own root entity.
    /// The next step routes a cancellable close after the current dispatch.
    pub fn requestCloseWindow(app: *App, handle: windows.Handle) !void {
        _ = try app.window(handle);
        for (app.state.close_requests.items) |queued| if (std.meta.eql(queued, handle)) return;
        try app.state.close_requests.append(app.state.allocator, handle);
    }
    /// Advances the same render path used by the native event loop. Tests inject time.
    pub fn step(app: *App, time: f64) !usize {
        try app.check();
        if (app.state.depth != 0) return error.TransactionActive;
        if (!std.math.isFinite(time) or time < 0) return error.InvalidTime;
        const native_count = app.state.windows.items.len;
        for (0..native_count) |index| if (app.state.windows.items[index]) |window_value| try window_value.flushNativeFocus();
        var external_index: usize = 0;
        // Copy the registration before calling it: callbacks may register other
        // recipients and grow the list. Dead generational identities are retired.
        const external_count = app.state.external.items.len;
        var visited: usize = 0;
        while (visited < external_count) : (visited += 1) {
            const recipient = app.state.external.items[external_index];
            if (!app.isAlive(recipient.owner)) {
                _ = app.state.external.orderedRemove(external_index);
                continue;
            }
            external_index += 1;
            try recipient.invoke(app, recipient.owner);
        }
        const close_count = app.state.close_requests.items.len;
        for (0..close_count) |_| {
            const request = app.state.close_requests.orderedRemove(0);
            app.closeWindow(request) catch |err| if (err != error.WindowNotFound) return err;
        }
        try app.state.jobs.drain(app);
        try app.flushEffects();
        if (try app.takeFrameRequest()) for (app.state.windows.items) |entry| {
            if (entry) |w| {
                for (w.frames.committed.dependencies.items) |dependency| {
                    const current_version = app.rawVersion(dependency.entity) catch {
                        w.dirty = true;
                        break;
                    };
                    if (current_version != dependency.version) {
                        w.dirty = true;
                        break;
                    }
                }
            }
        };
        var count: usize = 0;
        for (app.state.windows.items) |entry| if (entry) |w| if (w.parent) |parent| {
            _ = app.window(parent) catch {
                w.closed = true;
                w.surface.?.acceptClose();
                continue;
            };
        };
        var index = app.state.windows.items.len;
        while (index > 0) {
            index -= 1;
            const entry = &app.state.windows.items[index];
            const w = entry.* orelse continue;
            if (w.closed) {
                w.deinit();
                entry.* = null;
                continue;
            }
            w.time = time;
            if (w.animating) w.dirty = true;
            if (w.deadline) |deadline| if (time >= deadline) {
                w.dirty = true;
            };
            if (try w.draw()) count += 1;
        }
        return count;
    }
    pub fn dispatch(app: *App, handle: windows.Handle, input: @import("../platform/interface.zig").Input) !void {
        try (try app.window(handle)).dispatch(input);
    }
    pub fn run(app: *App) !void {
        while (true) {
            _ = try app.step(windows.now());
            var open = false;
            var animated = false;
            var deadline: ?f64 = null;
            for (app.state.windows.items) |entry| if (entry) |w| {
                if (!w.closed) {
                    open = true;
                    animated = animated or w.animating;
                    if (w.deadline) |time| deadline = @min(deadline orelse std.math.inf(f64), time);
                }
            };
            if (!open) return;
            if (app.state.dirty) continue;
            const next = if (deadline) |time| @max(0, time - windows.now()) else std.math.inf(f64);
            const interval = if (animated or app.state.jobs.queue.pending()) @min(next, 1.0 / 120.0) else next;
            try windows.pump(if (std.math.isFinite(interval)) interval else -1);
        }
    }
    pub fn createEntity(app: *App, comptime T: type, value: T) !identities.Entity(T) {
        try app.check();
        return app.state.store.create(T, value, .application);
    }
    pub fn spawn(app: *App, owner: anytype, comptime Job: type, job: Job, comptime callback: anytype) !task_module.Handle {
        try app.check();
        return app.state.jobs.spawn(app, owner, Job, job, callback);
    }
    pub fn cancelTask(app: *App, handle: task_module.Handle) !void {
        try app.check();
        try app.state.jobs.queue.cancel(handle);
    }
    pub fn tasksPending(app: *App) !bool {
        try app.check();
        return app.state.jobs.queue.pending();
    }
    /// Registers an entity-owned inbox drain. A producer calls wake() after
    /// publishing owned data; the recipient runs on the UI thread at next step.
    /// The callback must notify only when its effective state changes.
    pub fn watchExternal(app: *App, owner: anytype, comptime callback: anytype) !void {
        try app.check();
        _ = try app.version(owner);
        const T = @TypeOf(owner).State;
        const Adapter = struct {
            fn invoke(runtime: *App, token: identities.Token) !void {
                try runtime.update(identities.typed(T, token), callback, .{});
            }
        };
        for (app.state.external.items) |entry| if (std.meta.eql(entry.owner, owner.token()) and entry.invoke == Adapter.invoke) return;
        try app.state.external.append(app.state.allocator, .{ .owner = owner.token(), .invoke = Adapter.invoke });
    }
    /// Thread-safe event-loop signal. It carries no entity or borrowed payload.
    pub fn wake() void {
        windows.wake();
    }
    pub fn setReducedMotion(app: *App, reduced: bool) !void {
        try app.check();
        for (app.state.windows.items) |entry| if (entry) |w| {
            w.animations.reduced_motion = reduced;
            w.dirty = true;
        };
    }
    pub fn setTypography(app: *App, value: @import("../text/typography.zig").Typography) !void {
        try app.check();
        try value.validate();
        if (std.meta.eql(value, app.state.typography)) return;
        app.state.typography = value;
        for (app.state.windows.items) |entry| if (entry) |w| {
            w.surface.?.setTypography(value);
            w.dirty = true;
        };
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
        app.state.reactive.settle(app);
        app.state.jobs.cancelDead(app);
    }
    pub fn destroyScope(app: *App, scope: Scope) !void {
        try app.check();
        try app.state.store.destroyScope(scope);
        app.state.reactive.settle(app);
        app.state.jobs.cancelDead(app);
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
        if (app.state.depth == 0) {
            app.state.reactive.settle(app);
            app.state.jobs.cancelDead(app);
        }
    }
    /// Drains effects after all callback borrows end. Deferred callback failures
    /// are reported once here or by step(), without panicking in a defer block.
    pub fn flushEffects(app: *App) !void {
        try app.check();
        if (app.state.depth != 0 or app.state.reactive.settling) return error.TransactionActive;
        app.state.reactive.settle(app);
        if (app.state.reactive.takeError()) |err| return err;
    }
    pub fn isAlive(app: *App, token: identities.Token) bool {
        app.check() catch return false;
        return app.state.store.isAlive(token);
    }
    pub fn rawVersion(app: *App, token: identities.Token) !u64 {
        try app.check();
        return app.state.store.rawVersion(token);
    }
    pub fn observe(app: *App, owner: anytype, target: anytype, comptime callback: anytype) !Subscription {
        try app.check();
        return app.state.reactive.observe(app, owner, target, callback);
    }
    pub fn subscribe(app: *App, owner: anytype, target: anytype, comptime E: type, comptime callback: anytype) !Subscription {
        try app.check();
        return app.state.reactive.subscribe(app, owner, target, E, callback);
    }
    /// Event payloads copy by value or provide explicit clone/deinit ownership.
    pub fn emit(app: *App, source: anytype, value: anytype) !void {
        try app.check();
        try app.state.reactive.emit(app, source, value);
    }
    pub fn unsubscribe(app: *App, subscription: Subscription) !void {
        try app.check();
        try app.state.reactive.unsubscribe(app, subscription);
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
        pub fn observe(cx: *@This(), target: anytype, comptime callback: anytype) !Subscription {
            try cx.check();
            return cx.app.observe(cx.owner, target, callback);
        }
        pub fn subscribe(cx: *@This(), target: anytype, comptime E: type, comptime callback: anytype) !Subscription {
            try cx.check();
            return cx.app.subscribe(cx.owner, target, E, callback);
        }
        pub fn emit(cx: *@This(), value: anytype) !void {
            try cx.check();
            try cx.app.emit(cx.owner, value);
        }
        pub fn spawn(cx: *@This(), comptime Job: type, job: Job, comptime callback: anytype) !task_module.Handle {
            try cx.check();
            return cx.app.spawn(cx.owner, Job, job, callback);
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
