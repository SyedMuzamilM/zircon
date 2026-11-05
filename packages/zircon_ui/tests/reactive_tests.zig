const std = @import("std");
const ui = @import("zircon_ui");
const t = std.testing;
const Source = struct {
    value: u32 = 0,
    fn get(self: *const Source) u32 {
        return self.value;
    }
    fn set(self: *Source, cx: *ui.Context(Source), value: u32) void {
        self.value = value;
        cx.notify();
        cx.notify();
    }
    fn increment(self: *Source, cx: *ui.Context(Source), _: ui.Entity(Source)) void {
        self.value += 1;
        cx.notify();
    }
    fn emitSaved(self: *Source, cx: *ui.Context(Source), count: u32) !void {
        try cx.emit(Saved{ .count = count });
        self.value = count + 1;
    }
};
const Saved = struct { count: u32 };
const Observer = struct {
    calls: u32 = 0,
    value: u32 = 0,
    fn changed(self: *Observer, cx: *ui.Context(Observer), source: ui.Entity(Source)) !void {
        self.calls += 1;
        self.value = try cx.read(source, Source.get, .{});
        cx.notify();
    }
    fn saved(self: *Observer, cx: *ui.Context(Observer), source: ui.Entity(Source), event: *const Saved) !void {
        self.calls += 1;
        self.value = event.count + try cx.read(source, Source.get, .{});
        cx.notify();
    }
    fn snapshot(self: *const Observer) struct { calls: u32, value: u32 } {
        return .{ .calls = self.calls, .value = self.value };
    }
    fn fail(_: *Observer, _: *ui.Context(Observer), _: ui.Entity(Source)) !void {
        return error.ObserverFailed;
    }
};
test "observers run after the outer borrow and coalesce repeated notifications" {
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const source = try app.createEntity(Source, .{});
    const observer = try app.createEntity(Observer, .{});
    _ = try app.observe(observer, source, Observer.changed);
    try app.beginTransaction();
    try app.update(source, Source.set, .{4});
    try app.update(source, Source.set, .{8});
    try t.expectEqual(@as(u32, 0), (try app.read(observer, Observer.snapshot, .{})).calls);
    app.endTransaction();
    const value = try app.read(observer, Observer.snapshot, .{});
    try t.expectEqual(@as(u32, 1), value.calls);
    try t.expectEqual(@as(u32, 8), value.value);
    try t.expectEqual(@as(u64, 1), try app.scheduledFrameCount());
    try app.flushEffects();
}
test "chained observers settle after each callback releases its mutation borrow" {
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const source = try app.createEntity(Source, .{});
    const first = try app.createEntity(Observer, .{});
    const last = try app.createEntity(Observer, .{});
    const Chain = struct {
        fn changed(self: *Observer, cx: *ui.Context(Observer), target: ui.Entity(Observer)) !void {
            const value = try cx.read(target, Observer.snapshot, .{});
            self.calls += 1;
            self.value = value.value + 1;
            cx.notify();
        }
    };
    _ = try app.observe(last, first, Chain.changed);
    _ = try app.observe(first, source, Observer.changed);
    try app.update(source, Source.set, .{12});
    try t.expectEqual(@as(u32, 13), (try app.read(last, Observer.snapshot, .{})).value);
    try t.expectEqual(@as(u32, 1), (try app.read(last, Observer.snapshot, .{})).calls);
}
test "destroying either endpoint suppresses pending effects and stale generations stay dead" {
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const source = try app.createEntity(Source, .{});
    const observer = try app.createEntity(Observer, .{});
    _ = try app.observe(observer, source, Observer.changed);
    try app.beginTransaction();
    try app.update(source, Source.set, .{12});
    try app.destroyEntity(source);
    app.endTransaction();
    try t.expectEqual(@as(u32, 0), (try app.read(observer, Observer.snapshot, .{})).calls);
    try t.expect(!app.isAlive(source.token()));
    const fresh = try app.createEntity(Source, .{});
    try t.expect(fresh.slot == source.slot and fresh.generation != source.generation);
    try app.update(fresh, Source.set, .{1});
    try t.expectEqual(@as(u32, 0), (try app.read(observer, Observer.snapshot, .{})).calls);
    const registration = try app.observe(observer, fresh, Observer.changed);
    try app.destroyEntity(observer);
    try app.update(fresh, Source.set, .{2});
    try t.expectError(error.SubscriptionNotFound, app.unsubscribe(registration));
}
test "subscription slots reuse storage while old handles cannot unsubscribe replacements" {
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    var other = try ui.App.init(.{ .allocator = t.allocator });
    defer other.deinit();
    const source = try app.createEntity(Source, .{});
    const observer = try app.createEntity(Observer, .{});
    const old = try app.observe(observer, source, Observer.changed);
    try app.unsubscribe(old);
    const fresh = try app.observe(observer, source, Observer.changed);
    try t.expectEqual(old.slot, fresh.slot);
    try t.expect(old.generation != fresh.generation);
    try t.expectError(error.SubscriptionNotFound, app.unsubscribe(old));
    try t.expectError(error.WrongApplication, other.unsubscribe(fresh));
    try app.update(source, Source.set, .{3});
    try t.expectEqual(@as(u32, 1), (try app.read(observer, Observer.snapshot, .{})).calls);
    try app.unsubscribe(fresh);
    for (0..1000) |_| {
        const next = try app.observe(observer, source, Observer.changed);
        try app.unsubscribe(next);
    }
    try t.expectEqual(@as(usize, 1), app.state.reactive.registrations.items.len);
}
test "observer callbacks can unsubscribe themselves grow the registry and defer destruction" {
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const Reactive = struct {
        registration: ?ui.Subscription = null,
        calls: u32 = 0,
        fn changed(self: *@This(), cx: *ui.Context(@This()), source: ui.Entity(Source)) !void {
            self.calls += 1;
            try cx.app.unsubscribe(self.registration.?);
            for (0..300) |_| _ = try cx.observe(source, quiet);
            try cx.destroy(cx.owner);
        }
        fn quiet(_: *@This(), _: *ui.Context(@This()), _: ui.Entity(Source)) void {}
        fn register(self: *@This(), cx: *ui.Context(@This()), source: ui.Entity(Source)) !void {
            self.registration = try cx.observe(source, changed);
        }
        fn get(self: *const @This()) u32 {
            return self.calls;
        }
    };
    const source = try app.createEntity(Source, .{});
    const observer = try app.createEntity(Reactive, .{});
    try app.update(observer, Reactive.register, .{source});
    try app.update(source, Source.set, .{3});
    try t.expect(!app.isAlive(observer.token()));
    try t.expectError(error.EntityNotFound, app.read(observer, Reactive.get, .{}));
    try app.flushEffects();
}
test "observer failures report once and effect cycles terminate without recursive callbacks" {
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const source = try app.createEntity(Source, .{});
    const observer = try app.createEntity(Observer, .{});
    const failure = try app.observe(observer, source, Observer.fail);
    try app.update(source, Source.set, .{2});
    try t.expectError(error.ObserverFailed, app.flushEffects());
    try app.flushEffects();
    try app.unsubscribe(failure);
    const cycle = try app.observe(source, source, Source.increment);
    try app.update(source, Source.set, .{1});
    try t.expectError(error.EffectCycle, app.flushEffects());
    try app.unsubscribe(cycle);
    try app.flushEffects();
}
test "typed events deliver owned values after source mutation returns" {
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const source = try app.createEntity(Source, .{});
    const observer = try app.createEntity(Observer, .{});
    _ = try app.subscribe(observer, source, Saved, Observer.saved);
    try app.update(source, Source.emitSaved, .{9});
    const value = try app.read(observer, Observer.snapshot, .{});
    try t.expectEqual(@as(u32, 1), value.calls);
    try t.expectEqual(@as(u32, 19), value.value);
    try app.beginTransaction();
    try app.emit(source, Saved{ .count = 2 });
    _ = try app.subscribe(observer, source, Saved, Observer.saved);
    app.endTransaction();
    try t.expectEqual(@as(u32, 2), (try app.read(observer, Observer.snapshot, .{})).calls);
}
test "an event callback replacing another subscription cannot receive the older queued event" {
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const Swapper = struct {
        next: ?ui.Subscription = null,
        observer: ui.Entity(Observer),
        swapped: bool = false,
        fn saved(self: *@This(), cx: *ui.Context(@This()), source: ui.Entity(Source), _: *const Saved) !void {
            if (!self.swapped) {
                try cx.app.unsubscribe(self.next.?);
                _ = try cx.app.subscribe(self.observer, source, Saved, Observer.saved);
                self.swapped = true;
            }
        }
        fn set(self: *@This(), _: *ui.Context(@This()), subscription: ui.Subscription) void {
            self.next = subscription;
        }
    };
    const source = try app.createEntity(Source, .{});
    const observer = try app.createEntity(Observer, .{});
    const swapper = try app.createEntity(Swapper, .{ .observer = observer });
    _ = try app.subscribe(swapper, source, Saved, Swapper.saved);
    const original = try app.subscribe(observer, source, Saved, Observer.saved);
    try app.update(swapper, Swapper.set, .{original});
    try app.emit(source, Saved{ .count = 4 });
    try t.expectEqual(@as(u32, 0), (try app.read(observer, Observer.snapshot, .{})).calls);
    try app.emit(source, Saved{ .count = 5 });
    try t.expectEqual(@as(u32, 1), (try app.read(observer, Observer.snapshot, .{})).calls);
}
const OwnedEvent = struct {
    text: []const u8,
    releases: *usize,
    pub fn clone(self: OwnedEvent, a: std.mem.Allocator) !OwnedEvent {
        return .{ .text = try a.dupe(u8, self.text), .releases = self.releases };
    }
    pub fn deinit(self: *OwnedEvent, a: std.mem.Allocator) void {
        a.free(self.text);
        self.releases.* += 1;
    }
};
test "events clone borrowed input and release it even when a subscriber fails" {
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const source = try app.createEntity(Source, .{});
    const observer = try app.createEntity(Observer, .{});
    var releases: usize = 0;
    const Capture = struct {
        fn received(self: *Observer, _: *ui.Context(Observer), _: ui.Entity(Source), event: *const OwnedEvent) !void {
            try t.expectEqualStrings("saved", event.text);
            self.calls += 1;
            return error.EventFailed;
        }
    };
    _ = try app.subscribe(observer, source, OwnedEvent, Capture.received);
    var bytes = [_]u8{ 's', 'a', 'v', 'e', 'd' };
    try app.beginTransaction();
    try app.emit(source, OwnedEvent{ .text = &bytes, .releases = &releases });
    @memset(&bytes, 'x');
    app.endTransaction();
    try t.expectEqual(@as(usize, 1), releases);
    try t.expectError(error.EventFailed, app.flushEffects());
    try t.expectEqual(@as(u32, 1), (try app.read(observer, Observer.snapshot, .{})).calls);
}
const Child = struct {
    pub fn render(_: *const Child, b: *ui.Ui) !ui.Element {
        return b.text("child");
    }
};
const Parent = struct {
    child: ui.Entity(Child),
    source: ui.Entity(Source),
    fail: bool = false,
    pub fn render(self: *const Parent, b: *ui.Ui) !ui.Element {
        const value = try b.watch(self.source, Source.get, .{});
        const child = try b.view(self.child);
        if (self.fail) return error.ViewFailed;
        return b.column(.{}, &.{ child, try b.textFmt("Value {d}", .{value}) });
    }
    fn setFailure(self: *Parent, cx: *ui.Context(Parent)) void {
        self.fail = true;
        cx.notify();
    }
};
test "Ui.view and watch record committed dependencies and failed render retains the old set" {
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const source = try app.createEntity(Source, .{ .value = 7 });
    const child = try app.createEntity(Child, .{});
    const window = try app.openWindow(Parent, .{ .visible = false }, .{ .child = child, .source = source });
    _ = try app.step(0);
    const w = try app.window(window);
    try t.expectEqual(@as(usize, 3), w.frames.committed.dependencies.items.len);
    try t.expectEqualStrings("child", w.frames.committed.nodes.items[0].kind.text);
    try t.expectEqualStrings("Value 7", w.frames.committed.nodes.items[1].kind.text);
    const epoch = w.frames.committed.epoch;
    const root = try app.windowEntity(Parent, window);
    try app.update(root, Parent.setFailure, .{});
    try app.update(source, Source.set, .{9});
    try t.expectError(error.ViewFailed, app.step(1));
    try t.expectEqual(epoch, w.frames.committed.epoch);
    for (w.frames.committed.dependencies.items) |dep| if (std.meta.eql(dep.entity, source.token())) try t.expectEqual(@as(u64, 0), dep.version);
}
test "reactive registrations and cloned event storage clean up under allocation failure" {
    try t.checkAllAllocationFailures(t.allocator, allocationCase, .{});
}
fn allocationCase(a: std.mem.Allocator) !void {
    var app = try ui.App.init(.{ .allocator = a });
    defer app.deinit();
    const source = try app.createEntity(Source, .{});
    const observer = try app.createEntity(Observer, .{});
    _ = try app.observe(observer, source, Observer.changed);
    _ = try app.subscribe(observer, source, Saved, Observer.saved);
    var releases: usize = 0;
    try app.emit(source, OwnedEvent{ .text = "owned", .releases = &releases });
    try app.update(source, Source.emitSaved, .{8});
    try app.flushEffects();
}

const PresenceView = struct {
    shown: bool = true,
    pub fn render(self: *const PresenceView, b: *ui.Ui) !ui.Element {
        const present = try b.presence(1, self.shown, .{ .tween = .{ .duration = 1, .easing = .linear } });
        if (!present.visible) return b.div(.{}, &.{});
        return b.div(.{ .width = .{ .px = 80 }, .height = .{ .px = 20 }, .opacity = present.opacity, .background = ui.Color.white }, &.{});
    }
    fn hide(self: *PresenceView, cx: *ui.Context(PresenceView)) void {
        self.shown = false;
        cx.notify();
    }
};
test "presence keeps an exiting element until fade completion and then stops scheduling" {
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const window = try app.openWindow(PresenceView, .{ .visible = false }, .{});
    _ = try app.step(0);
    try app.update(try app.windowEntity(PresenceView, window), PresenceView.hide, .{});
    _ = try app.step(1);
    _ = try app.step(1.5);
    const w = try app.window(window);
    try t.expectEqual(@as(usize, 1), w.frames.committed.scene.items.len);
    try t.expectApproxEqAbs(@as(f32, 0.5), w.frames.committed.scene.items[0].color.a, 0.001);
    _ = try app.step(2);
    try t.expectEqual(@as(usize, 0), w.frames.committed.scene.items.len);
    try t.expectEqual(@as(usize, 0), try app.step(3));
}
const GeometryView = struct {
    rect: ui.Rect = .{ .x = 10, .width = 20, .height = 30 },
    color: ui.Color = .black,
    pub fn render(self: *const GeometryView, b: *ui.Ui) !ui.Element {
        const rect = try b.animateRect(10, self.rect, .{ .tween = .{ .duration = 1, .easing = .linear } });
        const color = try b.animateColor(20, self.color, .{ .spring = .{ .stiffness = 220, .damping = 1 } });
        return b.stack(.{ .width = .{ .px = rect.width }, .height = .{ .px = rect.height }, .background = color }, &.{try b.textFmt("x={d:.1}", .{rect.x})});
    }
    fn change(self: *GeometryView, cx: *ui.Context(GeometryView)) void {
        self.rect = .{ .x = 60, .width = 120, .height = 130 };
        self.color = .white;
        cx.notify();
    }
};
test "geometry channels interpolate together and spring color channels remain valid" {
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const window = try app.openWindow(GeometryView, .{ .visible = false }, .{});
    _ = try app.step(0);
    try app.update(try app.windowEntity(GeometryView, window), GeometryView.change, .{});
    _ = try app.step(1);
    _ = try app.step(1.2);
    const w = try app.window(window);
    try t.expect(w.frames.committed.scene.items[0].color.r <= 1);
    _ = try app.step(1.5);
    try t.expectEqualStrings("x=35.0", w.frames.committed.nodes.items[0].kind.text);
    try t.expectApproxEqAbs(@as(f32, 70), w.frames.committed.bounds[w.frames.committed.root.?.index].width, 0.001);
    try t.expectApproxEqAbs(@as(f32, 80), w.frames.committed.bounds[w.frames.committed.root.?.index].height, 0.001);
}
