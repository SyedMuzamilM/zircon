//! An explicit single-owner move channel for worker results. Taking the value
//! clears the box; task disposal always releases the box and any untaken value.
const std = @import("std");
pub fn Handoff(comptime T: type) type {
    return struct {
        value: ?T,
        allocator: std.mem.Allocator,
        pub fn create(a: std.mem.Allocator, value: T) !*@This() {
            const box = try a.create(@This());
            box.* = .{ .value = value, .allocator = a };
            return box;
        }
        pub fn take(self: *@This()) T {
            const value = self.value.?;
            self.value = null;
            return value;
        }
        pub fn destroy(self: *@This()) void {
            const a = self.allocator;
            if (self.value) |*value| value.deinit();
            a.destroy(self);
        }
    };
}
