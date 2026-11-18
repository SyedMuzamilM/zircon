//! Native ABI for a single flex container. Negative dimensions denote auto.

const styles = @import("../ui/style.zig");
const geometry = @import("geometry.zig");
pub const Item = extern struct {
    width: f32,
    height: f32,
    min_width: f32,
    min_height: f32,
    max_width: f32,
    max_height: f32,
    left: f32,
    right: f32,
    top: f32,
    bottom: f32,
    grow: f32,
    shrink: f32,
};
pub const Bounds = extern struct { x: f32, y: f32, width: f32, height: f32 };

extern fn zircon_taffy_arrange(items: [*]const Item, output: [*]Bounds, count: usize, width: f32, height: f32, gap: f32, row: bool, alignment: u8, justify: u8) bool;

pub fn arrange(items: []const Item, output: []Bounds, size: geometry.Size, style: styles.Style) !void {
    const alignment: u8 = switch (style.align_items) {
        .start => 0,
        .center => 1,
        .end => 2,
        .stretch => 3,
    };
    const justify: u8 = switch (style.justify_content) {
        .start => 0,
        .center => 1,
        .end => 2,
        .space_between => 3,
    };
    if (!zircon_taffy_arrange(items.ptr, output.ptr, items.len, size.width, size.height, style.gap, style.direction == .row, alignment, justify)) return error.TaffyLayoutFailed;
}
