//! A display-free application harness. It exercises the real entity runtime.
const std = @import("std");
const app = @import("../app/app.zig");
const tree = @import("../ui/tree.zig");
const builder = @import("../ui/ui.zig");
pub const Harness = struct {
    app: app.App,
    frames: tree.Frames,
    pub fn init(allocator: std.mem.Allocator) !Harness {
        var runtime = try app.App.init(.{ .allocator = allocator });
        errdefer runtime.deinit();
        return .{ .app = runtime, .frames = try tree.Frames.init(allocator) };
    }
    pub fn deinit(h: *Harness) void {
        h.frames.deinit();
        h.app.deinit();
    }
    pub fn render(h: *Harness, handle: anytype) !void {
        const staging = try h.frames.begin();
        errdefer staging.discard();
        const root = try builder.render(&h.app, handle, staging);
        try h.frames.commit(root);
    }
    pub fn flush(h: *Harness) !bool {
        return h.app.takeFrameRequest();
    }
};
