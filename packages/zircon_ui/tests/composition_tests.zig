const std = @import("std");
const ui = @import("zircon_ui");
const t = std.testing;

const Counter = struct {
    count: u32 = 0,
    reverse: bool = false,
    pub fn render(self: *const Counter, b: *ui.Ui) !ui.Element {
        const button = b.button(.{ .key = .named("add"), .label = "Add", .on_click = b.onClickWith(add, .two), .autofocus = true, .style = .{ .width = .pixels(100), .height = .pixels(30) } });
        if (self.reverse) return b.column(.{}, .{ b.text("heading"), button });
        return b.column(.{}, .{ button, b.text("heading") });
    }
    const Amount = enum { two };
    fn add(self: *Counter, _: *ui.Event(ui.Click), cx: *ui.Context(Counter), amount: Amount) void {
        self.count += switch (amount) {
            .two => 2,
        };
        cx.notify();
    }
    fn reorder(self: *Counter, cx: *ui.Context(Counter)) void {
        self.reverse = true;
        cx.notify();
    }
    fn value(self: *const Counter) u32 {
        return self.count;
    }
};

test "fallible tuple buttons infer payloads and keep focus across reorder" {
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const handle = try app.openWindow(Counter, .{ .visible = false, .width = 200, .height = 100 }, .{});
    const owner = try app.windowEntity(Counter, handle);
    _ = try app.step(0);
    try app.dispatch(handle, .{ .key_down = .{ .key = .enter } });
    try t.expectEqual(@as(u32, 2), try app.read(owner, Counter.value, .{}));
    try app.update(owner, Counter.reorder, .{});
    _ = try app.step(1);
    try app.dispatch(handle, .{ .key_down = .{ .key = .enter } });
    try t.expectEqual(@as(u32, 4), try app.read(owner, Counter.value, .{}));
    const window = try app.window(handle);
    try t.expectEqualStrings("add", window.frames.committed.nodes.items[window.focus.?].key.?.string);
}

test "tuples arrays and slices preserve child order and copy their handles" {
    var h = try ui.testing.Harness.init(t.allocator);
    defer h.deinit();
    const owner = try h.app.createEntity(Counter, .{});
    var b: ui.Ui = .{ .frame = try h.frames.begin(), .owner = owner.token() };
    const plain = try b.text("one");
    const tuple = try b.column(.{}, .{ plain, b.styled(b.text("two"), .{ .text = .{ .size = 20 } }) });
    const array = [_]anyerror!ui.Element{ b.text("three"), b.text("four") };
    const from_array = try b.row(.{}, array);
    var dynamic: []const anyerror!ui.Element = &.{ b.text("five"), b.text("six") };
    const from_slice = try b.stack(.{}, dynamic);
    dynamic = &.{};
    const root = try b.column(.{}, .{ tuple, from_array, from_slice });
    try h.frames.commit(root);
    const frame = &h.frames.committed;
    const first_children = (try frame.get(tuple)).children;
    try t.expectEqualStrings("one", frame.nodes.items[first_children[0]].kind.text);
    try t.expectEqualStrings("two", frame.nodes.items[first_children[1]].kind.text);
    const last_children = (try frame.get(from_slice)).children;
    try t.expectEqualStrings("five", frame.nodes.items[last_children[0]].kind.text);
    try t.expectEqualStrings("six", frame.nodes.items[last_children[1]].kind.text);
}

test "heap-backed pointer arrays normalize without recursion or a large stack copy" {
    var h = try ui.testing.Harness.init(t.allocator);
    defer h.deinit();
    const owner = try h.app.createEntity(Counter, .{});
    var b: ui.Ui = .{ .frame = try h.frames.begin(), .owner = owner.token() };
    const children = try t.allocator.create([600_000]ui.Element);
    defer t.allocator.destroy(children);
    const child = try b.text("child");
    @memset(children, child);
    // Validation should reject the first duplicate, rather than recursively
    // re-entering normalization or copying this heap allocation to the stack.
    try t.expectError(error.DuplicateChild, b.column(.{}, children));
    try t.expect((try b.frame.get(child)).parent == null);
}

test "a failed child or handler never parents earlier successful children" {
    var h = try ui.testing.Harness.init(t.allocator);
    defer h.deinit();
    const owner = try h.app.createEntity(Counter, .{});
    var b: ui.Ui = .{ .frame = try h.frames.begin(), .owner = owner.token() };
    const child = try b.text("available");
    const failed: anyerror!ui.Element = error.ChildFailed;
    try t.expectError(error.ChildFailed, b.column(.{}, .{ child, failed, b.text("later") }));
    try t.expect((try b.frame.get(child)).parent == null);
    try t.expectError(error.HandlerFailed, b.button(.{ .label = "failed", .on_click = error.HandlerFailed, .children = &.{child} }));
    try t.expect((try b.frame.get(child)).parent == null);
    try t.expectError(error.DuplicateChild, b.row(.{}, .{ child, child }));
    try t.expect((try b.frame.get(child)).parent == null);
    _ = try b.row(.{}, .{child});
}

const Cleanup = struct {
    destroyed: *usize,
    pub const LayoutState = void;
    pub const PrepaintState = void;
    pub fn requestLayout(_: *Cleanup, _: *ui.LayoutCx) !ui.LayoutResult(void) {
        return .{ .size = .{ .width = 5, .height = 5 }, .state = {} };
    }
    pub fn prepaint(_: *Cleanup, _: *ui.PrepaintCx, _: ui.Rect, _: *void) !void {}
    pub fn paint(_: *Cleanup, _: *ui.PaintCx, _: ui.Rect, _: *void, _: *void) !void {}
    pub fn deinit(self: *Cleanup) void {
        self.destroyed.* += 1;
    }
};
const FailingView = struct {
    destroyed: *usize,
    fail: bool = false,
    clicks: usize = 0,
    pub fn render(self: *const FailingView, b: *ui.Ui) !ui.Element {
        const failed: anyerror!ui.Element = if (self.fail) error.ChildFailed else b.text("ready");
        return b.column(.{}, .{
            b.button(.{ .label = "kept", .on_click = b.onClick(click) }),
            failed,
            b.custom(Cleanup, .{ .destroyed = self.destroyed }, .{}),
        });
    }
    fn click(self: *FailingView, _: *ui.Event(ui.Click), cx: *ui.Context(FailingView)) void {
        self.clicks += 1;
        cx.notify();
    }
    fn failNext(self: *FailingView, cx: *ui.Context(FailingView)) void {
        self.fail = true;
        cx.notify();
    }
    fn count(self: *const FailingView) usize {
        return self.clicks;
    }
};
test "later eager custom children release once on failure while committed handlers survive" {
    var destroyed: usize = 0;
    {
        var h = try ui.testing.Harness.init(t.allocator);
        defer h.deinit();
        const owner = try h.app.createEntity(FailingView, .{ .destroyed = &destroyed });
        try h.render(owner);
        const epoch = h.frames.committed.epoch;
        const handler = h.frames.committed.nodes.items[1].kind.button.on_click.?;
        try h.app.update(owner, FailingView.failNext, .{});
        try t.expectError(error.ChildFailed, h.render(owner));
        try t.expectEqual(@as(usize, 1), destroyed);
        try t.expectEqual(epoch, h.frames.committed.epoch);
        var click: ui.Event(ui.Click) = .{ .data = .{} };
        try handler.dispatch(&h.app, &click);
        try t.expectEqual(@as(usize, 1), try h.app.read(owner, FailingView.count, .{}));
    }
    try t.expectEqual(@as(usize, 2), destroyed);
}

fn allocationCase(allocator: std.mem.Allocator) !void {
    var h = try ui.testing.Harness.init(allocator);
    defer h.deinit();
    const owner = try h.app.createEntity(Counter, .{});
    try h.render(owner);
}
test "compact composition keeps allocation failure cleanup" {
    try t.checkAllAllocationFailures(t.allocator, allocationCase, .{});
}
