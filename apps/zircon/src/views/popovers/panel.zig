//! Shared workspace-popover framing, query focus and result scrolling.
const std = @import("std");
const ui = @import("zircon_ui");
const shell = @import("../../shell.zig");
const v = @import("../components.zig");
const Shell = shell.Shell;
pub const Options = struct { width: f32, height: f32, centered: bool = false, border_only: bool = false };
pub fn query(self: *const Shell, b: *ui.Ui, rows: *std.ArrayList(ui.Element)) !void {
    try rows.append(b.allocator(), try b.fluent().view(self.fields.?.query).id(.{ .string = "workspace-query" }).autofocus().style(.{ .height = .{ .px = 38 }, .flex_shrink = 0 }).build());
    try rows.append(b.allocator(), try v.rule(b, self.colors));
}
pub fn options(self: *const Shell, b: *ui.Ui, rows: *std.ArrayList(ui.Element), items: []const ui.Element, row_height: f32) !f32 {
    const visible = @min(@as(f32, @floatFromInt(items.len)) * row_height, @max(30, b.viewport().height - 240));
    const scroll = @max(0, @as(f32, @floatFromInt(self.overlay_index + 1)) * row_height - visible);
    try rows.append(b.allocator(), try b.fluent().div().h(.{ .px = visible }).scroll_y_px(scroll).shrink_0().overflow_hidden().flex_col().children(items).build());
    return visible;
}
pub fn render(self: *const Shell, b: *ui.Ui, settings: Options, rows: []const ui.Element) !ui.Element {
    const c = self.colors;
    const height = @min(settings.height, b.viewport().height - 40);
    const width = @min(settings.width, b.viewport().width - 24);
    const placement = if (settings.centered) ui.Rect{ .x = (b.viewport().width - width) / 2, .y = @min(78, b.viewport().height * 0.13), .width = width, .height = height } else v.popoverBounds(b.viewport(), self.popup_anchor, .{ .width = width, .height = height });
    const body = if (settings.border_only)
        try b.fluent().div().w(.{ .px = placement.width }).h(.{ .px = placement.height }).shrink_0().padding(ui.Insets.all(1)).rounded_px(v.metrics.popover_radius).background(c.line).flex_col().children(.{b.fluent().div().grow().padding(ui.Insets.all(5)).rounded_px(v.metrics.popover_radius - 1).background(c.panel).overflow_hidden().flex_col().children(rows)}).build()
    else
        try v.floatingPanel(b, c, .{ .width = placement.width, .height = placement.height }, ui.Insets.all(6), 0, rows);
    const popup = try b.fluent().adopt(body).id(.{ .string = "workspace-popup" }).build();
    return b.fluent().div().padding(.{ .top = placement.y, .left = placement.x }).items(.start).stack().children(.{popup}).listeners(.{ .on_input = b.onInput(Shell.onMenuInput) }).modal().build();
}
