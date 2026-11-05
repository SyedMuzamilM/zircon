const std = @import("std");
const ui = @import("zircon_ui");
const t = std.testing;
const Counter = struct {
    value: i32 = 0,
    fn get(s: *const Counter) i32 {
        return s.value;
    }
    fn add(s: *Counter, cx: *ui.Context(Counter), n: i32) void {
        s.value += n;
        cx.notify();
        cx.notify();
    }
};
test "typed read/update and notifications use one scheduled frame" {
    var h = try ui.testing.Harness.init(t.allocator);
    defer h.deinit();
    const counter = try h.app.createEntity(Counter, .{});
    try h.app.update(counter, Counter.add, .{3});
    try h.app.update(counter, Counter.add, .{4});
    try t.expectEqual(@as(i32, 7), try h.app.read(counter, Counter.get, .{}));
    try t.expectEqual(@as(u64, 2), try h.app.version(counter));
    try t.expectEqual(@as(u64, 1), try h.app.scheduledFrameCount());
    try t.expect(try h.flush());
    try t.expect(!try h.flush());
    try h.app.update(counter, Counter.add, .{1});
    try t.expectEqual(@as(u64, 2), try h.app.scheduledFrameCount());
}
test "stale handles, foreign applications and forged types are refused" {
    var a = try ui.App.init(.{ .allocator = t.allocator });
    defer a.deinit();
    var b = try ui.App.init(.{ .allocator = t.allocator });
    defer b.deinit();
    const old = try a.createEntity(Counter, .{});
    try a.destroyEntity(old);
    const fresh = try a.createEntity(Counter, .{ .value = 9 });
    try t.expectEqual(old.slot, fresh.slot);
    try t.expect(old.generation != fresh.generation);
    try t.expectError(error.EntityNotFound, a.read(old, Counter.get, .{}));
    try t.expectError(error.WrongApplication, b.read(fresh, Counter.get, .{}));
    const Other = struct {
        value: i32,
        fn get(s: *const @This()) i32 {
            return s.value;
        }
    };
    const forged: ui.Entity(Other) = .{ .app_id = fresh.app_id, .slot = fresh.slot, .generation = fresh.generation };
    try t.expectError(error.WrongEntityType, a.read(forged, Other.get, .{}));
}
test "reentrant mutation and reads during mutation are refused, then borrow releases" {
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const counter = try app.createEntity(Counter, .{});
    const Methods = struct {
        fn check(_: *Counter, cx: *ui.Context(Counter), entity: ui.Entity(Counter)) !void {
            try t.expectError(error.BorrowConflict, cx.update(entity, Counter.add, .{1}));
            try t.expectError(error.BorrowConflict, cx.read(entity, Counter.get, .{}));
            return error.ExpectedCallbackFailure;
        }
        fn readAgain(s: *const Counter, other: *ui.App, handle: ui.Entity(Counter)) !i32 {
            return s.value + try other.read(handle, Counter.get, .{});
        }
    };
    try t.expectError(error.ExpectedCallbackFailure, app.update(counter, Methods.check, .{counter}));
    try app.update(counter, Counter.add, .{5});
    try t.expectEqual(@as(i32, 10), try app.read(counter, Methods.readAgain, .{ &app, counter }));
}
test "scope destruction releases children before parents and invalidates all handles" {
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    var log: std.ArrayList(u8) = .empty;
    defer log.deinit(t.allocator);
    const Resource = struct {
        tag: u8,
        log: *std.ArrayList(u8),
        child: ?ui.Entity(@This()) = null,
        pub fn deinit(s: *@This(), a: std.mem.Allocator) void {
            s.log.append(a, s.tag) catch unreachable;
        }
        fn spawn(s: *@This(), cx: *ui.Context(@This())) !void {
            s.child = try cx.createChild(@This(), .{ .tag = 'c', .log = s.log });
        }
        fn childOf(s: *const @This(), out: *?ui.Entity(@This())) void {
            out.* = s.child;
        }
        fn tagOf(s: *const @This()) u8 {
            return s.tag;
        }
    };
    try log.ensureTotalCapacity(t.allocator, 3);
    const scope = try app.createScope();
    const parent = try app.createInScope(scope, Resource, .{ .tag = 'p', .log = &log });
    try app.update(parent, Resource.spawn, .{});
    var child: ?ui.Entity(Resource) = null;
    try app.read(parent, Resource.childOf, .{&child});
    try app.destroyScope(scope);
    try t.expectEqualStrings("cp", log.items);
    try t.expectError(error.EntityNotFound, app.read(parent, Resource.tagOf, .{}));
    try t.expectError(error.EntityNotFound, app.read(child.?, Resource.tagOf, .{}));
    try t.expectError(error.ScopeNotFound, app.createInScope(scope, Counter, .{}));
}
test "entity allocations remain stable while the slot registry grows" {
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const root = try app.createEntity(Counter, .{});
    const Methods = struct {
        fn grow(s: *Counter, cx: *ui.Context(Counter)) !void {
            s.value = 11;
            for (0..2000) |_| _ = try cx.createChild(Counter, .{});
            s.value += 12;
            cx.notify();
        }
    };
    try app.update(root, Methods.grow, .{});
    try t.expectEqual(@as(i32, 23), try app.read(root, Counter.get, .{}));
}
test "destroying a borrowed subtree refuses atomically and context destruction defers" {
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const root = try app.createEntity(Counter, .{});
    const Methods = struct {
        fn direct(_: *Counter, cx: *ui.Context(Counter), handle: ui.Entity(Counter)) !void {
            try t.expectError(error.BorrowConflict, cx.app.destroyEntity(handle));
        }
        fn deferred(s: *Counter, cx: *ui.Context(Counter), handle: ui.Entity(Counter)) !void {
            try cx.destroy(handle);
            s.value = 99;
            cx.notify();
        }
    };
    try app.update(root, Methods.direct, .{root});
    try app.update(root, Methods.deferred, .{root});
    try t.expectError(error.EntityNotFound, app.read(root, Counter.get, .{}));
}
test "copied contexts expire at the end of their callback" {
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const root = try app.createEntity(Counter, .{});
    const Methods = struct {
        fn capture(_: *Counter, cx: *ui.Context(Counter), out: *?ui.Context(Counter)) void {
            out.* = cx.*;
        }
    };
    var copied: ?ui.Context(Counter) = null;
    try app.update(root, Methods.capture, .{&copied});
    try t.expectError(error.InvalidContext, copied.?.createChild(Counter, .{}));
}
test "entity creation allocation failures do not leak or consume the caller's value" {
    try t.checkAllAllocationFailures(t.allocator, allocationCase, .{});
}
fn allocationCase(a: std.mem.Allocator) !void {
    var app = try ui.App.init(.{ .allocator = a });
    defer app.deinit();
    const handle = try app.createEntity(Counter, .{});
    try app.update(handle, Counter.add, .{1});
    try t.expectEqual(@as(i32, 1), try app.read(handle, Counter.get, .{}));
}
test "many generation reuse cycles cannot revive an old handle" {
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const old = try app.createEntity(Counter, .{});
    try app.destroyEntity(old);
    for (0..10000) |_| {
        const next = try app.createEntity(Counter, .{});
        try app.destroyEntity(next);
    }
    try t.expectError(error.EntityNotFound, app.read(old, Counter.get, .{}));
}

test "immutable borrow blocks a mutable update until the read returns" {
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const handle = try app.createEntity(Counter, .{});
    const Reader = struct {
        fn check(_: *const Counter, owner: *ui.App, entity: ui.Entity(Counter)) !void {
            try t.expectError(error.BorrowConflict, owner.update(entity, Counter.add, .{1}));
        }
    };
    try app.read(handle, Reader.check, .{ &app, handle });
    try app.update(handle, Counter.add, .{1});
}

test "destruction refuses a borrowed child without partially destroying its parent" {
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const scope = try app.createScope();
    const parent = try app.createInScope(scope, Counter, .{});
    const Spawn = struct {
        fn spawn(_: *Counter, cx: *ui.Context(Counter)) !ui.Entity(Counter) {
            return cx.createChild(Counter, .{});
        }
    };
    const child = try app.update(parent, Spawn.spawn, .{});
    const Child = struct {
        fn check(_: *Counter, cx: *ui.Context(Counter), root: ui.Entity(Counter), owner: ui.Scope) !void {
            try t.expectError(error.BorrowConflict, cx.app.destroyEntity(root));
            try t.expectError(error.BorrowConflict, cx.app.destroyScope(owner));
        }
    };
    try app.update(child, Child.check, .{ parent, scope });
    try t.expectEqual(@as(i32, 0), try app.read(parent, Counter.get, .{}));
    try t.expectEqual(@as(i32, 0), try app.read(child, Counter.get, .{}));
}

test "generation exhaustion retires entity and scope slots instead of wrapping" {
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    var handle = try app.createEntity(Counter, .{});
    // Fault injection exercises the otherwise unreachable final generation.
    app.state.store.slots.items[handle.slot].generation = std.math.maxInt(u32);
    handle.generation = std.math.maxInt(u32);
    try app.destroyEntity(handle);
    const replacement = try app.createEntity(Counter, .{});
    try t.expect(replacement.slot != handle.slot);
    try t.expectError(error.EntityNotFound, app.read(handle, Counter.get, .{}));
    var scope = try app.createScope();
    app.state.store.scopes.items[scope.slot].generation = std.math.maxInt(u32);
    scope.generation = std.math.maxInt(u32);
    try app.destroyScope(scope);
    const next = try app.createScope();
    try t.expect(next.slot != scope.slot);
}

test "entity access from a worker is rejected before touching the registry" {
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const handle = try app.createEntity(Counter, .{});
    var refused = false;
    const Worker = struct {
        fn run(owner: *ui.App, entity: ui.Entity(Counter), result: *bool) void {
            _ = owner.read(entity, Counter.get, .{}) catch |err| {
                result.* = err == error.WrongThread;
                return;
            };
        }
    };
    const worker = try std.Thread.spawn(.{}, Worker.run, .{ &app, handle, &refused });
    worker.join();
    try t.expect(refused);
}

test "destructors cannot reenter the application while ownership is being released" {
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    var refused = false;
    const Owned = struct {
        owner: *ui.App,
        result: *bool,
        pub fn deinit(s: *@This(), _: std.mem.Allocator) void {
            _ = s.owner.createEntity(Counter, .{}) catch |err| {
                s.result.* = err == error.AppIsDestroying;
                return;
            };
        }
    };
    const object = try app.createEntity(Owned, .{ .owner = &app, .result = &refused });
    try app.destroyEntity(object);
    try t.expect(refused);
}
