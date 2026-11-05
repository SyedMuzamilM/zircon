const std = @import("std");
const ui = @import("zircon_ui");
const t = std.testing;
const Inbox = struct {
    pending: *std.atomic.Value(bool),
    drains: *usize,
    value: u32 = 0,
    fn drain(self: *Inbox, cx: *ui.Context(Inbox)) void {
        self.drains.* += 1;
        if (self.pending.swap(false, .acq_rel)) {
            self.value += 1;
            cx.notify();
        }
    }
    fn read(self: *const Inbox) u32 {
        return self.value;
    }
};
test "external inbox deduplicates registration and retires destroyed recipient" {
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    var pending = std.atomic.Value(bool).init(false);
    var drains: usize = 0;
    const owner = try app.createEntity(Inbox, .{ .pending = &pending, .drains = &drains });
    try app.watchExternal(owner, Inbox.drain);
    try app.watchExternal(owner, Inbox.drain);
    _ = try app.step(0);
    try t.expectEqual(@as(usize, 1), drains);
    pending.store(true, .release);
    ui.App.wake();
    _ = try app.step(1);
    try t.expectEqual(@as(u32, 1), try app.read(owner, Inbox.read, .{}));
    try app.destroyEntity(owner);
    _ = try app.step(2);
    try t.expectEqual(@as(usize, 2), drains);
}
