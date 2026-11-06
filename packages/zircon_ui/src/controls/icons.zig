//! Lucide's pinned, licensed SVG geometry, baked into native line segments.
//! Drawing and hit targets remain Zircon UI; no icon font or SVG parsing runs
//! during a frame. Source SVGs, attribution and the offline generator are kept.
const ui = @import("../ui/ui.zig");
const g = @import("../layout/geometry.zig");
const custom = @import("../ui/custom.zig");
const Painter = @import("../graphics/painter.zig").Painter;
const paths = @import("icon_paths.zig");
pub const Name = paths.Name;
pub fn element(builder: *ui.Ui, name: Name, color: g.Color, size: f32) !@import("../ui/element.zig").Element {
    return builder.custom(Icon, .{ .name = name, .color = color, .size = size }, .{ .width = .{ .px = size }, .height = .{ .px = size }, .flex_shrink = 0 });
}
const Icon = struct {
    name: Name,
    color: g.Color,
    size: f32,
    pub const LayoutState = void;
    pub const PrepaintState = void;
    pub fn requestLayout(self: *Icon, _: *custom.LayoutCx) !custom.LayoutResult(void) {
        return .{ .size = .{ .width = self.size, .height = self.size }, .state = {} };
    }
    pub fn prepaint(_: *Icon, _: *custom.PrepaintCx, _: g.Rect, _: *void) !void {}
    pub fn paint(self: *Icon, cx: *custom.PaintCx, bounds: g.Rect, _: *void, _: *void) !void {
        try draw(self.name, cx.painter, bounds, self.color);
    }
};
pub fn draw(name: Name, painter: *Painter, bounds: g.Rect, color: g.Color) !void {
    const side = @min(bounds.width, bounds.height);
    const scale = side / 24;
    const x = bounds.x + (bounds.width - side) / 2;
    const y = bounds.y + (bounds.height - side) / 2;
    for (paths.paths(name)) |points| {
        for (points[1..], points[0 .. points.len - 1]) |end, start| try painter.strokeLine(.{ .x = x + start[0] * scale, .y = y + start[1] * scale }, .{ .x = x + end[0] * scale, .y = y + end[1] * scale }, color, 2 * scale);
    }
}
