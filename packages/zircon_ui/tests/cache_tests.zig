const std = @import("std");
const ui = @import("zircon_ui");
const t = std.testing;

const Panels = struct {
    value: u32 = 0,
    spacer: bool = false,
    fail: bool = false,
    pub fn render(self: *const Panels, b: *ui.Ui) !ui.Element {
        const f = b.fluent();
        const left = try f.row().id(.named("left")).h_px(40).cache().children(.{
            f.textFmt("Value {}", .{self.value}),
            try ui.controls.icons.element(b, .folder, .white, 16),
            f.row().hover_bg(.white).children(.{f.text("hover")}),
        }).build();
        const right = try f.row().id(.named("right")).h_px(40).cache().children(.{
            f.text("unchanged"),
            try ui.controls.icons.element(b, .file, .white, 16),
        }).build();
        if (self.fail) return error.DeliberateRenderFailure;
        return f.column().gap_px(4).children(.{
            f.text(if (self.spacer) "changed sibling" else "sibling"),
            f.adopt(left),
            f.adopt(right),
        }).build();
    }
    fn update(self: *Panels, cx: *ui.Context(Panels), value: u32, spacer: bool, fail: bool) void {
        self.* = .{ .value = value, .spacer = spacer, .fail = fail };
        cx.notify();
    }
};

fn reference(window: anytype) !void {
    const frame = &window.frames.committed;
    const measurer = window.surface.?.measurer();
    var fresh = try ui.layout.calculate(t.allocator, frame, frame.root.?, .{ .viewport = window.dimensions }, measurer);
    defer fresh.deinit();
    try t.expectEqualSlices(ui.Rect, fresh.bounds, frame.bounds);
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var painter = try ui.graphics.Painter.init(arena.allocator(), .{ .width = window.dimensions.width, .height = window.dimensions.height });
    try ui.graphics.paintTree(frame, &fresh, &painter, measurer);
    const expected = try painter.finish(window.background);
    try t.expectEqual(expected.items.len, frame.scene.items.len);
    for (expected.items, frame.scene.items) |a, b| {
        try t.expectEqualStrings(a.text, b.text);
        var lhs = a;
        var rhs = b;
        lhs.text = "";
        rhs.text = "";
        try t.expect(std.meta.eql(lhs, rhs));
    }
}

test "subtree measurement arrangement and scene hits match a fresh frame after edits hover resize and failure" {
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const handle = try app.openWindow(Panels, .{ .visible = false, .width = 320, .height = 180 }, .{});
    const owner = try app.windowEntity(Panels, handle);
    _ = try app.step(0);
    const window = try app.window(handle);
    try reference(window);
    const epoch = window.frames.committed.epoch;
    const initial_measure = window.layout_cache.measurement_hits;
    const initial_arrange = window.layout_cache.arrangement_hits;
    const initial_scene = window.scene_cache.hits;
    try app.update(owner, Panels.update, .{ 0, false, false });
    _ = try app.step(0.1);
    try t.expect(window.layout_cache.measurement_hits >= initial_measure + 2);
    try t.expect(window.layout_cache.arrangement_hits >= initial_arrange + 2);
    try t.expect(window.scene_cache.hits >= initial_scene + 2);
    try reference(window);
    try app.update(owner, Panels.update, .{ 1, true, false });
    _ = try app.step(0.2);
    try reference(window);
    try app.dispatch(handle, .{ .pointer_move = .{ .position = .{ .x = 95, .y = 30 } } });
    _ = try app.step(0.3);
    try reference(window);
    try app.dispatch(handle, .{ .resize = .{ .width = 220, .height = 140 } });
    _ = try app.step(0.4);
    try reference(window);
    const committed = window.frames.committed.epoch;
    try app.update(owner, Panels.update, .{ 2, false, true });
    try t.expectError(error.DeliberateRenderFailure, app.step(0.5));
    try t.expectEqual(committed, window.frames.committed.epoch);
    try t.expect(epoch != committed);
    try reference(window);
    try app.update(owner, Panels.update, .{ 3, false, false });
    _ = try app.step(0.6);
    try reference(window);
}

test "replayed text survives cache replacement and cache deinitialization" {
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const h = try app.openWindow(Panels, .{ .visible = false }, .{});
    const owner = try app.windowEntity(Panels, h);
    _ = try app.step(0);
    try app.update(owner, Panels.update, .{ 0, false, false });
    _ = try app.step(1);
    const window = try app.window(h);
    try t.expect(window.scene_cache.hits > 0);
    window.scene_cache.deinit();
    window.scene_cache = .init(t.allocator);
    try reference(window);
}

fn cacheAllocationCase(a: std.mem.Allocator) !void {
    var cache = ui.graphics.SceneCache.init(a);
    defer cache.deinit();
    const items = [_]@typeInfo(@FieldType(ui.graphics.Scene, "items")).pointer.child{
        .{ .kind = .text, .text = "first", .rect = .{}, .clip = .{}, .color = .white },
        .{ .kind = .text, .text = "second", .rect = .{}, .clip = .{}, .color = .white },
    };
    try cache.put(1, 1, .{}, .{}, &items);
    try cache.put(1, 2, .{}, .{}, &items);
}
test "scene cache allocation failures preserve caller text and release partial copies" {
    try t.checkAllAllocationFailures(t.allocator, cacheAllocationCase, .{});
}

test "layout cache invalidates font generation rem and viewport and remaps shifted frame indices" {
    var h = try ui.testing.Harness.init(t.allocator);
    defer h.deinit();
    const model = try h.app.createEntity(Panels, .{});
    var cache = ui.layout.Cache.init(t.allocator);
    defer cache.deinit();
    var metrics: ui.layout.FixedMetrics = .{};
    for (0..6) |iteration| {
        try h.render(model);
        const frame = &h.frames.committed;
        var measurer = metrics.measurer();
        measurer.generation = if (iteration >= 2) 1 else 0;
        if (iteration >= 2) metrics.advance = 12;
        const constraints: ui.layout.Constraints = .{
            .viewport = .{ .width = if (iteration >= 4) 200 else 300, .height = 180 },
            .rem = if (iteration >= 3) 20 else 16,
        };
        var cached = try ui.layout.calculateWithCache(t.allocator, frame, frame.root.?, constraints, measurer, &cache);
        defer cached.deinit();
        var fresh = try ui.layout.calculate(t.allocator, frame, frame.root.?, constraints, measurer);
        defer fresh.deinit();
        try t.expectEqualSlices(ui.Rect, fresh.bounds, cached.bounds);
    }
    try t.expect(cache.measurement_hits > 0);
    try t.expect(cache.arrangement_hits > 0);
}

const ScopedPanels = struct {
    pub fn render(_: *const ScopedPanels, b: *ui.Ui) !ui.Element {
        const f = b.fluent();
        return f.column().children(.{
            f.column().id(.named("scope-a")).children(.{
                f.row().id(.named("same-key")).cache().children(.{f.text("first")}),
            }),
            f.column().id(.named("scope-b")).children(.{
                f.row().id(.named("same-key")).cache().children(.{f.text("second")}),
            }),
        }).build();
    }
};
test "same cache keys in different logical scopes reuse independently" {
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const h = try app.openWindow(ScopedPanels, .{ .visible = false }, .{});
    _ = try app.step(0);
    const window = try app.window(h);
    window.dirty = true;
    _ = try app.step(1);
    try t.expectEqual(@as(usize, 2), window.scene_cache.hits);
    try t.expectEqual(@as(usize, 2), window.layout_cache.measurement_hits);
    try t.expectEqual(@as(usize, 2), window.layout_cache.arrangement_hits);
    try reference(window);
}

const Stateful = struct {
    pub const LayoutState = u32;
    pub const PrepaintState = void;
    pub fn cacheFingerprint(_: *const Stateful) u64 {
        return 1;
    }
    pub fn requestLayout(_: *Stateful, _: *ui.LayoutCx) !ui.LayoutResult(u32) {
        return .{ .size = .{ .width = 30, .height = 20 }, .state = 42 };
    }
    pub fn prepaint(_: *Stateful, _: *ui.PrepaintCx, _: ui.Rect, state: *u32) !void {
        try t.expectEqual(@as(u32, 42), state.*);
    }
    pub fn paint(_: *Stateful, cx: *ui.PaintCx, rect: ui.Rect, state: *u32, _: *void) !void {
        try t.expectEqual(@as(u32, 42), state.*);
        try cx.painter.fillRect(.{ .bounds = rect, .color = .white });
    }
};
const StatefulView = struct {
    pub fn render(_: *const StatefulView, b: *ui.Ui) !ui.Element {
        return b.fluent().adopt(try b.custom(Stateful, .{}, .{})).id(.named("stateful")).cache().build();
    }
};
test "custom elements with frame-local layout state initialize it on every new frame" {
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const h = try app.openWindow(StatefulView, .{ .visible = false }, .{});
    _ = try app.step(0);
    const window = try app.window(h);
    window.dirty = true;
    _ = try app.step(1);
    try t.expectEqual(@as(usize, 0), window.layout_cache.measurement_hits);
    // A focus change invalidates scene reuse, so the new phase state is read.
    window.dirty = true;
    window.active = false;
    _ = try app.step(2);
    try reference(window);
}

test "scene cache keeps memory bounded as keys disappear" {
    var cache = ui.graphics.SceneCache.init(t.allocator);
    defer cache.deinit();
    for (0..ui.graphics.SceneCache.max_entries + 5) |key| try cache.put(key, 1, .{}, .{}, &.{});
    try t.expect(cache.entries.count() <= ui.graphics.SceneCache.max_entries);
    try t.expect(cache.bytes <= ui.graphics.SceneCache.max_bytes);
}
