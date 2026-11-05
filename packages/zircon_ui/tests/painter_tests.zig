const std = @import("std");
const ui = @import("zircon_ui");
const t = std.testing;
test "painter copies UTF8 applies nested clipping opacity and rejects invalid commands" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var painter = try ui.graphics.Painter.init(arena.allocator(), .{ .width = 100, .height = 100 });
    painter.opacity = 0.5;
    try painter.pushClip(.{ .x = 10, .y = 10, .width = 40, .height = 40 });
    try painter.pushClip(.{ .x = 20, .y = 0, .width = 50, .height = 30 });
    var text = [_]u8{ 't', 'e', 'x', 't' };
    try painter.drawText(.{ .bounds = .{ .width = 100, .height = 100 }, .text = &text });
    @memset(&text, 'x');
    try t.expectError(error.UnbalancedClip, painter.finish(.black));
    painter.popClip();
    painter.popClip();
    try painter.fillRect(.{ .bounds = .{ .x = 200, .y = 200, .width = 10, .height = 10 }, .color = .white });
    try t.expectError(error.InvalidDrawCommand, painter.fillRect(.{ .bounds = .{ .width = -1 }, .color = .white }));
    try t.expectError(error.InvalidUtf8, painter.drawText(.{ .bounds = .{ .width = 10, .height = 10 }, .text = "\xff" }));
    const scene = try painter.finish(.black);
    try t.expectEqual(@as(usize, 1), scene.items.len);
    try t.expectEqualStrings("text", scene.items[0].text);
    try t.expectEqual(@as(f32, 0.5), scene.items[0].color.a);
    try t.expectEqual(ui.Rect{ .x = 20, .y = 10, .width = 30, .height = 20 }, scene.items[0].clip);
}
const Overlay = struct {
    value: u32 = 0,
    pub fn render(_: *const Overlay, b: *ui.Ui) !ui.Element {
        return b.stack(.{ .align_items = .center, .justify_content = .center }, &.{
            try b.button(.{ .label = "Background", .on_click = b.onClick(base), .style = .{ .background = ui.Color.rgb(0xff0000) } }),
            try b.button(.{ .label = "Dialog", .on_click = b.onClick(dialog), .style = .{ .width = .{ .px = 100 }, .height = .{ .px = 40 }, .background = ui.Color.rgb(0x0000ff) } }),
        });
    }
    fn base(self: *Overlay, _: *ui.Event(ui.Click), cx: *ui.Context(Overlay)) void {
        self.value = 1;
        cx.notify();
    }
    fn dialog(self: *Overlay, _: *ui.Event(ui.Click), cx: *ui.Context(Overlay)) void {
        self.value = 2;
        cx.notify();
    }
    fn read(self: *const Overlay) u32 {
        return self.value;
    }
};
test "stack layers share layout bounds and dispatch to the last painted hit" {
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const h = try app.openWindow(Overlay, .{ .visible = false, .width = 300, .height = 200 }, .{});
    _ = try app.step(0);
    const w = try app.window(h);
    try t.expectEqual(ui.Rect{ .x = 100, .y = 80, .width = 100, .height = 40 }, w.frames.committed.bounds[1]);
    try app.dispatch(h, .{ .pointer_down = .{ .position = .{ .x = 150, .y = 100 } } });
    try app.dispatch(h, .{ .pointer_up = .{ .position = .{ .x = 150, .y = 100 } } });
    const root = try app.windowEntity(Overlay, h);
    try t.expectEqual(@as(u32, 2), try app.read(root, Overlay.read, .{}));
}
