//! A real native application. Windowing, input, layout, fonts and Metal remain
//! framework responsibilities; the application owns only its entity and view.
const std = @import("std");
const ui = @import("zircon_ui");
const Counter = struct {
    count: u32 = 0,
    pub fn render(self: *const Counter, b: *ui.Ui) !ui.Element {
        const heading = try b.styled(try b.text("Zircon UI"), .{ .text = .{ .size = 26 } });
        const button = try b.key(.{ .string = "increment" }, try b.button(.{ .label = "Increment", .on_click = b.onClick(increment), .style = .{ .height = .{ .px = 42 }, .padding = ui.Insets.all(12), .radius = 7, .background = ui.Color.rgb(0x395bd8) } }));
        const animated_width = try b.animate(1, 30 + @as(f32, @floatFromInt(self.count % 8)) * 35, .{ .spring = .{} });
        return b.column(.{ .padding = ui.Insets.all(28), .gap = 18, .background = ui.Color.rgb(0x171b24) }, &.{ heading, try b.textFmt("Count: {d}", .{self.count}), button, try b.div(.{ .width = .{ .px = animated_width }, .height = .{ .px = 5 }, .radius = 2, .background = ui.Color.rgb(0x72b8f2) }, &.{}) });
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
