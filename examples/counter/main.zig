//! Inspect the declarative counter without opening a native window.
const std = @import("std");
const ui = @import("zircon_ui");
const Counter = struct {
    count: u32 = 0,
    pub fn render(self: *const Counter, builder: *ui.Ui) !ui.Element {
        return builder.column(.{ .gap = 12, .padding = ui.Insets.all(24) }, &.{
            try builder.textFmt("Count: {d}", .{self.count}),
            try builder.button(.{ .label = "Increment", .on_click = builder.onClick(increment) }),
        });
    }
    fn increment(self: *Counter, event: *ui.Event(ui.Click), cx: *ui.Context(Counter)) void {
        _ = event;
        self.count += 1;
        cx.notify();
    }
};
pub fn main(init: std.process.Init) !void {
    var harness = try ui.testing.Harness.init(init.gpa);
    defer harness.deinit();
    const counter = try harness.app.createEntity(Counter, .{});
    try harness.render(counter);
    const frame = &harness.frames.committed;
    std.debug.print("Headless counter: {d} frame-owned nodes\n", .{frame.nodes.items.len});
    for (frame.nodes.items) |node| switch (node.kind) {
        .text => |text| std.debug.print("text: {s}\n", .{text}),
        .button => |button| std.debug.print("button: {s}\n", .{button.label}),
        .container => {},
    };
}
