//! Ordered scene recording. The supplied frame arena owns commands and copied
//! text. Painter values and the resulting scene must not outlive that arena.
const std = @import("std");
const g = @import("../layout/geometry.zig");
const scene = @import("scene.zig");
const TextStyle = @import("../text/style.zig").TextStyle;
const images = @import("images.zig");
pub const Quad = struct { bounds: g.Rect, color: g.Color, radius: f32 = 0 };
pub const Text = struct { bounds: g.Rect, text: []const u8, style: TextStyle = .{} };
pub const Painter = struct {
    allocator: std.mem.Allocator,
    viewport: g.Rect,
    items: std.ArrayList(scene.Primitive) = .empty,
    clips: std.ArrayList(g.Rect) = .empty,
    opacity: f32 = 1,
    pub fn init(frame_allocator: std.mem.Allocator, viewport: g.Rect) !Painter {
        try validateRect(viewport);
        return .{ .allocator = frame_allocator, .viewport = viewport };
    }
    pub fn clip(painter: *const Painter) g.Rect {
        return if (painter.clips.items.len == 0) painter.viewport else painter.clips.items[painter.clips.items.len - 1];
    }
    pub fn pushClip(painter: *Painter, bounds: g.Rect) !void {
        try validateRect(bounds);
        try painter.clips.append(painter.allocator, painter.clip().intersection(bounds));
    }
    pub fn popClip(painter: *Painter) void {
        std.debug.assert(painter.clips.items.len > 0);
        _ = painter.clips.pop();
    }
    pub fn fillRect(painter: *Painter, quad: Quad) !void {
        try validateRect(quad.bounds);
        try validateColor(quad.color);
        if (!std.math.isFinite(quad.radius) or quad.radius < 0) return error.InvalidDrawCommand;
        const clipped = quad.bounds.intersection(painter.clip());
        if (clipped.width == 0 or clipped.height == 0) return;
        var color = quad.color;
        color.a *= painter.opacity;
        try painter.items.append(painter.allocator, .{ .kind = .rect, .rect = quad.bounds, .clip = painter.clip(), .color = color, .radius = quad.radius });
    }
    pub fn strokeRect(painter: *Painter, bounds: g.Rect, color: g.Color, width: f32) !void {
        try validateRect(bounds);
        if (!std.math.isFinite(width) or width < 0) return error.InvalidDrawCommand;
        const n = @min(width, @min(bounds.width, bounds.height) / 2);
        const edges = [_]g.Rect{
            .{ .x = bounds.x, .y = bounds.y, .width = bounds.width, .height = n },
            .{ .x = bounds.x, .y = bounds.y + bounds.height - n, .width = bounds.width, .height = n },
            .{ .x = bounds.x, .y = bounds.y + n, .width = n, .height = @max(0, bounds.height - 2 * n) },
            .{ .x = bounds.x + bounds.width - n, .y = bounds.y + n, .width = n, .height = @max(0, bounds.height - 2 * n) },
        };
        for (edges) |edge| try painter.fillRect(.{ .bounds = edge, .color = color });
    }
    pub fn drawText(painter: *Painter, options: Text) !void {
        try validateRect(options.bounds);
        try options.style.validate();
        if (!std.unicode.utf8ValidateSlice(options.text)) return error.InvalidUtf8;
        const clipped = options.bounds.intersection(painter.clip());
        if (clipped.width == 0 or clipped.height == 0 or options.text.len == 0) return;
        const text = try painter.allocator.dupe(u8, options.text);
        var color = options.style.color;
        color.a *= painter.opacity;
        try painter.items.append(painter.allocator, .{ .kind = .text, .rect = options.bounds, .clip = clipped, .color = color, .font_size = options.style.size, .mono = options.style.mono, .text = text });
    }
    /// Records a borrowed asset view. An owning Image must remain alive until
    /// this scene has been submitted; custom elements retain it in frame cleanup.
    pub fn drawImage(painter: *Painter, asset: images.Image, bounds: g.Rect, fit: images.Fit) !void {
        try validateRect(bounds);
        const view = asset.view();
        try view.validate();
        if (bounds.width == 0 or bounds.height == 0) return;
        const clipped = bounds.intersection(painter.clip());
        if (clipped.width == 0 or clipped.height == 0) return;
        var rect = bounds;
        var uv: g.Rect = .{ .width = 1, .height = 1 };
        const width: f32 = @floatFromInt(view.width);
        const height: f32 = @floatFromInt(view.height);
        switch (fit) {
            .stretch => {},
            .contain => {
                const scale = @min(bounds.width / width, bounds.height / height);
                rect.width = width * scale;
                rect.height = height * scale;
                rect.x += (bounds.width - rect.width) / 2;
                rect.y += (bounds.height - rect.height) / 2;
            },
            .cover => {
                const scale = @max(bounds.width / width, bounds.height / height);
                uv.width = bounds.width / (width * scale);
                uv.height = bounds.height / (height * scale);
                uv.x = (1 - uv.width) / 2;
                uv.y = (1 - uv.height) / 2;
            },
        }
        try painter.items.append(painter.allocator, .{ .kind = .image, .rect = rect, .clip = clipped, .color = .{ .r = 1, .g = 1, .b = 1, .a = painter.opacity }, .image = view, .uv = uv });
    }
    pub fn finish(painter: *const Painter, background: g.Color) !scene.Frame {
        if (painter.clips.items.len != 0) return error.UnbalancedClip;
        try validateColor(background);
        return .{ .items = painter.items.items, .background = background };
    }
};
fn validateRect(rect: g.Rect) !void {
    inline for (.{ "x", "y", "width", "height" }) |field| if (!std.math.isFinite(@field(rect, field))) return error.InvalidDrawCommand;
    if (rect.width < 0 or rect.height < 0) return error.InvalidDrawCommand;
}
fn validateColor(color: g.Color) !void {
    inline for (.{ "r", "g", "b", "a" }) |field| {
        const n = @field(color, field);
        if (!std.math.isFinite(n) or n < 0 or n > 1) return error.InvalidDrawCommand;
    }
}
