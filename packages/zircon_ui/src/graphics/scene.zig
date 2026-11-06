//! Platform-neutral display items. No native pointers or C transport types.
const geometry = @import("../layout/geometry.zig");
pub const Primitive = struct {
    kind: enum { rect, text, image, line },
    segment: ?struct { start: geometry.Point, end: geometry.Point, width: f32 } = null,
    mono: bool = false,
    rect: geometry.Rect,
    clip: geometry.Rect,
    color: geometry.Color,
    radius: f32 = 0,
    font_size: f32 = 14,
    text: []const u8 = "",
    image: ?@import("images.zig").View = null,
    uv: geometry.Rect = .{ .width = 1, .height = 1 },
};
pub const Frame = struct { items: []const Primitive, background: geometry.Color };
