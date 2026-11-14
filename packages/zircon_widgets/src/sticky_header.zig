//! File headers share viewport pinning and next-file push-off across composites.
const std = @import("std");
const ui = @import("zircon_ui");
pub fn hit(frame: anytype, input: ui.Input, prefix: []const u8) bool {
    if (input != .pointer_down) return false;
    for (frame.nodes.items, 0..) |node, i| if (node.key) |key| if (key == .string and std.mem.startsWith(u8, key.string, prefix)) {
        const rect = frame.bounds[i];
        const point = input.pointer_down.position;
        if (point.x >= rect.x and point.x < rect.x + rect.width and point.y >= rect.y and point.y < rect.y + rect.height) return true;
    };
    return false;
}
pub fn offset(first: f32, end: f32, height: f32, scroll: f32) ?f32 {
    if (scroll <= first or scroll >= end) return null;
    return @max(0, scroll + height - end);
}
pub fn overlay(b: *ui.Ui, content: ui.Element, header: ui.Element, height: f32, push: f32) !ui.Element {
    return b.fluent().stack().grow().min_h_px(0).overflow_hidden().children(.{
        content,
        b.fluent().column().h_px(height).shrink_0().scroll_y_px(push).overflow_hidden().child(header),
    }).build();
}
