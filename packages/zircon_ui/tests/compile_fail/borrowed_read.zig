const std = @import("std");
const ui = @import("zircon_ui");
const Invalid = struct {
    value: u32 = 1,
    fn borrow(self: *const @This()) *const u32 {
        return &self.value;
    }
};
test "borrowed access result is rejected" {
    var app = try ui.App.init(.{ .allocator = std.testing.allocator });
    defer app.deinit();
    _ = try app.read(try app.createEntity(Invalid, .{}), Invalid.borrow, .{});
}
