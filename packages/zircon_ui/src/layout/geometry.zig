//! Logical geometry. Device scaling belongs to the graphics backend.
pub const Point = struct { x: f32 = 0, y: f32 = 0 };
pub const Size = struct { width: f32, height: f32 };
pub const Rect = struct {
    x: f32 = 0,
    y: f32 = 0,
    width: f32 = 0,
    height: f32 = 0,
    pub fn intersection(a: Rect, b: Rect) Rect {
        const x = @max(a.x, b.x);
        const y = @max(a.y, b.y);
        return .{ .x = x, .y = y, .width = @max(0, @min(a.x + a.width, b.x + b.width) - x), .height = @max(0, @min(a.y + a.height, b.y + b.height) - y) };
    }
};
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

pub const Color = struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32 = 1,
    pub const white: Color = .{ .r = 1, .g = 1, .b = 1 };
    pub const black: Color = .{ .r = 0, .g = 0, .b = 0 };
    pub const transparent: Color = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
    pub fn rgb(value: u24) Color {
        return .{ .r = @as(f32, @floatFromInt((value >> 16) & 255)) / 255, .g = @as(f32, @floatFromInt((value >> 8) & 255)) / 255, .b = @as(f32, @floatFromInt(value & 255)) / 255 };
    }
};
