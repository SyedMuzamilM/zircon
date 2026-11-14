//! Shared application controls and semantic colors. No workspace policy.
const std = @import("std");
const ui = @import("zircon_ui");
const palette = @import("palette.zig");
pub const sticky_header = @import("sticky_header.zig");
pub const Palette = palette.Palette;
pub const Icon = ui.controls.icons.Name;
pub const metrics = struct {
    pub const control_radius = ui.controls.metrics.control_radius;
    pub const popover_radius = ui.controls.metrics.popover_radius;
    pub const titlebar: f32 = 34;
    pub const tabs: f32 = 32;
    pub const status: f32 = 24;
    pub const file_header: f32 = 32;
    pub const tree_row: f32 = 24;
    pub const divider: f32 = 5;
    pub const control: f32 = 28;
    pub const icon_control: f32 = 22;
    pub const small_gap: f32 = 4;
    pub const inset: f32 = 12;
};
pub fn text(b: *ui.Ui, bytes: []const u8, color: ui.Color, size: f32) !ui.Element {
    return b.fluent().text(bytes).style(.{
        .text = .{ .size = size, .color = color },
        .overflow = .hidden,
        .flex_shrink = 0,
    }).build();
}

pub fn icon(b: *ui.Ui, name: Icon, color: ui.Color, size: f32) !ui.Element {
    return ui.controls.icons.element(b, name, color, size);
}

pub fn iconButtonStyle(c: Palette, selected: bool) ui.Style {
    return .{ .width = .{ .px = 24 }, .height = .{ .px = metrics.icon_control }, .flex_shrink = 0, .align_items = .center, .justify_content = .center, .radius = metrics.control_radius, .background = if (selected) c.selected else null, .hover_background = c.hover };
}

pub fn buttonStyle(c: Palette, primary: bool) ui.Style {
    return .{ .direction = .row, .height = .{ .px = metrics.control }, .gap = 6, .align_items = .center, .justify_content = .center, .padding = .{ .left = 8, .right = 8 }, .radius = metrics.control_radius, .background = if (primary) c.primary else c.element, .hover_background = if (primary) c.primary_hover else c.hover, .text = .{ .size = 12, .color = if (primary) c.on_primary else c.text }, .flex_shrink = 0 };
}

pub fn inputAppearance(c: Palette) ui.controls.TextInput.Appearance {
    return .{ .background = c.document, .border = c.line, .foreground = c.text, .placeholder = c.muted, .selection = c.selection, .caret = c.accent, .focus_border = c.accent };
}

pub fn rule(b: *ui.Ui, c: Palette) !ui.Element {
    return b.fluent().div().h(.{ .px = 1 }).shrink_0().background(c.line).children(.{}).build();
}

pub fn popoverBounds(viewport: ui.Size, anchor: ui.Rect, requested: ui.Size) ui.Rect {
    const inset: f32 = 6;
    const width = @min(requested.width, @max(0, viewport.width - inset * 2));
    const height = @min(requested.height, @max(0, viewport.height - inset * 2));
    const below = anchor.y + anchor.height + 4;
    const preferred_y = if (below + height <= viewport.height - inset) below else anchor.y - height - 4;
    return .{ .x = std.math.clamp(anchor.x + anchor.width - width, inset, @max(inset, viewport.width - width - inset)), .y = std.math.clamp(preferred_y, inset, @max(inset, viewport.height - height - inset)), .width = width, .height = height };
}

pub fn floatingPanel(b: *ui.Ui, c: Palette, size: ui.Size, padding: ui.Insets, gap: f32, children: []const ui.Element) !ui.Element {
    return b.fluent().div().w(.{ .px = size.width }).h(.{ .px = size.height }).shrink_0().stack().children(.{
        b.custom(PanelSurface, .{ .colors = c }, .{ .flex_grow = 1 }),
        b.fluent().div().padding(padding).gap_px(gap).overflow_hidden().flex_col().children(children),
    }).build();
}
const PanelSurface = struct {
    colors: Palette,
    pub const LayoutState = void;
    pub const PrepaintState = void;
    pub fn requestLayout(_: *PanelSurface, cx: *ui.LayoutCx) !ui.LayoutResult(void) {
        return .{ .size = cx.available, .state = {} };
    }
    pub fn prepaint(_: *PanelSurface, _: *ui.PrepaintCx, _: ui.Rect, _: *void) !void {}
    pub fn paint(self: *PanelSurface, cx: *ui.PaintCx, bounds: ui.Rect, _: *void, _: *void) !void {
        for ([_]f32{ 10, 6, 3 }) |spread| try cx.painter.fillRect(.{ .bounds = .{ .x = bounds.x - spread, .y = bounds.y - spread / 2 + 2, .width = bounds.width + spread * 2, .height = bounds.height + spread }, .radius = metrics.popover_radius + spread, .color = .{ .r = 0, .g = 0, .b = 0, .a = 0.035 } });
        try cx.painter.fillRect(.{ .bounds = bounds, .radius = metrics.popover_radius, .color = self.colors.line });
        try cx.painter.fillRect(.{ .bounds = .{ .x = bounds.x + 1, .y = bounds.y + 1, .width = @max(0, bounds.width - 2), .height = @max(0, bounds.height - 2) }, .radius = metrics.popover_radius - 1, .color = self.colors.panel });
    }
};
