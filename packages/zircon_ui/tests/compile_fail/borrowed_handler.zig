const std = @import("std");
const ui = @import("zircon_ui");
const Invalid = struct {
    pub fn render(_: *const Invalid, b: *ui.Ui) !ui.Element {
        return b.button(.{ .label = "invalid", .on_click = b.onClickWith(click, @as(*const u8, &value)) });
    }
    const value: u8 = 1;
    fn click(_: *Invalid, _: *ui.Event(ui.Click), _: *ui.Context(Invalid), _: *const u8) void {}
};
test "callback inference still rejects borrowed payloads" {
    var h = try ui.testing.Harness.init(std.testing.allocator);
    defer h.deinit();
    try h.render(try h.app.createEntity(Invalid, .{}));
}
