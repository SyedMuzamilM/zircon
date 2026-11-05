//! Font settings shared by layout, painting and native shaping adapters.
const std = @import("std");
const Color = @import("../layout/geometry.zig").Color;
pub const TextStyle = struct {
    size: f32 = 14,
    mono: bool = false,
    color: Color = .white,
    pub fn validate(style: TextStyle) !void {
        if (!std.math.isFinite(style.size) or style.size <= 0 or style.size > 256) return error.InvalidTextStyle;
        inline for (.{ "r", "g", "b", "a" }) |field| {
            const n = @field(style.color, field);
            if (!std.math.isFinite(n) or n < 0 or n > 1) return error.InvalidTextStyle;
        }
    }
};
