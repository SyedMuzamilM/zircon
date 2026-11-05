//! Typed styling for a documented flex subset, not a CSS string parser.
const std = @import("std");
pub const Insets = @import("../layout/geometry.zig").Insets;
pub const Color = @import("../layout/geometry.zig").Color;
pub const Length = union(enum) { auto, px: f32, percent: f32, rem: f32, viewport_width: f32, viewport_height: f32 };
pub const Direction = enum { row, column, stack };
pub const Align = enum { start, center, end, stretch };
pub const Justify = enum { start, center, end, space_between };
pub const Style = struct {
    direction: Direction = .column,
    width: Length = .auto,
    height: Length = .auto,
    min_width: Length = .auto,
    min_height: Length = .auto,
    max_width: Length = .auto,
    max_height: Length = .auto,
    padding: Insets = .{},
    margin: Insets = .{},
    gap: f32 = 0,
    align_items: Align = .stretch,
    justify_content: Justify = .start,
    flex_grow: f32 = 0,
    flex_shrink: f32 = 1,
    background: ?Color = null,
    radius: f32 = 0,
    opacity: f32 = 1,
    overflow: enum { visible, hidden } = .visible,
    text: @import("../text/style.zig").TextStyle = .{},
    pub fn validate(style: Style) !void {
        try style.text.validate();
        inline for (.{ "width", "height", "min_width", "min_height", "max_width", "max_height" }) |field| switch (@field(style, field)) {
            .auto => {},
            inline else => |n| if (!std.math.isFinite(n) or n < 0) return error.InvalidStyle,
        };
        inline for (.{ "gap", "flex_grow", "flex_shrink", "radius" }) |field| {
            const n = @field(style, field);
            if (!std.math.isFinite(n) or n < 0) return error.InvalidStyle;
        }
        inline for (.{ "padding", "margin" }) |field| inline for (.{ "top", "right", "bottom", "left" }) |edge| {
            const n = @field(@field(style, field), edge);
            if (!std.math.isFinite(n) or n < 0) return error.InvalidStyle;
        };
        if (!std.math.isFinite(style.opacity) or style.opacity < 0 or style.opacity > 1) return error.InvalidStyle;
        if (style.background) |color| inline for (.{ "r", "g", "b", "a" }) |field| {
            const n = @field(color, field);
            if (!std.math.isFinite(n) or n < 0 or n > 1) return error.InvalidStyle;
        };
    }
};
