//! Original outline icons built from framework line segments, not font glyphs
//! or imported artwork. They retain crisp strokes at native display scales.
const std = @import("std");
const ui = @import("../ui/ui.zig");
const g = @import("../layout/geometry.zig");
const custom = @import("../ui/custom.zig");
const Painter = @import("../graphics/painter.zig").Painter;
pub const Name = enum { folder, folder_open, file, code, zig, markdown, image, chevron_down, chevron_right, chevron_left, plus, close, search, split, sidebar, branch, history, settings, commands, more, check, extension, refresh, arrow_up, arrow_down };
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
        const side = @min(bounds.width, bounds.height);
        var path: Path = .{ .painter = cx.painter, .color = self.color, .x = bounds.x + (bounds.width - side) / 2, .y = bounds.y + (bounds.height - side) / 2, .scale = side / 20 };
        switch (self.name) {
            .folder, .folder_open => {
                try path.chain(&.{ .{ 3, 16 }, .{ 3, 5 }, .{ 8, 5 }, .{ 10, 7 }, .{ 17, 7 }, .{ 17, 16 }, .{ 3, 16 } });
                if (self.name == .folder_open) try path.chain(&.{ .{ 3, 16 }, .{ 5, 10 }, .{ 18, 10 }, .{ 16, 16 } });
            },
            .file, .zig => {
                try path.chain(&.{ .{ 12, 3 }, .{ 5, 3 }, .{ 5, 17 }, .{ 16, 17 }, .{ 16, 7 }, .{ 12, 3 }, .{ 12, 7 }, .{ 16, 7 } });
                if (self.name == .zig) try path.chain(&.{ .{ 8, 10 }, .{ 13, 10 }, .{ 8, 14 }, .{ 13, 14 } });
            },
            .code => {
                try path.chain(&.{ .{ 7, 5 }, .{ 3, 10 }, .{ 7, 15 } });
                try path.chain(&.{ .{ 13, 5 }, .{ 17, 10 }, .{ 13, 15 } });
                try path.line(.{ 11, 4 }, .{ 9, 16 });
            },
            .markdown => {
                try path.box(2, 5, 16, 11);
                try path.chain(&.{ .{ 5, 13 }, .{ 5, 8 }, .{ 8, 11 }, .{ 11, 8 }, .{ 11, 13 } });
                try path.line(.{ 15, 8 }, .{ 15, 13 });
                try path.chain(&.{ .{ 13, 11 }, .{ 15, 13 }, .{ 17, 11 } });
            },
            .image => {
                try path.box(3, 3, 14, 14);
                try path.circle(7, 7, 1);
                try path.chain(&.{ .{ 3, 14 }, .{ 8, 10 }, .{ 11, 13 }, .{ 14, 9 }, .{ 17, 12 } });
            },
            .chevron_down => try path.chain(&.{ .{ 5, 8 }, .{ 10, 13 }, .{ 15, 8 } }),
            .chevron_right => try path.chain(&.{ .{ 8, 5 }, .{ 13, 10 }, .{ 8, 15 } }),
            .chevron_left => try path.chain(&.{ .{ 12, 5 }, .{ 7, 10 }, .{ 12, 15 } }),
            .plus => {
                try path.line(.{ 10, 4 }, .{ 10, 16 });
                try path.line(.{ 4, 10 }, .{ 16, 10 });
            },
            .close => {
                try path.line(.{ 5, 5 }, .{ 15, 15 });
                try path.line(.{ 15, 5 }, .{ 5, 15 });
            },
            .search => {
                try path.circle(8.5, 8.5, 5);
                try path.line(.{ 12, 12 }, .{ 17, 17 });
            },
            .split, .sidebar => {
                try path.box(3, 4, 14, 12);
                try path.line(.{ if (self.name == .split) 10 else 7, 4 }, .{ if (self.name == .split) 10 else 7, 16 });
            },
            .branch => {
                try path.circle(6, 4, 2);
                try path.circle(6, 16, 2);
                try path.circle(15, 5, 2);
                try path.line(.{ 6, 6 }, .{ 6, 14 });
                try path.chain(&.{ .{ 15, 7 }, .{ 15, 9 }, .{ 12, 12 }, .{ 6, 12 } });
            },
            .history, .refresh => {
                try path.arc(10, 10, 6, -0.1, 5.0);
                try path.chain(&.{ .{ 3, 4 }, .{ 3, 8 }, .{ 7, 8 } });
                if (self.name == .history) try path.chain(&.{ .{ 10, 6 }, .{ 10, 10 }, .{ 13, 12 } });
            },
            .settings => {
                try path.circle(10, 10, 3);
                try path.circle(10, 10, 6);
                for (0..8) |i| {
                    const angle = @as(f32, @floatFromInt(i)) * std.math.pi / 4;
                    try path.line(.{ 10 + @cos(angle) * 6, 10 + @sin(angle) * 6 }, .{ 10 + @cos(angle) * 8, 10 + @sin(angle) * 8 });
                }
            },
            .commands => {
                try path.chain(&.{ .{ 4, 5 }, .{ 9, 10 }, .{ 4, 15 } });
                try path.line(.{ 11, 15 }, .{ 17, 15 });
            },
            .more => for ([_]f32{ 4, 10, 16 }) |x| try path.circle(x, 10, 0.7),
            .check => try path.chain(&.{ .{ 4, 10 }, .{ 8, 14 }, .{ 16, 5 } }),
            .extension => {
                try path.box(3, 3, 5, 5);
                try path.box(12, 3, 5, 5);
                try path.box(3, 12, 5, 5);
                try path.box(12, 12, 5, 5);
            },
            .arrow_up, .arrow_down => {
                const a: f32 = if (self.name == .arrow_up) 5 else 15;
                const b: f32 = 20 - a;
                try path.line(.{ 10, a }, .{ 10, b });
                try path.chain(&.{ .{ 5, 10 }, .{ 10, a }, .{ 15, 10 } });
            },
        }
    }
};
const Path = struct {
    painter: *Painter,
    color: g.Color,
    x: f32,
    y: f32,
    scale: f32,
    fn line(self: *Path, a: [2]f32, b: [2]f32) !void {
        try self.painter.strokeLine(.{ .x = self.x + a[0] * self.scale, .y = self.y + a[1] * self.scale }, .{ .x = self.x + b[0] * self.scale, .y = self.y + b[1] * self.scale }, self.color, 1.5 * self.scale);
    }
    fn chain(self: *Path, points: []const [2]f32) !void {
        for (points[1..], 1..) |point, i| try self.line(points[i - 1], point);
    }
    fn box(self: *Path, x: f32, y: f32, w: f32, h: f32) !void {
        try self.chain(&.{ .{ x, y }, .{ x + w, y }, .{ x + w, y + h }, .{ x, y + h }, .{ x, y } });
    }
    fn circle(self: *Path, x: f32, y: f32, radius: f32) !void {
        try self.arc(x, y, radius, 0, std.math.tau);
    }
    fn arc(self: *Path, x: f32, y: f32, radius: f32, start: f32, end: f32) !void {
        var last = [2]f32{ x + @cos(start) * radius, y + @sin(start) * radius };
        for (1..25) |i| {
            const angle = start + (end - start) * @as(f32, @floatFromInt(i)) / 24;
            const next = [2]f32{ x + @cos(angle) * radius, y + @sin(angle) * radius };
            try self.line(last, next);
            last = next;
        }
    }
};
