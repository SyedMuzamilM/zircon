//! Captured excerpt drags keep advancing while the pointer is outside the page.

const std = @import("std");
const ui = @import("zircon_ui");
pub const Drag = struct {
    point: ui.Point,
    bounds: ui.Rect,
    time: f64,

    pub fn track(previous: ?Drag, point: ui.Point, bounds: ui.Rect, now: f64) ?Drag {
        if (point.y >= bounds.y and point.y < bounds.y + bounds.height) return null;
        return .{ .point = point, .bounds = bounds, .time = if (previous) |drag| drag.time else now };
    }

    pub fn delta(self: *Drag, now: f64) f32 {
        const elapsed = std.math.clamp(now - self.time, 0, 0.05);
        self.time = now;
        const outside = if (self.point.y < self.bounds.y) self.point.y - self.bounds.y else self.point.y - self.bounds.y - self.bounds.height + 1;
        const speed = std.math.clamp(@abs(outside) * 12, 80, 1000);
        return @as(f32, @floatCast(elapsed)) * speed * (if (outside < 0) @as(f32, -1) else 1);
    }
};
