const std = @import("std");
const ui = @import("zircon_ui");
const t = std.testing;
const State = struct {
    value: u32 = 0,
    fn complete(self: *State, cx: *ui.Context(State), result: anyerror!u32) !void {
        self.value = try result;
        cx.notify();
    }
    fn read(self: *const State) u32 {
        return self.value;
    }
};
const Job = struct {
    pub const Output = u32;
    finished: *std.atomic.Value(bool),
    disposed: *u32,
    wait: bool = false,
    pub fn run(self: *Job, cancel: *ui.tasks.Cancellation) !u32 {
        defer self.finished.store(true, .release);
        if (self.wait) {
            while (!cancel.isCanceled()) std.atomic.spinLoopHint();
            try cancel.check();
        }
        return 42;
    }
    pub fn discard(self: *Job, _: u32) void {
        self.disposed.* += 1;
    }
};
test "entity-owned worker completes through a fresh UI update and discards output" {
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const owner = try app.createEntity(State, .{});
    var finished = std.atomic.Value(bool).init(false);
    var disposed: u32 = 0;
    _ = try app.spawn(owner, Job, .{ .finished = &finished, .disposed = &disposed }, State.complete);
    while (try app.tasksPending()) {
        _ = try app.step(0);
        std.atomic.spinLoopHint();
    }
    try t.expectEqual(@as(u32, 42), try app.read(owner, State.read, .{}));
    try t.expectEqual(@as(u32, 1), disposed);
}
test "destroying a task owner cancels its worker and suppresses completion" {
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const owner = try app.createEntity(State, .{});
    var finished = std.atomic.Value(bool).init(false);
    var disposed: u32 = 0;
    _ = try app.spawn(owner, Job, .{ .finished = &finished, .disposed = &disposed, .wait = true }, State.complete);
    try app.destroyEntity(owner);
    while (!finished.load(.acquire)) std.atomic.spinLoopHint();
    while (try app.tasksPending()) {
        _ = try app.step(0);
        std.atomic.spinLoopHint();
    }
    try t.expectEqual(@as(u32, 0), disposed);
}
