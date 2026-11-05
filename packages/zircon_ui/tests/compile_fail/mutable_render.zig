const std = @import("std");
const ui = @import("zircon_ui");
const Invalid = struct {
    pub fn render(_: *@This(), _: *ui.Ui) !ui.Element {
        return error.NeverCalled;
    }
};
test "mutable render is rejected" {
    var harness = try ui.testing.Harness.init(std.testing.allocator);
    defer harness.deinit();
    try harness.render(try harness.app.createEntity(Invalid, .{}));
}
