const std = @import("std");
const ui = @import("zircon_ui");
const t = std.testing;
const View = struct {
    count: u32 = 0,
    fail: bool = false,
    pub fn render(self: *const View, b: *ui.Ui) !ui.Element {
        const f = b.fluent();
        const child: anyerror!ui.Element = if (self.fail) error.ChildFailed else b.text("kept");
        return f.div().p_4().gap_2().bg(.rgb(0x123456))
            .child(f.button(.{ .label = "Add", .autofocus = true }).id(.named("add")).h_px(30).on_click(b.onClickWith(add, @as(u32, 2))))
            .child(child).build();
    }
    fn add(self: *View, _: *ui.Event(ui.Click), cx: *ui.Context(View), amount: u32) void {
        self.count += amount;
        cx.notify();
    }
    fn failNext(self: *View, cx: *ui.Context(View)) void {
        self.fail = true;
        cx.notify();
    }
    fn value(self: *const View) u32 {
        return self.count;
    }
};

test "fluent typed events and failed frames preserve committed handlers" {
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const handle = try app.openWindow(View, .{ .visible = false, .width = 200, .height = 100 }, .{});
    const owner = try app.windowEntity(View, handle);
    _ = try app.step(0);
    try app.dispatch(handle, .{ .key_down = .{ .key = .enter } });
    try t.expectEqual(@as(u32, 2), try app.read(owner, View.value, .{}));
    try app.update(owner, View.failNext, .{});
    try t.expectError(error.ChildFailed, app.step(1));
    try app.dispatch(handle, .{ .key_down = .{ .key = .enter } });
    try t.expectEqual(@as(u32, 4), try app.read(owner, View.value, .{}));
}

test "fluent copies alias one draft and build is idempotent with atomic parenting" {
    var h = try ui.testing.Harness.init(t.allocator);
    defer h.deinit();
    const owner = try h.app.createEntity(View, .{});
    var b: ui.Ui = .{ .frame = try h.frames.begin(), .owner = owner.token() };
    const f = b.fluent();
    const parent = f.div().p(4).px_px(5);
    const alias = parent;
    const first = try b.text("first");
    _ = alias.child(first);
    const second = f.text("second").text_size(20);
    _ = parent.child(second);
    try t.expect((try b.frame.get(first)).parent == null);
    const element = try parent.build();
    try t.expectEqual(element, try alias.build());
    const node = try b.frame.get(element);
    try t.expectEqual(@as(usize, 2), node.children.len);
    try t.expectEqual(@as(f32, 5), node.style.padding.left);
    try t.expectEqual(@as(f32, 16), node.style.padding.top);
    try h.frames.commit(element);
}

test "fluent mixed child collections copy text and retain exact order" {
    var h = try ui.testing.Harness.init(t.allocator);
    defer h.deinit();
    const owner = try h.app.createEntity(View, .{});
    var b: ui.Ui = .{ .frame = try h.frames.begin(), .owner = owner.token() };
    const f = b.fluent();
    var local = [_]u8{ 'c', 'o', 'p', 'y' };
    const copied = f.text(&local);
    @memset(&local, 'x');
    const raw = [_]anyerror!ui.Element{ b.text("two"), b.text("three") };
    const root = try f.div().child(copied).children(&raw).children(.{ f.text("four"), b.text("five") }).build();
    try h.frames.commit(root);
    const frame = &h.frames.committed;
    const node = try frame.get(root);
    for ([_][]const u8{ "copy", "two", "three", "four", "five" }, node.children) |expected, index| try t.expectEqualStrings(expected, frame.nodes.items[index].kind.text);
}

test "fluent errors cannot be ignored and stale builders cannot poison a new epoch" {
    var h = try ui.testing.Harness.init(t.allocator);
    defer h.deinit();
    const owner = try h.app.createEntity(View, .{});
    var b: ui.Ui = .{ .frame = try h.frames.begin(), .owner = owner.token() };
    const f = b.fluent();
    const stale = f.text("old");
    const parent = f.div();
    _ = parent.child(parent);
    try t.expectError(error.CyclicElement, parent.build());
    try t.expectError(error.CyclicElement, h.frames.commit(try b.text("fallback")));
    b.frame = try h.frames.begin();
    try t.expectError(error.InvalidFrame, stale.build());
    try h.frames.commit(try b.fluent().div().child(b.text("fresh")).build());
}

test "fluent duplicate or finished mutation refuses a frame without partial links" {
    var h = try ui.testing.Harness.init(t.allocator);
    defer h.deinit();
    const owner = try h.app.createEntity(View, .{});
    var b: ui.Ui = .{ .frame = try h.frames.begin(), .owner = owner.token() };
    var f = b.fluent();
    const child = try b.text("unparented");
    const parent = f.div().child(child).child(child);
    try t.expectError(error.DuplicateChild, parent.build());
    try t.expect((try b.frame.get(child)).parent == null);
    b.frame = try h.frames.begin();
    f = b.fluent();
    const finished = f.div();
    const root = try finished.build();
    _ = finished.bg(.white);
    try t.expectError(error.BuilderFinished, h.frames.commit(root));
}

test "discard invalidates fluent storage until a fresh frame epoch begins" {
    var h = try ui.testing.Harness.init(t.allocator);
    defer h.deinit();
    const owner = try h.app.createEntity(View, .{});
    var b: ui.Ui = .{ .frame = try h.frames.begin(), .owner = owner.token() };
    const stale = b.fluent().text("old");
    b.frame.discard();
    try t.expectError(error.InvalidFrame, b.text("not active"));
    try t.expectError(error.InvalidFrame, stale.build());
    b.frame = try h.frames.begin();
    const fresh = b.fluent().text("new");
    _ = stale.text_size(99);
    const element = try fresh.build();
    try t.expectEqual(@as(f32, 14), (try b.frame.get(element)).style.text.size);
    try h.frames.commit(element);
}

test "fluent final style validation preserves precedence and conditional typed values" {
    var h = try ui.testing.Harness.init(t.allocator);
    defer h.deinit();
    const owner = try h.app.createEntity(View, .{});
    var b: ui.Ui = .{ .frame = try h.frames.begin(), .owner = owner.token() };
    const f = b.fluent();
    const node = try f.div().w(.pixels(42)).gap_px(-1).gap_2()
        .when(false, .{ .opacity = @as(f32, -1) })
        .when(true, .{ .overflow = .hidden }).build();
    const style = (try b.frame.get(node)).style;
    try t.expectEqual(@as(f32, 42), style.width.px);
    try t.expectEqual(@as(f32, 8), style.gap);
    try t.expectEqual(@as(f32, 1), style.opacity);
    try t.expectEqual(.hidden, style.overflow);
    try t.expectError(error.InvalidStyle, f.div().opacity(-1).build());
}

const Cleanup = struct {
    destroyed: *usize,
    pub const LayoutState = void;
    pub const PrepaintState = void;
    pub fn requestLayout(_: *Cleanup, _: *ui.LayoutCx) !ui.LayoutResult(void) {
        return .{ .size = .{ .width = 1, .height = 1 }, .state = {} };
    }
    pub fn prepaint(_: *Cleanup, _: *ui.PrepaintCx, _: ui.Rect, _: *void) !void {}
    pub fn paint(_: *Cleanup, _: *ui.PaintCx, _: ui.Rect, _: *void, _: *void) !void {}
    pub fn deinit(self: *Cleanup) void {
        self.destroyed.* += 1;
    }
};
test "later owning custom children retire exactly once after a fluent failure" {
    var h = try ui.testing.Harness.init(t.allocator);
    defer h.deinit();
    const owner = try h.app.createEntity(View, .{});
    var b: ui.Ui = .{ .frame = try h.frames.begin(), .owner = owner.token() };
    const f = b.fluent();
    var destroyed: usize = 0;
    const failed: anyerror!ui.Element = error.ChildFailed;
    const root = f.div().children(.{ failed, b.custom(Cleanup, .{ .destroyed = &destroyed }, .{}) });
    try t.expectError(error.ChildFailed, root.build());
    try t.expectEqual(@as(usize, 0), destroyed);
    _ = try h.frames.begin();
    try t.expectEqual(@as(usize, 1), destroyed);
}

fn allocationCase(a: std.mem.Allocator) !void {
    var h = try ui.testing.Harness.init(a);
    defer h.deinit();
    const owner = try h.app.createEntity(View, .{});
    try h.render(owner);
}
test "fluent allocation errors propagate without leaking draft resources" {
    try t.checkAllAllocationFailures(t.allocator, allocationCase, .{});
}
