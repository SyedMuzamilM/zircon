//! Text measurement is injected so layout is testable without a font system.
const geometry = @import("geometry.zig");
pub const Measurer = struct {
    context: ?*anyopaque,
    text: *const fn (?*anyopaque, []const u8, f32) anyerror!geometry.Size,
};
/// Deterministic test adapter, explicitly not a production font shaper.
pub const FixedMetrics = struct {
    advance: f32 = 8,
    line_height: f32 = 18,
    pub fn measurer(metrics: *FixedMetrics) Measurer {
        return .{ .context = metrics, .text = measure };
    }
    fn measure(raw: ?*anyopaque, text: []const u8, _: f32) !geometry.Size {
        const metrics: *FixedMetrics = @ptrCast(@alignCast(raw.?));
        var points: usize = 0;
        for (text) |byte| if (byte & 0xc0 != 0x80) {
            points += 1;
        };
        return .{ .width = @as(f32, @floatFromInt(points)) * metrics.advance, .height = metrics.line_height };
    }
};
