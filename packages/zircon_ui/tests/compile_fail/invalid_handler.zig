const std = @import("std");
const ui = @import("zircon_ui");
const Invalid = struct {
    pub fn render(_: *const @This(), builder: *ui.Ui) !ui.Element {
        return builder.button(.{ .label = "Bad", .on_click = builder.onClick(click) });
    }
    fn click(_: *@This()) void {}
};
test "invalid handler contract is rejected" {
    var harness = try ui.testing.Harness.init(std.testing.allocator);
    defer harness.deinit();
    try harness.render(try harness.app.createEntity(Invalid, .{}));
}
