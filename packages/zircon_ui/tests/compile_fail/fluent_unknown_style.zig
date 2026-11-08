const std = @import("std");
const ui = @import("zircon_ui");
const Invalid = struct {
    pub fn render(_: *const Invalid, b: *ui.Ui) !ui.Element {
        return b.fluent().div().when(false, .{ .not_a_style = 1 }).build();
    }
};
test "false condition still checks style field names" {
    var h = try ui.testing.Harness.init(std.testing.allocator);
    defer h.deinit();
    try h.render(try h.app.createEntity(Invalid, .{}));
}
