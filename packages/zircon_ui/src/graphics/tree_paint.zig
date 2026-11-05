//! Paints an arranged frame in tree order. Scene storage belongs to that same
//! frame, so staging failure can discard layout and paint together.
const tree = @import("../ui/tree.zig");
const flex = @import("../layout/flex.zig");
const g = @import("../layout/geometry.zig");
const Painter = @import("painter.zig").Painter;
pub fn paint(frame: *tree.Frame, layout: *const flex.Layout, painter: *Painter, measurer: @import("../layout/measure.zig").Measurer) !void {
    const root = frame.root orelse return error.NoFrameRoot;
    if (layout.frame_epoch != frame.epoch) return error.InvalidFrame;
    try node(frame, layout, painter, root.index, 1, 0, measurer);
}
fn node(frame: *tree.Frame, layout: *const flex.Layout, painter: *Painter, index: u32, inherited_opacity: f32, depth: usize, measurer: @import("../layout/measure.zig").Measurer) anyerror!void {
    if (depth > 128) return error.PaintDepthExceeded;
    const value = frame.nodes.items[index];
    const bounds = layout.bounds[index];
    const opacity = inherited_opacity * value.style.opacity;
    if (value.style.background) |background| {
        var color = background;
        color.a *= opacity;
        try painter.fillRect(.{ .bounds = bounds, .color = color, .radius = value.style.radius });
    }
    if (value.style.overflow == .hidden) try painter.pushClip(bounds);
    defer if (value.style.overflow == .hidden) painter.popClip();
    switch (value.kind) {
        .custom => |custom| {
            const previous_opacity = painter.opacity;
            painter.opacity = opacity;
            defer painter.opacity = previous_opacity;
            var cx: @import("../ui/custom.zig").PaintCx = .{ .painter = painter, .measurer = measurer, .focused = frame.focused_node == index, .text_input = &frame.text_input };
            try custom.paint(custom.object, &cx, bounds);
        },
        .container => {},
        .text, .button => {
            const text = if (value.kind == .text) value.kind.text else value.kind.button.label;
            var style = value.style.text;
            style.color.a *= opacity;
            const content: g.Rect = .{ .x = bounds.x + value.style.padding.left, .y = bounds.y + value.style.padding.top, .width = @max(0, bounds.width - value.style.padding.horizontal()), .height = @max(0, bounds.height - value.style.padding.vertical()) };
            try painter.drawText(.{ .bounds = content, .text = text, .style = style });
        },
    }
    for (value.children) |child| try node(frame, layout, painter, child, opacity, depth + 1, measurer);
}
