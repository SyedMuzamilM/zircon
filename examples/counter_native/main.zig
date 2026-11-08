//! A real native application. Windowing, input, layout, fonts and Metal remain
//! framework responsibilities; the application owns only its entity and view.
const std = @import("std");
const ui = @import("zircon_ui");
const Counter = struct {
    count: u32 = 0,
    pub fn render(self: *const Counter, b: *ui.Ui) !ui.Element {
        const animated_width = try b.animate(1, 30 + @as(f32, @floatFromInt(self.count % 8)) * 35, .{ .spring = .{} });
        const f = b.fluent();
        return f.div().flex_col().p(7).gap_px(18).bg(.rgb(0x171b24))
            .child(f.text("Zircon UI").text_size(26))
            .child(f.textFmt("Count: {d}", .{self.count}))
            .child(f.button(.{ .label = "Increment" }).id(.named("increment"))
                .h_px(42).p_3().rounded_px(7).bg(.rgb(0x395bd8))
                .on_click(b.onClick(increment)))
            .child(f.div().w_px(animated_width).h_px(5).rounded_px(2).bg(.rgb(0x72b8f2)))
            .build();
    }
    fn increment(self: *Counter, _: *ui.Event(ui.Click), cx: *ui.Context(Counter)) void {
        self.count += 1;
        cx.notify();
    }
};
pub fn main(init: std.process.Init) !void {
    var app = try ui.App.init(.{ .allocator = init.gpa });
    defer app.deinit();
    _ = try app.openWindow(Counter, .{ .title = "Zircon UI · Counter", .width = 420, .height = 320 }, .{});
    try app.run();
}
