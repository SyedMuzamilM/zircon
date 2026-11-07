//! A real native application. Windowing, input, layout, fonts and Metal remain
//! framework responsibilities; the application owns only its entity and view.
const std = @import("std");
const ui = @import("zircon_ui");
const Counter = struct {
    count: u32 = 0,
    pub fn render(self: *const Counter, b: *ui.Ui) !ui.Element {
        const animated_width = try b.animate(1, 30 + @as(f32, @floatFromInt(self.count % 8)) * 35, .{ .spring = .{} });
        return b.column(.{ .padding = .all(28), .gap = 18, .background = .rgb(0x171b24) }, .{
            b.styled(b.text("Zircon UI"), .{ .text = .{ .size = 26 } }),
            b.textFmt("Count: {d}", .{self.count}),
            b.button(.{ .key = .named("increment"), .label = "Increment", .on_click = b.onClick(increment), .style = .{ .height = .pixels(42), .padding = .all(12), .radius = 7, .background = .rgb(0x395bd8) } }),
            b.div(.{ .width = .pixels(animated_width), .height = .pixels(5), .radius = 2, .background = .rgb(0x72b8f2) }, .{}),
        });
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
