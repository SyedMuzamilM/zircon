//! A display-free application harness. It exercises the real entity runtime.
const std = @import("std");
const app = @import("../app/app.zig");
pub const Harness = struct {
    app: app.App,
    pub fn init(allocator: std.mem.Allocator) !Harness {
        return .{ .app = try app.App.init(.{ .allocator = allocator, .renderer = .headless }) };
    }
    pub fn deinit(h: *Harness) void {
        h.app.deinit();
    }
    pub fn flush(h: *Harness) !bool {
        return h.app.takeFrameRequest();
    }
};
