//! Million-item virtualization benchmark. It measures layout/prepaint/paint
//! CPU work with a fixed viewport; it never allocates one node per item.

const std = @import("std");
const ui = @import("zircon_ui");
const Probe = struct {
    painted: usize = 0,
    fn paint(raw: *anyopaque, index: usize, bounds: ui.Rect, cx: *ui.PaintCx) !void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.painted += 1;
        try cx.painter.fillRect(.{ .bounds = bounds, .color = if (index % 2 == 0) .{ .r = 0.15, .g = 0.18, .b = 0.23 } else .{ .r = 0.18, .g = 0.21, .b = 0.27 } });
    }
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const item_count: usize = if (args.len > 1) try std.fmt.parseInt(usize, args[1], 10) else 1_000_000;
    const iterations: usize = if (args.len > 2) try std.fmt.parseInt(usize, args[2], 10) else 200;
    var probe: Probe = .{};
    var list = ui.controls.uniformList(item_count, 20, 0, 2, &probe, Probe.paint);
    var metrics: ui.layout.FixedMetrics = .{};
    var layout_cx: ui.LayoutCx = .{ .allocator = init.gpa, .available = .{ .width = 1200, .height = 820 }, .measurer = metrics.measurer() };
    const start = std.Io.Clock.awake.now(init.io).nanoseconds;
    var scene_items: usize = 0;
    for (0..iterations) |iteration| {
        list.offset = @as(f32, @floatFromInt((iteration * 137) % (item_count * 20)));
        const layout = try list.requestLayout(&layout_cx);
        var state = layout.state;
        var prepaint_cx: ui.PrepaintCx = .{ .allocator = init.gpa };
        var prepaint = try list.prepaint(&prepaint_cx, .{ .width = 1200, .height = 820 }, &state);
        var arena = std.heap.ArenaAllocator.init(init.gpa);
        var painter = try ui.graphics.Painter.init(arena.allocator(), .{ .width = 1200, .height = 820 });
        var paint_cx: ui.PaintCx = .{ .painter = &painter, .measurer = metrics.measurer() };
        try list.paint(&paint_cx, .{ .width = 1200, .height = 820 }, &state, &prepaint);
        scene_items += painter.items.items.len;
        arena.deinit();
    }
    const elapsed_ns = std.Io.Clock.awake.now(init.io).nanoseconds - start;
    std.debug.print("{{\"items\":{},\"iterations\":{},\"painted_rows\":{},\"scene_items\":{},\"elapsed_ms\":{d:.3},\"avg_frame_ms\":{d:.6}}}\n", .{ item_count, iterations, probe.painted, scene_items, @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000, @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000 / @as(f64, @floatFromInt(iterations)) });
}
