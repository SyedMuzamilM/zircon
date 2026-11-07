const std = @import("std");
const ui = @import("zircon_ui");
const Invalid = struct {
    pub fn render(_: *const Invalid, b: *ui.Ui) !ui.Element {
        return b.column(.{}, .{ b.text("valid"), 42 });
    }
};
test "a child must be an element or fallible element" {
    var h = try ui.testing.Harness.init(std.testing.allocator);
    defer h.deinit();
    try h.render(try h.app.createEntity(Invalid, .{}));
}
