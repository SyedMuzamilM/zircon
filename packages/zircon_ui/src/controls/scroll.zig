//! Scroll math shared by custom controls and virtualized editor content. The
//! window supplies wheel events; models retain offsets rather than frame nodes.
const std = @import("std");
pub const Scroll = struct {
    offset: f32 = 0,
    pub fn clamp(self: *Scroll, content: f32, viewport: f32) void {
        self.offset = std.math.clamp(self.offset, 0, @max(0, content - viewport));
    }
    pub fn wheel(self: *Scroll, delta: f32, content: f32, viewport: f32) void {
        if (!std.math.isFinite(delta)) return;
        self.offset -= delta;
        self.clamp(content, viewport);
    }
    pub fn reveal(self: *Scroll, start: f32, end: f32, content: f32, viewport: f32) void {
        if (start < self.offset) self.offset = start;
        if (end > self.offset + viewport) self.offset = end - viewport;
        self.clamp(content, viewport);
    }
};
pub const VisibleRows = struct { start: usize, end: usize, top: f32, total_height: f32 };
/// Returns a half-open range including overscan. Work scales with the visible
/// rows; callers keep document indexing outside the frame builder.
pub fn visibleRows(count: usize, height: f32, offset: f32, viewport: f32, overscan: usize) !VisibleRows {
    if (!std.math.isFinite(height) or height <= 0 or !std.math.isFinite(offset) or !std.math.isFinite(viewport) or offset < 0 or viewport < 0) return error.InvalidViewport;
    const total = @as(f32, @floatFromInt(count)) * height;
    if (!std.math.isFinite(total)) return error.InvalidViewport;
    const clamped = @min(offset, total);
    const first: usize = @intFromFloat(@floor(clamped / height));
    const visible: usize = @intFromFloat(@ceil(@min(viewport, total) / height));
    const start = first -| overscan;
    const end = @min(count, first +| visible +| overscan +| 1);
    return .{ .start = start, .end = end, .top = @as(f32, @floatFromInt(start)) * height - offset, .total_height = total };
}
