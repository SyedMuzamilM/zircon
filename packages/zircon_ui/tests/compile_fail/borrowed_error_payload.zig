const std = @import("std");
const ui = @import("zircon_ui");
const Invalid = struct {
    const Payload = struct { value: anyerror!*const u8 };
    const value: u8 = 1;
    pub fn render(_: *const Invalid, b: *ui.Ui) !ui.Element {
        return b.button(.{ .label = "invalid", .on_click = b.onClickWith(click, .{ .value = &value }) });
    }
    fn click(_: *Invalid, _: *ui.Event(ui.Click), _: *ui.Context(Invalid), _: Payload) void {}
};
test "error-union fields cannot hide a borrowed callback pointer" {
    var h = try ui.testing.Harness.init(std.testing.allocator);
    defer h.deinit();
    try h.render(try h.app.createEntity(Invalid, .{}));
}
