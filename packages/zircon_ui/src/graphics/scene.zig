//! Platform-neutral display items. No native pointers or C transport types.
const geometry = @import("../layout/geometry.zig");
pub const Primitive = struct {
    kind: enum { rect, text },
    mono: bool = false,
    rect: geometry.Rect,
    clip: geometry.Rect,
    color: geometry.Color,
    radius: f32 = 0,
    font_size: f32 = 14,
    text: []const u8 = "",
};
pub const Frame = struct { items: []const Primitive, background: geometry.Color };
