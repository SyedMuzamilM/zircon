const std = @import("std");
const ui = @import("zircon_ui");
const t = std.testing;
fn builder(h: *ui.testing.Harness) !ui.Ui {
    const state = try h.app.createEntity(struct {}, .{});
    return .{ .frame = try h.frames.begin(), .owner = state.token() };
}
fn calculate(h: *ui.testing.Harness, root: ui.Element, size: ui.Size) !ui.layout.LayoutResult {
    try h.frames.commit(root);
    var metrics: ui.layout.FixedMetrics = .{};
    return ui.layout.calculate(t.allocator, &h.frames.committed, root, .{ .viewport = size }, metrics.measurer());
}
test "rows account for padding gaps and equally shared growth" {
    var h = try ui.testing.Harness.init(t.allocator);
    defer h.deinit();
    var b = try builder(&h);
    const a = try b.div(.{ .width = .{ .px = 20 }, .height = .{ .px = 20 }, .flex_grow = 1 }, &.{});
    const c = try b.div(.{ .width = .{ .px = 20 }, .height = .{ .px = 20 }, .flex_grow = 1 }, &.{});
    const root = try b.row(.{ .padding = ui.Insets.all(10), .gap = 10 }, &.{ a, c });
    var result = try calculate(&h, root, .{ .width = 200, .height = 100 });
    defer result.deinit();
    const ra = try result.get(&h.frames.committed, a);
    const rc = try result.get(&h.frames.committed, c);
    try t.expectApproxEqAbs(@as(f32, 85), ra.width, 0.001);
    try t.expectApproxEqAbs(@as(f32, 105), rc.x, 0.001);
    try t.expectEqual(@as(f32, 10), ra.y);
}
test "growth redistributes after a maximum size freezes one child" {
    var h = try ui.testing.Harness.init(t.allocator);
    defer h.deinit();
    var b = try builder(&h);
    const a = try b.div(.{ .width = .{ .px = 20 }, .max_width = .{ .px = 60 }, .flex_grow = 1 }, &.{});
    const c = try b.div(.{ .width = .{ .px = 20 }, .flex_grow = 1 }, &.{});
    var result = try calculate(&h, try b.row(.{}, &.{ a, c }), .{ .width = 200, .height = 100 });
    defer result.deinit();
    try t.expectEqual(@as(f32, 60), (try result.get(&h.frames.committed, a)).width);
    try t.expectApproxEqAbs(@as(f32, 140), (try result.get(&h.frames.committed, c)).width, 0.001);
}
test "shrink redistributes around minimum widths without negative geometry" {
    var h = try ui.testing.Harness.init(t.allocator);
    defer h.deinit();
    var b = try builder(&h);
    const a = try b.div(.{ .width = .{ .px = 80 }, .min_width = .{ .px = 70 } }, &.{});
    const c = try b.div(.{ .width = .{ .px = 80 }, .min_width = .{ .px = 10 } }, &.{});
    var result = try calculate(&h, try b.row(.{}, &.{ a, c }), .{ .width = 100, .height = 50 });
    defer result.deinit();
    try t.expectEqual(@as(f32, 70), (try result.get(&h.frames.committed, a)).width);
    try t.expectApproxEqAbs(@as(f32, 30), (try result.get(&h.frames.committed, c)).width, 0.001);
}
test "columns honor margins and center alignment on both axes" {
    var h = try ui.testing.Harness.init(t.allocator);
    defer h.deinit();
    var b = try builder(&h);
    const a = try b.div(.{ .width = .{ .px = 40 }, .height = .{ .px = 20 } }, &.{});
    var result = try calculate(&h, try b.column(.{ .padding = ui.Insets.all(10), .align_items = .center, .justify_content = .center }, &.{a}), .{ .width = 100, .height = 100 });
    defer result.deinit();
    const rect = try result.get(&h.frames.committed, a);
    try t.expectEqual(@as(f32, 30), rect.x);
    try t.expectEqual(@as(f32, 40), rect.y);
}
test "percentage and rem lengths resolve in the parent's content box" {
    var h = try ui.testing.Harness.init(t.allocator);
    defer h.deinit();
    var b = try builder(&h);
    const child = try b.div(.{ .width = .{ .percent = 50 }, .height = .{ .rem = 1.5 } }, &.{});
    var result = try calculate(&h, try b.column(.{ .padding = ui.Insets.all(10) }, &.{child}), .{ .width = 200, .height = 100 });
    defer result.deinit();
    const rect = try result.get(&h.frames.committed, child);
    try t.expectEqual(@as(f32, 90), rect.width);
    try t.expectEqual(@as(f32, 24), rect.height);
}
test "text measurement is injected and identical constraints give identical bounds" {
    var h = try ui.testing.Harness.init(t.allocator);
    defer h.deinit();
    var b = try builder(&h);
    const a = try b.text("hello");
    const c = try b.text("é");
    const root = try b.column(.{ .gap = 4, .align_items = .start }, &.{ a, c });
    var first = try calculate(&h, root, .{ .width = 200, .height = 100 });
    defer first.deinit();
    var metrics: ui.layout.FixedMetrics = .{};
    var second = try ui.layout.calculate(t.allocator, &h.frames.committed, root, .{ .viewport = .{ .width = 200, .height = 100 } }, metrics.measurer());
    defer second.deinit();
    try t.expectEqualDeep(first.bounds, second.bounds);
    try t.expectEqual(@as(f32, 40), (try first.get(&h.frames.committed, a)).width);
    try t.expectEqual(@as(f32, 8), (try first.get(&h.frames.committed, c)).width);
    try t.expectEqual(@as(f32, 22), (try first.get(&h.frames.committed, c)).y);
}
test "invalid measurements and arithmetic overflow are reported" {
    var h = try ui.testing.Harness.init(t.allocator);
    defer h.deinit();
    var b = try builder(&h);
    const node = try b.text("test");
    try h.frames.commit(node);
    const Bad = struct {
        fn measure(_: ?*anyopaque, _: []const u8, _: f32) !ui.Size {
            return .{ .width = std.math.nan(f32), .height = 10 };
        }
    };
    try t.expectError(error.InvalidMeasurement, ui.layout.calculate(t.allocator, &h.frames.committed, node, .{ .viewport = .{ .width = 100, .height = 100 } }, .{ .context = null, .text = Bad.measure }));
    var metrics: ui.layout.FixedMetrics = .{};
    try t.expectError(error.InvalidConstraints, ui.layout.calculate(t.allocator, &h.frames.committed, node, .{ .viewport = .{ .width = -1, .height = 100 } }, metrics.measurer()));
    b = try builder(&h);
    const huge = try b.div(.{ .width = .{ .percent = 3.4e38 } }, &.{});
    try h.frames.commit(huge);
    try t.expectError(error.InvalidStyle, ui.layout.calculate(t.allocator, &h.frames.committed, huge, .{ .viewport = .{ .width = 100, .height = 100 } }, metrics.measurer()));
}
test "layout results cannot be reused for another frame epoch" {
    var h = try ui.testing.Harness.init(t.allocator);
    defer h.deinit();
    var b = try builder(&h);
    const old = try b.text("old");
    var result = try calculate(&h, old, .{ .width = 100, .height = 100 });
    defer result.deinit();
    b = try builder(&h);
    const fresh = try b.text("new");
    try h.frames.commit(fresh);
    try t.expectError(error.InvalidFrame, result.get(&h.frames.committed, fresh));
}
test "layout scratch allocation failures release every temporary allocation" {
    try t.checkAllAllocationFailures(t.allocator, allocationCase, .{});
}
fn allocationCase(a: std.mem.Allocator) !void {
    var h = try ui.testing.Harness.init(a);
    defer h.deinit();
    var b = try builder(&h);
    const child = try b.text("size");
    const root = try b.row(.{}, &.{child});
    try h.frames.commit(root);
    var metrics: ui.layout.FixedMetrics = .{};
    var result = try ui.layout.calculate(a, &h.frames.committed, root, .{ .viewport = .{ .width = 100, .height = 100 } }, metrics.measurer());
    defer result.deinit();
}
