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
    var hovered = frame.hovered_node;
    var within_hover = false;
    while (hovered) |current| : (hovered = frame.nodes.items[current].parent) if (current == index) {
        within_hover = true;
        break;
    };
    const background_value = if (within_hover) value.style.hover_background orelse value.style.background else value.style.background;
    if (background_value) |background| {
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
            var cx: @import("../ui/custom.zig").PaintCx = .{ .painter = painter, .measurer = measurer, .focused = frame.focused_node == index, .text_input = &frame.text_input, .time = frame.time, .next_deadline = &frame.next_deadline };
            try custom.paint(custom.object, &cx, bounds);
        },
        .container => {},
        .text, .button => {
            const text = if (value.kind == .text) value.kind.text else value.kind.button.label;
            var style = value.style.text;
            style.color.a *= opacity;
            var content: g.Rect = .{ .x = bounds.x + value.style.padding.left, .y = bounds.y + value.style.padding.top, .width = @max(0, bounds.width - value.style.padding.horizontal()), .height = @max(0, bounds.height - value.style.padding.vertical()) };
            // A bare button label follows the same alignment as a text child.
            // Previously its top-left paint origin ignored centered layout.
            if (value.kind == .button and value.children.len == 0) {
                const measured = try measurer.text(measurer.context, text, style);
                const horizontal = value.style.direction == .row;
                const center_x = if (horizontal) value.style.justify_content == .center else value.style.align_items == .center;
                const center_y = if (horizontal) value.style.align_items == .center else value.style.justify_content == .center;
                if (center_x) content.x += @max(0, content.width - measured.width) / 2;
                if (center_y) content.y += @max(0, content.height - measured.height) / 2;
                content.width = @min(content.width, measured.width);
                content.height = @min(content.height, measured.height);
            }
            if (value.kind == .text or value.children.len == 0) try painter.drawText(.{ .bounds = content, .text = text, .style = style });
        },
    }
    for (value.children) |child| try node(frame, layout, painter, child, opacity, depth + 1, measurer);
}
