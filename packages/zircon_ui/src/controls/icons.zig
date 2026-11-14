//! Shared assets/icons SVG geometry, baked into native strokes and fill spans.
//! Drawing and hit targets remain Zircon UI; no icon font or SVG parsing runs
//! during a frame. Source SVGs, attribution and the offline generator are kept.
const std = @import("std");
const graphics_painter = @import("../graphics/painter.zig");
const g = @import("../layout/geometry.zig");
const custom = @import("../ui/custom.zig");
const ui_element = @import("../ui/element.zig");
const ui = @import("../ui/ui.zig");
const paths = @import("icon_paths.zig");
const Painter = graphics_painter.Painter;
pub const Name = paths.Name;
pub fn element(builder: *ui.Ui, name: Name, color: g.Color, size: f32) !ui_element.Element {
    return builder.custom(Icon, .{ .name = name, .color = color, .size = size }, .{ .width = .{ .px = size }, .height = .{ .px = size }, .flex_shrink = 0 });
}
const Icon = struct {
    name: Name,
    color: g.Color,
    size: f32,
    pub const LayoutState = void;
    pub const PrepaintState = void;
    pub fn cacheFingerprint(self: *const Icon) u64 {
        var hash: u64 = @intFromEnum(self.name);
        hash = std.hash.Wyhash.hash(hash, std.mem.asBytes(&self.color));
        hash = std.hash.Wyhash.hash(hash, std.mem.asBytes(&self.size));
        return hash;
    }
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
    for (paths.fills(name)) |rect| {
        var tint = color;
        tint.a *= rect[4];
        try painter.fillRect(.{ .bounds = .{ .x = x + rect[0] * scale, .y = y + rect[1] * scale, .width = rect[2] * scale, .height = rect[3] * scale }, .color = tint });
    }
    for (paths.strokes(name)) |stroke| {
        const points = stroke.points;
        var tint = color;
        tint.a *= stroke.opacity;
        for (points[1..], points[0 .. points.len - 1]) |end, start| try painter.strokeLine(.{ .x = x + start[0] * scale, .y = y + start[1] * scale }, .{ .x = x + end[0] * scale, .y = y + end[1] * scale }, tint, stroke.width * scale);
    }
}
