const std = @import("std");
const ui = @import("zircon_ui");
const State = struct {
    value: u8 = 1,
    const Wrapped = struct { borrowed: anyerror!*const u8 };
    fn read(self: *const State) Wrapped {
        return .{ .borrowed = &self.value };
    }
};
test "an error union cannot hide a pointer escaping an entity read" {
    var app = try ui.App.init(.{ .allocator = std.testing.allocator });
    defer app.deinit();
    const owner = try app.createEntity(State, .{});
    _ = try app.read(owner, State.read, .{});
}
