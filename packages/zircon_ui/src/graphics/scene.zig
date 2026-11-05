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
pub const Range = struct { start: usize, end: usize };
pub const TextInput = struct { text: []const u8, caret: usize, anchor: usize, marked: ?Range = null, caret_rect: geometry.Rect, can_undo: bool = false, can_redo: bool = false };
pub const Frame = struct { items: []const Primitive, background: geometry.Color, input: ?TextInput = null };
