//! The public App path, driven by real AppKit input, not direct handler calls.
const std = @import("std");
const ui = @import("native").ui;
const native = @import("native");
const objc = native.objc;
const Counter = struct {
    count: u32 = 0,
    pub fn render(self: *const Counter, b: *ui.Ui) !ui.Element {
        return b.column(.{ .padding = ui.Insets.all(20), .gap = 16, .background = ui.Color.rgb(0x171b24) }, &.{
            try b.textFmt("Count {d}", .{self.count}),
            try b.key(.{ .string = "increment" }, try b.button(.{ .label = "Increment", .on_click = b.onClick(increment), .style = .{ .height = .{ .px = 40 }, .padding = ui.Insets.all(10), .background = ui.Color.rgb(0x395bd8), .radius = 6 } })),
        });
    }
    fn increment(self: *Counter, _: *ui.Event(ui.Click), cx: *ui.Context(Counter)) void {
        self.count += 1;
        cx.notify();
    }
    fn value(self: *const Counter) u32 {
        return self.count;
    }
};
test "worker wake interrupts the native idle wait" {
    var app = try ui.App.init(.{ .allocator = std.testing.allocator });
    defer app.deinit();
    _ = try app.openWindow(Counter, .{ .visible = false }, .{});
    _ = try app.step(0);
    for (0..64) |_| try native.window.pump(0);
    var sent = std.atomic.Value(bool).init(false);
    const Worker = struct {
        fn run(flag: *std.atomic.Value(bool)) void {
            std.Io.sleep(std.testing.io, .fromMilliseconds(50), .awake) catch return;
            flag.store(true, .release);
            ui.App.wake();
        }
    };
    const thread = try std.Thread.spawn(.{}, Worker.run, .{&sent});
    defer thread.join();
    const start = native.window.now();
    while (!sent.load(.acquire)) try native.window.pump(0.5);
    try std.testing.expect(native.window.now() - start < 0.3);
}
test "public App native window handles queued click resize snapshot and close" {
    const pool = objc.Pool.init();
    defer pool.deinit();
    var app = try ui.App.init(.{ .allocator = std.testing.allocator });
    defer app.deinit();
    const h = try app.openWindow(Counter, .{ .title = "Zircon runtime test", .width = 420, .height = 280 }, .{});
    const root = try app.windowEntity(Counter, h);
    _ = try app.step(0);
    const nsapp = objc.send(objc.Id, objc.class("NSApplication"), "sharedApplication", .{});
    const list = objc.send(objc.Id, nsapp, "windows", .{});
    const window = objc.send(objc.Id, list, "objectAtIndex:", .{@as(usize, 0)});
    const view = objc.send(objc.Id, window, "contentView", .{});
    const number = objc.send(isize, window, "windowNumber", .{});
    const point = objc.send(objc.CGPoint, view, "convertPoint:toView:", .{ objc.CGPoint{ .x = 40, .y = 70 }, @as(objc.Id, null) });
    for ([_]usize{ 1, 2 }) |kind| {
        const event = objc.send(objc.Id, objc.class("NSEvent"), "mouseEventWithType:location:modifierFlags:timestamp:windowNumber:context:eventNumber:clickCount:pressure:", .{ kind, point, @as(usize, 0), native.window.now(), number, @as(objc.Id, null), @as(isize, 0), @as(isize, 1), @as(f32, 1) });
        objc.send(void, nsapp, "postEvent:atStart:", .{ event, false });
    }
    for (0..256) |_| {
        if (try app.read(root, Counter.value, .{}) == 1) break;
        try native.window.pump(0);
    }
    try std.testing.expectEqual(@as(u32, 1), try app.read(root, Counter.value, .{}));
    _ = try app.step(1);
    const w = try app.window(h);
    try std.testing.expectEqualStrings("Count 1", w.frames.committed.nodes.items[0].kind.text);
    try w.snapshot("/tmp/zircon-counter-runtime.png");
    objc.send(void, window, "setContentSize:", .{objc.CGSize{ .width = 600, .height = 400 }});
    for (0..16) |_| try native.window.pump(0);
    _ = try app.step(2);
    try std.testing.expectEqual(@as(f32, 600), w.dimensions.width);
    objc.send(void, window, "performClose:", .{@as(objc.Id, null)});
    for (0..16) |_| try native.window.pump(0);
    _ = try app.step(3);
    try std.testing.expectError(error.WindowNotFound, app.window(h));
}
