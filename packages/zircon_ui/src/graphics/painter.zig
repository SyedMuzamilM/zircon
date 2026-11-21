//! Ordered scene recording. The supplied frame arena owns commands and copied
//! text. Painter values and the resulting scene must not outlive that arena.
const std = @import("std");
const g = @import("../layout/geometry.zig");
const text_style = @import("../text/style.zig");
const images = @import("images.zig");
const scene = @import("scene.zig");
const TextStyle = text_style.TextStyle;
pub const Quad = struct { bounds: g.Rect, color: g.Color, radius: f32 = 0 };
pub const Text = struct { bounds: g.Rect, text: []const u8, style: TextStyle = .{} };
pub const Transform = scene.Transform;
pub const Gradient = scene.Gradient;
pub const Painter = struct {
    allocator: std.mem.Allocator,
    viewport: g.Rect,
    items: std.ArrayList(scene.Primitive) = .empty,
    animations: std.ArrayList(scene.Animation) = .empty,
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
    pub fn fillLinearGradient(painter: *Painter, bounds: g.Rect, from: g.Color, to: g.Color, start: g.Point, end: g.Point, radius: f32) !void {
        try validateRect(bounds);
        try validateColor(from);
        try validateColor(to);
        inline for (.{ start.x, start.y, end.x, end.y, radius }) |value| if (!std.math.isFinite(value)) return error.InvalidDrawCommand;
        if (radius < 0) return error.InvalidDrawCommand;
        const clipped = bounds.intersection(painter.clip());
        if (clipped.width == 0 or clipped.height == 0) return;
        var color = from;
        color.a *= painter.opacity;
        var end_color = to;
        end_color.a *= painter.opacity;
        try painter.items.append(painter.allocator, .{ .kind = .gradient, .rect = bounds, .clip = clipped, .color = color, .radius = radius, .gradient = .{ .start = start, .end = end, .end_color = end_color } });
    }
    /// Emits a small layered approximation of a blurred shadow. It keeps the
    /// scene representation batchable and avoids a separate blur texture.
    pub fn shadowRect(painter: *Painter, bounds: g.Rect, color: g.Color, radius: f32, blur: f32, offset: g.Point) !void {
        try validateRect(bounds);
        try validateColor(color);
        if (!std.math.isFinite(blur) or blur < 0 or !std.math.isFinite(offset.x) or !std.math.isFinite(offset.y) or !std.math.isFinite(radius) or radius < 0) return error.InvalidDrawCommand;
        const layers: usize = @max(1, @as(usize, @intFromFloat(@ceil(blur / 2))));
        for (0..layers) |layer| {
            const t: f32 = @as(f32, @floatFromInt(layer + 1)) / @as(f32, @floatFromInt(layers));
            var layer_color = color;
            layer_color.a *= 1 - t;
            const spread = blur * t;
            try painter.fillRect(.{ .bounds = .{ .x = bounds.x + offset.x - spread, .y = bounds.y + offset.y - spread, .width = bounds.width + spread * 2, .height = bounds.height + spread * 2 }, .color = layer_color, .radius = radius + spread });
        }
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
    /// Antialiased segment with round caps. Endpoints stay in logical pixels;
    /// the native renderer evaluates coverage at the actual display scale.
    pub fn strokeLine(painter: *Painter, start: g.Point, end: g.Point, color_value: g.Color, width: f32) !void {
        inline for (.{ start.x, start.y, end.x, end.y, width }) |value| if (!std.math.isFinite(value)) return error.InvalidDrawCommand;
        if (width < 0) return error.InvalidDrawCommand;
        try validateColor(color_value);
        if (width == 0) return;
        const pad = width * 0.5 + 1;
        const bounds: g.Rect = .{ .x = @min(start.x, end.x) - pad, .y = @min(start.y, end.y) - pad, .width = @abs(end.x - start.x) + pad * 2, .height = @abs(end.y - start.y) + pad * 2 };
        const clipped = bounds.intersection(painter.clip());
        if (clipped.width == 0 or clipped.height == 0) return;
        var color = color_value;
        color.a *= painter.opacity;
        try painter.items.append(painter.allocator, .{ .kind = .line, .rect = bounds, .clip = painter.clip(), .color = color, .segment = .{ .start = start, .end = end, .width = width } });
    }
    pub fn drawText(painter: *Painter, options: Text) !void {
        return paintText(painter, options, true);
    }
    /// The text must be valid UTF-8 and remain immutable for the scene's
    /// lifetime, including any later presentation of the committed frame.
    pub fn drawTextBorrowed(painter: *Painter, options: Text) !void {
        return paintText(painter, options, false);
    }
    fn paintText(painter: *Painter, options: Text, comptime copy: bool) !void {
        try validateRect(options.bounds);
        try options.style.validate();
        if (copy and !std.unicode.utf8ValidateSlice(options.text)) return error.InvalidUtf8;
        const clipped = options.bounds.intersection(painter.clip());
        if (clipped.width == 0 or clipped.height == 0 or options.text.len == 0) return;
        const text = if (copy) try painter.allocator.dupe(u8, options.text) else options.text;
        var color = options.style.color;
        color.a *= painter.opacity;
        try painter.items.append(painter.allocator, .{ .kind = .text, .rect = options.bounds, .clip = clipped, .color = color, .font_size = options.style.size, .mono = options.style.mono, .text = text });
    }
    /// Records a borrowed asset view. An owning Image must remain alive until
    /// this scene has been submitted; custom elements retain it in frame cleanup.
    pub fn drawImage(painter: *Painter, asset: images.Image, bounds: g.Rect, fit: images.Fit) !void {
        return painter.drawImageTransformed(asset, bounds, fit, .identity);
    }
    /// Draw an image with a transform carried in the scene instance.
    pub fn drawImageTransformed(painter: *Painter, asset: images.Image, bounds: g.Rect, fit: images.Fit, transform: Transform) !void {
        try validateRect(bounds);
        const view = asset.view();
        try view.validate();
        if (!std.math.isFinite(transform.scale_x) or !std.math.isFinite(transform.scale_y) or transform.scale_x <= 0 or transform.scale_y <= 0 or !std.math.isFinite(transform.translate_x) or !std.math.isFinite(transform.translate_y) or !std.math.isFinite(transform.rotation) or !std.math.isFinite(transform.opacity) or transform.opacity < 0 or transform.opacity > 1) return error.InvalidDrawCommand;
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
        try painter.items.append(painter.allocator, .{ .kind = .image, .rect = rect, .clip = clipped, .color = .{ .r = 1, .g = 1, .b = 1, .a = painter.opacity }, .image = view, .uv = uv, .transform = transform });
    }
    pub fn drawAnimatedImage(painter: *Painter, asset: images.Image, bounds: g.Rect, fit: images.Fit, spec: scene.AnimationSpec) !void {
        if (!std.math.isFinite(spec.duration) or spec.duration <= 0) return error.InvalidAnimation;
        const index = painter.items.items.len;
        try painter.drawImageTransformed(asset, bounds, fit, spec.from);
        try painter.animations.append(painter.allocator, .{ .item_index = index, .spec = spec });
    }
    pub fn finish(painter: *const Painter, background: g.Color) !scene.Frame {
        if (painter.clips.items.len != 0) return error.UnbalancedClip;
        try validateColor(background);
        return .{ .items = painter.items.items, .background = background, .animations = painter.animations.items };
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
