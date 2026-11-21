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
    fits_single_row_fn: ?*const fn (?*anyopaque, []const u8, text_style.TextStyle, f32) bool = null,
    line_carets_fn: ?*const fn (?*anyopaque, []const u8, text_style.TextStyle) ?LineCarets.Native = null,
    pub fn fitsSingleRow(m: Measurer, bytes: []const u8, style: text_style.TextStyle, width: f32) bool {
        const fits = m.fits_single_row_fn orelse return false;
        return fits(m.context, bytes, style, width);
    }
    pub fn caret(m: Measurer, bytes: []const u8, style: text_style.TextStyle, offset: usize) f32 {
        if (m.caret_fn) |f| return f(m.context, bytes, style, offset);
        return (m.text(m.context, bytes[0..@min(offset, bytes.len)], style) catch return 0).width;
    }
    /// Borrows the shaped line until the next measurement on this measurer.
    /// Use it for consecutive offsets in one draw or layout operation.
    pub fn lineCarets(m: Measurer, bytes: []const u8, style: text_style.TextStyle) LineCarets {
        if (m.line_carets_fn) |prepare| {
            if (prepare(m.context, bytes, style)) |native| {
                if (native.uniform_advance > 0) return .{ .uniform = .{ .advance = native.uniform_advance, .length = bytes.len } };
                return .{ .native = native };
            }
        }
        return .{ .measured = .{ .measurer = m, .bytes = bytes, .style = style } };
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

pub const LineCarets = union(enum) {
    uniform: struct { advance: f32, length: usize },
    native: Native,
    measured: struct { measurer: Measurer, bytes: []const u8, style: text_style.TextStyle },

    pub const Native = struct {
        context: *anyopaque,
        caret: *const fn (*anyopaque, usize) f32,
        uniform_advance: f32 = 0,
    };

    pub fn at(line: LineCarets, offset: usize) f32 {
        return switch (line) {
            .uniform => |uniform| @as(f32, @floatFromInt(@min(offset, uniform.length))) * uniform.advance,
            .native => |native| native.caret(native.context, offset),
            .measured => |measured| measured.measurer.caret(measured.bytes, measured.style, offset),
        };
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
