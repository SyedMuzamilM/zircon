//! Runtime SVG-backed image element. SVG decoding happens before the frame is
//! built; paint only submits the retained image view and transform instance.

const images = @import("../graphics/images.zig");
const scene = @import("../graphics/scene.zig");
const geometry = @import("../layout/geometry.zig");
const custom = @import("../ui/custom.zig");
pub const Svg = struct {
    image: images.Image,
    transform: scene.Transform = .identity,
    animation: ?scene.AnimationSpec = null,

    pub const LayoutState = struct { size: geometry.Size };
    pub const PrepaintState = void;

    pub fn init(image: images.Image) Svg {
        return .{ .image = image };
    }

    pub fn requestLayout(self: *Svg, cx: *custom.LayoutCx) !custom.LayoutResult(LayoutState) {
        const natural = self.image.size();
        return .{ .size = .{ .width = if (cx.available.width > 0) @min(natural.width, cx.available.width) else natural.width, .height = if (cx.available.height > 0) @min(natural.height, cx.available.height) else natural.height }, .state = .{ .size = natural } };
    }

    pub fn prepaint(_: *Svg, _: *custom.PrepaintCx, _: geometry.Rect, _: *LayoutState) !PrepaintState {}

    pub fn paint(self: *Svg, cx: *custom.PaintCx, bounds: geometry.Rect, _: *LayoutState, _: *PrepaintState) !void {
        if (self.animation) |animation| {
            try cx.painter.drawAnimatedImage(self.image, bounds, .contain, animation);
        } else try cx.painter.drawImageTransformed(self.image, bounds, .contain, self.transform);
    }

    pub fn deinit(self: *Svg) void {
        self.image.deinit();
    }
};

pub fn init(image: images.Image) Svg {
    return Svg.init(image);
}
