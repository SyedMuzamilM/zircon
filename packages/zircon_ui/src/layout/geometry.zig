//! Logical geometry. Device scaling belongs to the graphics backend.
pub const Point = struct { x: f32 = 0, y: f32 = 0 };
pub const Size = struct { width: f32, height: f32 };
pub const Rect = struct { x: f32 = 0, y: f32 = 0, width: f32 = 0, height: f32 = 0 };
pub const Insets = struct {
    top: f32 = 0,
    right: f32 = 0,
    bottom: f32 = 0,
    left: f32 = 0,
    pub fn all(value: f32) Insets {
        return .{ .top = value, .right = value, .bottom = value, .left = value };
    }
    pub fn horizontal(value: Insets) f32 {
        return value.left + value.right;
    }
    pub fn vertical(value: Insets) f32 {
        return value.top + value.bottom;
    }
};
