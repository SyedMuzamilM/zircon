//! One selected project row changes per committed frame.
const std = @import("std");
const ui = @import("zircon_ui");

const rows = 32;
const highlight = ui.Color.rgb(0x345678);
const Sidebar = struct {
    selected: usize = 0,
    cached: bool,

    pub fn render(self: *const Sidebar, b: *ui.Ui) !ui.Element {
        const f = b.fluent();
        var children: [rows]ui.Element = undefined;
        for (&children, 0..) |*child, i| {
            var row = f.row().id(.{ .number = i }).h_px(20).background(if (self.selected == i) highlight else null);
            if (self.cached) row = row.cache();
            child.* = try row.child(f.textFmt("project/file-{d}.zig", .{i})).build();
        }
        return b.column(.{}, &children);
    }

    fn select(self: *Sidebar, cx: *ui.Context(Sidebar), selected: usize) void {
        self.selected = selected;
        cx.notify();
    }
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3) return error.ExpectedCachedOrFreshAndOutputPath;
    const cached = std.mem.eql(u8, args[1], "cached");
    if (!cached and !std.mem.eql(u8, args[1], "fresh")) return error.InvalidCacheMode;
    var app = try ui.App.init(.{ .allocator = init.gpa });
    defer app.deinit();
    const h = try app.openWindow(Sidebar, .{ .width = 320, .height = 640, .visible = false }, .{ .cached = cached });
    const owner = try app.windowEntity(Sidebar, h);
    const window = try app.window(h);
    window.profile_frames = true;
    _ = try app.step(0);
    const Sample = struct {
        elapsed_ns: i96,
        nodes: usize,
        scene_items: usize,
        measurement_hits: usize,
        arrangement_hits: usize,
        scene_hits: usize,
        phases: ?@TypeOf(window.last_frame_timings),
    };
    var samples: [1024]Sample = undefined;
    const native = @import("sidebar_options").native_timings;
    for (0..samples.len + rows) |i| {
        const selected = (i + 1) % rows;
        const m = window.layout_cache.measurement_hits;
        const a = window.layout_cache.arrangement_hits;
        const p = window.scene_cache.hits;
        const start = std.Io.Clock.awake.now(init.io);
        try app.update(owner, Sidebar.select, .{selected});
        if (try app.step(@as(f64, @floatFromInt(i + 1)) / 120) != 1) return error.ExpectedOneFrame;
        const elapsed = start.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds;
        const frame = &window.frames.committed;
        var highlights: usize = 0;
        for (frame.scene.items) |item| {
            if (item.kind != .rect or !std.meta.eql(item.color, highlight)) continue;
            if (item.rect.y != @as(f32, @floatFromInt(selected * 20)) or item.rect.height != 20) return error.WrongSelectionBounds;
            highlights += 1;
        }
        if (highlights != 1) return error.MissingOrDuplicateHighlight;
        if (i >= rows) samples[i - rows] = .{
            .elapsed_ns = elapsed,
            .nodes = frame.nodes.items.len,
            .scene_items = frame.scene.items.len,
            .measurement_hits = window.layout_cache.measurement_hits - m,
            .arrangement_hits = window.layout_cache.arrangement_hits - a,
            .scene_hits = window.scene_cache.hits - p,
            .phases = if (native) window.last_frame_timings else null,
        };
    }
    const json = try std.json.Stringify.valueAlloc(init.arena.allocator(), .{ .native = native, .cached = cached, .warmup_frames = rows, .samples = &samples }, .{});
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = args[2], .data = json });
}
