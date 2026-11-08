//! Text measurement is injected so layout is testable without a font system.
const text_style = @import("../text/style.zig");
const geometry = @import("geometry.zig");
pub const Measurer = struct {
    /// Changes whenever resolved fonts or text metrics change.
    generation: u64 = 0,
    context: ?*anyopaque,
    text: *const fn (?*anyopaque, []const u8, text_style.TextStyle) anyerror!geometry.Size,
    caret_fn: ?*const fn (?*anyopaque, []const u8, text_style.TextStyle, usize) f32 = null,
    index_fn: ?*const fn (?*anyopaque, []const u8, text_style.TextStyle, f32) usize = null,
    pub fn caret(m: Measurer, bytes: []const u8, style: text_style.TextStyle, offset: usize) f32 {
        if (m.caret_fn) |f| return f(m.context, bytes, style, offset);
        return (m.text(m.context, bytes[0..@min(offset, bytes.len)], style) catch return 0).width;
    }
    pub fn index(m: Measurer, bytes: []const u8, style: text_style.TextStyle, x: f32) usize {
        if (m.index_fn) |f| return f(m.context, bytes, style, x);
        var previous: f32 = 0;
        var i: usize = 0;
        while (i < bytes.len) {
            const start = i;
            i += 1;
            while (i < bytes.len and bytes[i] & 0xc0 == 0x80) : (i += 1) {}
            const next = m.caret(bytes, style, i);
            if (x < (previous + next) / 2) return start;
            previous = next;
        }
        return bytes.len;
    }
};
/// Deterministic test adapter, explicitly not a production font shaper.
pub const FixedMetrics = struct {
    advance: f32 = 8,
    line_height: f32 = 18,
    pub fn measurer(metrics: *FixedMetrics) Measurer {
        return .{ .context = metrics, .text = measure };
    }
    fn measure(raw: ?*anyopaque, text: []const u8, _: text_style.TextStyle) !geometry.Size {
        const metrics: *FixedMetrics = @ptrCast(@alignCast(raw.?));
        var points: usize = 0;
        for (text) |byte| if (byte & 0xc0 != 0x80) {
            points += 1;
        };
        return .{ .width = @as(f32, @floatFromInt(points)) * metrics.advance, .height = metrics.line_height };
    }
};
