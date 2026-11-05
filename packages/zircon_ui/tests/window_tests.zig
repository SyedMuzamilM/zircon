const std = @import("std");
const ui = @import("zircon_ui");
const t = std.testing;
const Counter = struct {
    count: u32 = 0,
    fail: bool = false,
    alternate: bool = false,
    pub fn render(self: *const Counter, b: *ui.Ui) !ui.Element {
        const label = try b.textFmt("Count {d}", .{self.count});
        const button = try b.key(.{ .string = "increment" }, try b.button(.{ .label = "Increment", .on_click = b.onClick(increment), .style = .{ .height = .{ .px = 40 }, .background = ui.Color.rgb(0x334477) } }));
        if (self.fail) return error.RenderRefused;
        if (self.alternate) return b.column(.{}, &.{ button, label });
        return b.column(.{}, &.{ label, button });
    }
    fn increment(self: *Counter, _: *ui.Event(ui.Click), cx: *ui.Context(Counter)) void {
        self.count += 1;
        cx.notify();
    }
    fn configure(self: *Counter, cx: *ui.Context(Counter), fail: bool, alternate: bool) void {
        self.fail = fail;
        self.alternate = alternate;
        cx.notify();
    }
    fn value(self: *const Counter) u32 {
        return self.count;
    }
};
test "window uses one committed layout scene and input path and remains idle" {
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const handle = try app.openWindow(Counter, .{ .width = 300, .height = 200, .visible = false }, .{});
    const root = try app.windowEntity(Counter, handle);
    try t.expectEqual(@as(usize, 1), try app.step(0));
    const window = try app.window(handle);
    try t.expect(window.frames.committed.scene.items.len >= 3);
    try t.expectEqual(@as(usize, 0), try app.step(0.1));
    try app.dispatch(handle, .{ .pointer_down = .{ .position = .{ .x = 10, .y = 30 } } });
    try app.dispatch(handle, .{ .pointer_up = .{ .position = .{ .x = 10, .y = 30 } } });
    try t.expectEqual(@as(u32, 1), try app.read(root, Counter.value, .{}));
    try t.expectEqual(@as(usize, 1), try app.step(0.2));
    try t.expectEqualStrings("Count 1", window.frames.committed.nodes.items[0].kind.text);
    try t.expectEqual(@as(usize, 0), try app.step(0.3));
    try app.dispatch(handle, .{ .resize = .{ .width = 500, .height = 240 } });
    _ = try app.step(0.4);
    try t.expectEqual(@as(f32, 500), window.frames.committed.bounds[window.frames.committed.root.?.index].width);
}
test "failed window staging retains displayed geometry handlers and keys" {
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const h = try app.openWindow(Counter, .{ .width = 300, .height = 200, .visible = false }, .{});
    const root = try app.windowEntity(Counter, h);
    _ = try app.step(0);
    const w = try app.window(h);
    const epoch = w.frames.committed.epoch;
    const old_items = w.frames.committed.scene.items;
    try app.update(root, Counter.configure, .{ true, false });
    try t.expectError(error.RenderRefused, app.step(0.1));
    try t.expectEqual(epoch, w.frames.committed.epoch);
    try t.expectEqual(old_items.ptr, w.frames.committed.scene.items.ptr);
    try app.dispatch(h, .{ .pointer_down = .{ .position = .{ .x = 10, .y = 30 } } });
    try app.dispatch(h, .{ .pointer_up = .{ .position = .{ .x = 10, .y = 30 } } });
    try t.expectEqual(@as(u32, 1), try app.read(root, Counter.value, .{}));
    try app.update(root, Counter.configure, .{ false, true });
    _ = try app.step(0.2);
    try t.expect(w.focus != null);
    try t.expectEqualStrings("increment", w.frames.committed.nodes.items[w.focus.?].key.?.string);
    try app.dispatch(h, .{ .key_down = .{ .key = .enter } });
    try t.expectEqual(@as(u32, 2), try app.read(root, Counter.value, .{}));
}
test "window handles enforce ownership and closing releases scoped root" {
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    var other = try ui.App.init(.{ .allocator = t.allocator });
    defer other.deinit();
    const h = try app.openWindow(Counter, .{ .visible = false }, .{});
    const root = try app.windowEntity(Counter, h);
    try t.expectError(error.WrongApplication, other.closeWindow(h));
    try app.closeWindow(h);
    try t.expectError(error.WindowNotFound, app.closeWindow(h));
    _ = try app.step(0);
    try t.expectError(error.EntityNotFound, app.read(root, Counter.value, .{}));
}
const Routed = struct {
    log: [16]u8 = @splat(0),
    len: usize = 0,
    pub fn render(_: *const Routed, b: *ui.Ui) !ui.Element {
        const child = try b.listen(try b.key(.{ .string = "child" }, try b.div(.{ .height = .{ .px = 100 } }, &.{})), .{ .on_input = b.onInput(target), .focusable = true });
        return b.listen(try b.column(.{}, &.{child}), .{ .on_capture = b.onInput(capture), .on_input = b.onInput(bubble) });
    }
    fn capture(self: *Routed, _: *ui.Event(ui.Input), _: *ui.Context(Routed)) void {
        self.log[self.len] = 'c';
        self.len += 1;
    }
    fn target(self: *Routed, e: *ui.Event(ui.Input), _: *ui.Context(Routed)) void {
        self.log[self.len] = 't';
        self.len += 1;
        if (e.data == .pointer_down) e.capturePointer();
        if (e.data == .text) e.stopPropagation();
    }
    fn bubble(self: *Routed, _: *ui.Event(ui.Input), _: *ui.Context(Routed)) void {
        self.log[self.len] = 'b';
        self.len += 1;
    }
    fn copy(self: *const Routed, output: *[16]u8) void {
        output.* = self.log;
    }
};
test "input capture target bubble and pointer capture use committed tree" {
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const h = try app.openWindow(Routed, .{ .width = 300, .height = 200, .visible = false }, .{});
    _ = try app.step(0);
    try app.dispatch(h, .{ .pointer_down = .{ .position = .{ .x = 20, .y = 20 } } });
    try app.dispatch(h, .{ .pointer_move = .{ .position = .{ .x = 500, .y = 500 } } });
    const root = try app.windowEntity(Routed, h);
    var log: [16]u8 = undefined;
    try app.read(root, Routed.copy, .{&log});
    try t.expectEqualStrings("ctbctb", log[0..6]);
    try t.expect((try app.window(h)).capture != null);
    try app.dispatch(h, .{ .focus = false });
    try t.expect((try app.window(h)).capture == null);
}
const Drawing = struct {
    pub const LayoutState = u8;
    pub const PrepaintState = ui.Rect;
    pub fn requestLayout(_: *Drawing, _: *ui.LayoutCx) !ui.LayoutResult(u8) {
        return .{ .size = .{ .width = 80, .height = 60 }, .state = 42 };
    }
    pub fn prepaint(_: *Drawing, _: *ui.PrepaintCx, bounds: ui.Rect, state: *u8) !ui.Rect {
        try t.expectEqual(@as(u8, 42), state.*);
        return bounds;
    }
    pub fn paint(_: *Drawing, cx: *ui.PaintCx, bounds: ui.Rect, _: *u8, prepared: *ui.Rect) !void {
        try t.expectEqual(bounds, prepared.*);
        try cx.painter.fillRect(.{ .bounds = bounds, .color = ui.Color.rgb(0xff0000) });
        try cx.painter.pushClip(.{ .x = 10, .y = 10, .width = 20, .height = 20 });
        defer cx.painter.popClip();
        try cx.painter.drawText(.{ .bounds = .{ .width = 80, .height = 60 }, .text = "Custom" });
    }
};
const CustomView = struct {
    pub fn render(_: *const CustomView, b: *ui.Ui) !ui.Element {
        return b.custom(Drawing, .{}, .{});
    }
};
test "custom element executes layout prepaint paint and records clipped scene" {
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const h = try app.openWindow(CustomView, .{ .visible = false, .width = 100, .height = 100 }, .{});
    _ = try app.step(0);
    const items = (try app.window(h)).frames.committed.scene.items;
    try t.expectEqual(@as(usize, 2), items.len);
    try t.expectEqualStrings("Custom", items[1].text);
    try t.expectEqual(@as(f32, 20), items[1].clip.width);
}
const Animated = struct {
    target: f32 = 20,
    pub fn render(self: *const Animated, b: *ui.Ui) !ui.Element {
        return b.div(.{ .width = .{ .px = try b.animate(1, self.target, .{ .tween = .{ .duration = 1, .easing = .linear } }) } }, &.{});
    }
    fn set(self: *Animated, cx: *ui.Context(Animated), target: f32) void {
        self.target = target;
        cx.notify();
    }
};
test "window animation renders final value then stops requesting frames" {
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const h = try app.openWindow(Animated, .{ .visible = false }, .{});
    const root = try app.windowEntity(Animated, h);
    _ = try app.step(0);
    try app.update(root, Animated.set, .{100});
    _ = try app.step(1);
    _ = try app.step(1.5);
    const w = try app.window(h);
    try t.expectApproxEqAbs(@as(f32, 60), w.frames.committed.bounds[0].width, 0.001);
    try t.expectEqual(@as(usize, 1), try app.step(2.5));
    try t.expectEqual(@as(f32, 100), w.frames.committed.bounds[0].width);
    try t.expectEqual(@as(usize, 0), try app.step(3));
}
test "window construction and prepared frames release storage on allocation failure" {
    try t.checkAllAllocationFailures(t.allocator, allocationCase, .{});
}
fn allocationCase(a: std.mem.Allocator) !void {
    var app = try ui.App.init(.{ .allocator = a });
    defer app.deinit();
    _ = try app.openWindow(CustomView, .{ .visible = false }, .{});
    _ = try app.step(0);
}

const PayloadView = struct {
    value: u32 = 0,
    pub fn render(self: *const PayloadView, b: *ui.Ui) !ui.Element {
        var payload: u32 = self.value + 7;
        const button = try b.button(.{ .label = "Choose", .on_click = try b.onClickWith(payload, chosen), .style = .{ .height = .{ .px = 40 } } });
        payload = 999;
        return b.listen(button, .{ .on_input = try b.onInputWith(@as(u32, 9), key), .focusable = true });
    }
    fn chosen(self: *PayloadView, _: *ui.Event(ui.Click), cx: *ui.Context(PayloadView), value: u32) void {
        self.value = value;
        cx.notify();
    }
    fn key(self: *PayloadView, e: *ui.Event(ui.Input), cx: *ui.Context(PayloadView), value: u32) void {
        if (e.data != .key_down) return;
        self.value = value;
        cx.notify();
    }
    fn read(self: *const PayloadView) u32 {
        return self.value;
    }
};
test "typed handler payloads copy immutable values out of the render stack" {
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const h = try app.openWindow(PayloadView, .{ .visible = false, .width = 200, .height = 100 }, .{});
    _ = try app.step(0);
    const root = try app.windowEntity(PayloadView, h);
    try app.dispatch(h, .{ .pointer_down = .{ .position = .{ .x = 10, .y = 10 } } });
    try app.dispatch(h, .{ .pointer_up = .{ .position = .{ .x = 10, .y = 10 } } });
    try t.expectEqual(@as(u32, 7), try app.read(root, PayloadView.read, .{}));
    try app.dispatch(h, .{ .key_down = .{ .key = .a } });
    try t.expectEqual(@as(u32, 9), try app.read(root, PayloadView.read, .{}));
}

const OwnedDrawing = struct {
    dropped: *usize,
    pub const LayoutState = void;
    pub const PrepaintState = void;
    pub fn requestLayout(_: *@This(), _: *ui.LayoutCx) !ui.LayoutResult(void) {
        return .{ .size = .{ .width = 10, .height = 10 }, .state = {} };
    }
    pub fn prepaint(_: *@This(), _: *ui.PrepaintCx, _: ui.Rect, _: *void) !void {}
    pub fn paint(_: *@This(), _: *ui.PaintCx, _: ui.Rect, _: *void, _: *void) !void {}
    pub fn deinit(self: *@This()) void {
        self.dropped.* += 1;
    }
};
test "custom element takes resource ownership only after successful construction" {
    try t.checkAllAllocationFailures(t.allocator, ownedCustomCase, .{});
}
fn ownedCustomCase(a: std.mem.Allocator) !void {
    var h = try ui.testing.Harness.init(a);
    defer h.deinit();
    const owner = try h.app.createEntity(Counter, .{});
    var b: ui.Ui = .{ .frame = try h.frames.begin(), .owner = owner.token() };
    var dropped: usize = 0;
    var resource: OwnedDrawing = .{ .dropped = &dropped };
    const element = b.custom(OwnedDrawing, resource, .{}) catch |err| {
        resource.deinit();
        b.frame.discard();
        try t.expectEqual(@as(usize, 1), dropped);
        return err;
    };
    try h.frames.commit(element);
    h.frames.committed.discard();
    try t.expectEqual(@as(usize, 1), dropped);
}

const ModalView = struct {
    shown: bool = false,
    count: u32 = 0,
    pub fn render(self: *const ModalView, b: *ui.Ui) !ui.Element {
        const base = try b.key(.{ .string = "base" }, try b.button(.{ .label = "Background", .on_click = b.onClick(clicked) }));
        if (!self.shown) return b.stack(.{}, &.{base});
        const first = try b.key(.{ .string = "first" }, try b.button(.{ .label = "First" }));
        const second = try b.autofocus(try b.key(.{ .string = "second" }, try b.button(.{ .label = "Second" })));
        const modal = try b.modal(try b.key(.{ .string = "modal" }, try b.column(.{ .width = .{ .px = 120 }, .height = .{ .px = 100 } }, &.{ first, second })));
        return b.stack(.{ .align_items = .center, .justify_content = .center }, &.{ base, modal });
    }
    fn show(self: *ModalView, cx: *ui.Context(ModalView), enabled: bool) void {
        self.shown = enabled;
        cx.notify();
    }
    fn clicked(self: *ModalView, _: *ui.Event(ui.Click), cx: *ui.Context(ModalView)) void {
        self.count += 1;
        cx.notify();
    }
    fn value(self: *const ModalView) u32 {
        return self.count;
    }
};
test "modal autofocus traps Tab and outside clicks and restores previous focus" {
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const h = try app.openWindow(ModalView, .{ .visible = false, .width = 300, .height = 200 }, .{});
    _ = try app.step(0);
    const root = try app.windowEntity(ModalView, h);
    const w = try app.window(h);
    try t.expectEqualStrings("base", w.frames.committed.nodes.items[w.focus.?].key.?.string);
    try app.update(root, ModalView.show, .{true});
    _ = try app.step(1);
    try t.expectEqualStrings("second", w.frames.committed.nodes.items[w.focus.?].key.?.string);
    try app.dispatch(h, .{ .key_down = .{ .key = .tab } });
    _ = try app.step(2);
    try t.expectEqualStrings("first", w.frames.committed.nodes.items[w.focus.?].key.?.string);
    try app.dispatch(h, .{ .pointer_down = .{ .position = .{ .x = 5, .y = 5 } } });
    try app.dispatch(h, .{ .pointer_up = .{ .position = .{ .x = 5, .y = 5 } } });
    try t.expectEqual(@as(u32, 0), try app.read(root, ModalView.value, .{}));
    try app.update(root, ModalView.show, .{false});
    _ = try app.step(3);
    try t.expectEqualStrings("base", w.frames.committed.nodes.items[w.focus.?].key.?.string);
}
const CloseButton = struct {
    handle: ?ui.WindowHandle = null,
    pub fn render(_: *const CloseButton, b: *ui.Ui) !ui.Element {
        return b.button(.{ .label = "Close", .on_click = b.onClick(close) });
    }
    fn set(self: *CloseButton, cx: *ui.Context(CloseButton), handle: ui.WindowHandle) void {
        self.handle = handle;
        cx.notify();
    }
    fn close(self: *CloseButton, _: *ui.Event(ui.Click), cx: *ui.Context(CloseButton)) !void {
        try cx.app.requestCloseWindow(self.handle.?);
    }
};
test "a root handler can queue close without reborrowing its mutable state" {
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const h = try app.openWindow(CloseButton, .{ .visible = false }, .{});
    const root = try app.windowEntity(CloseButton, h);
    try app.update(root, CloseButton.set, .{h});
    _ = try app.step(0);
    try app.dispatch(h, .{ .key_down = .{ .key = .enter } });
    _ = try app.step(1);
    try t.expectError(error.WindowNotFound, app.window(h));
}

const Clocked = struct {
    pub const LayoutState = void;
    pub const PrepaintState = void;
    pub fn requestLayout(_: *@This(), _: *ui.LayoutCx) !ui.LayoutResult(void) {
        return .{ .size = .{ .width = 100, .height = 100 }, .state = {} };
    }
    pub fn prepaint(_: *@This(), cx: *ui.PrepaintCx, _: ui.Rect, _: *void) !void {
        if (cx.focused) try cx.requestFrameAfter(0.5);
    }
    pub fn paint(_: *@This(), _: *ui.PaintCx, _: ui.Rect, _: *void, _: *void) !void {}
};
const ClockView = struct {
    pub fn render(_: *const ClockView, b: *ui.Ui) !ui.Element {
        return b.listen(try b.custom(Clocked, .{}, .{}), .{ .focusable = true });
    }
};
test "custom deadlines coalesce and stop when the native window loses focus" {
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const h = try app.openWindow(ClockView, .{ .visible = false }, .{});
    try t.expectEqual(@as(usize, 1), try app.step(0));
    try t.expectEqual(@as(usize, 0), try app.step(0.25));
    try t.expectEqual(@as(usize, 1), try app.step(0.5));
    try t.expectEqual(@as(f64, 1), (try app.window(h)).deadline.?);
    try app.dispatch(h, .{ .focus = false });
    _ = try app.step(0.75);
    try t.expect((try app.window(h)).deadline == null);
    try t.expectEqual(@as(usize, 0), try app.step(100));
}

const DimensionsView = struct {
    width: f32 = 0,
    pub fn render(_: *const @This(), b: *ui.Ui) !ui.Element {
        return b.listen(try b.div(.{}, &.{}), .{ .on_input = b.onInput(input) });
    }
    fn input(self: *@This(), e: *ui.Event(ui.Input), _: *ui.Context(@This())) !void {
        self.width = (try e.windowSize()).width;
    }
    fn read(self: *const @This()) f32 {
        return self.width;
    }
};
test "event window geometry uses current logical runtime size after synthetic resize" {
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const h = try app.openWindow(DimensionsView, .{ .visible = false, .width = 200, .height = 100 }, .{});
    _ = try app.step(0);
    try app.dispatch(h, .{ .resize = .{ .width = 500, .height = 300 } });
    _ = try app.step(1);
    try app.dispatch(h, .{ .text = "x" });
    const owner = try app.windowEntity(DimensionsView, h);
    try t.expectEqual(@as(f32, 500), try app.read(owner, DimensionsView.read, .{}));
}
const OwnedWindow = struct {
    releases: *usize,
    pub fn render(_: *const @This(), b: *ui.Ui) !ui.Element {
        return b.text("owned");
    }
    pub fn deinit(self: *@This(), _: std.mem.Allocator) void {
        self.releases.* += 1;
    }
};
test "opening a window transfers entity ownership only on success" {
    try t.checkAllAllocationFailures(t.allocator, ownedWindowCase, .{});
}
fn ownedWindowCase(a: std.mem.Allocator) !void {
    var app = try ui.App.init(.{ .allocator = a });
    defer app.deinit();
    var releases: usize = 0;
    var state: OwnedWindow = .{ .releases = &releases };
    const h = app.openWindow(OwnedWindow, .{ .visible = false }, state) catch |err| {
        state.deinit(a);
        try t.expectEqual(@as(usize, 1), releases);
        return err;
    };
    try app.closeWindow(h);
    _ = try app.step(0);
    try t.expectEqual(@as(usize, 1), releases);
}
