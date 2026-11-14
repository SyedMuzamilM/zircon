//! Platform-neutral display items. No native pointers or C transport types.
const std = @import("std");
const geometry = @import("../layout/geometry.zig");
const images = @import("images.zig");
pub const Transform = struct {
    scale_x: f32 = 1,
    scale_y: f32 = 1,
    translate_x: f32 = 0,
    translate_y: f32 = 0,
    rotation: f32 = 0,
    opacity: f32 = 1,
    pub const identity: Transform = .{};
};
pub const Gradient = struct {
    start: geometry.Point,
    end: geometry.Point,
    end_color: geometry.Color,
};
pub const AnimationSpec = struct {
    from: Transform,
    to: Transform,
    duration: f64,
    repeat: bool = false,
};
pub const Animation = struct {
    item_index: usize,
    spec: AnimationSpec,
    started: f64 = 0,
};
pub const Primitive = struct {
    kind: enum { rect, text, image, line, gradient },
    segment: ?struct { start: geometry.Point, end: geometry.Point, width: f32 } = null,
    mono: bool = false,
    rect: geometry.Rect,
    clip: geometry.Rect,
    color: geometry.Color,
    radius: f32 = 0,
    font_size: f32 = 14,
    text: []const u8 = "",
    image: ?images.View = null,
    uv: geometry.Rect = .{ .width = 1, .height = 1 },
    transform: Transform = .identity,
    gradient: ?Gradient = null,
};
pub const Frame = struct {
    items: []const Primitive,
    background: geometry.Color,
    animations: []Animation = &.{},

    pub fn startAnimations(frame: *Frame, now: f64) void {
        for (frame.animations) |*animation| animation.started = now;
    }

    /// Advances scene-only animations. Returns whether another frame is needed.
    pub fn advance(frame: *Frame, now: f64) bool {
        var active = false;
        for (frame.animations) |animation| {
            if (animation.item_index >= frame.items.len or !std.math.isFinite(now) or !std.math.isFinite(animation.spec.duration) or animation.spec.duration <= 0) continue;
            const elapsed = @max(0, now - animation.started);
            const raw = elapsed / animation.spec.duration;
            const settled = raw >= 1;
            const progress = if (animation.spec.repeat) raw - @floor(raw) else @min(1, raw);
            @constCast(frame.items)[animation.item_index].transform = interpolate(animation.spec.from, animation.spec.to, progress);
            if (animation.spec.repeat or !settled) active = true;
        }
        return active;
    }
};

fn interpolate(from: Transform, to: Transform, progress: f64) Transform {
    const p: f32 = @floatCast(std.math.clamp(progress, 0, 1));
    return .{
        .scale_x = from.scale_x + (to.scale_x - from.scale_x) * p,
        .scale_y = from.scale_y + (to.scale_y - from.scale_y) * p,
        .translate_x = from.translate_x + (to.translate_x - from.translate_x) * p,
        .translate_y = from.translate_y + (to.translate_y - from.translate_y) * p,
        .rotation = from.rotation + (to.rotation - from.rotation) * p,
        .opacity = from.opacity + (to.opacity - from.opacity) * p,
    };
}
