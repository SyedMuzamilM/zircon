//! Image ownership stays outside frame arenas. Each committed image element
//! retains the immutable decoded pixels until the frame is retired.
const std = @import("std");
const ui = @import("zircon_ui");
const shell = @import("../shell.zig");
const components = @import("components.zig");
pub const Image = ui.graphics.images.Image;
pub const Asset = struct {
    path: []u8,
    image: Image,
    pub fn init(a: std.mem.Allocator, io: std.Io, path: []const u8) !Asset {
        const encoded = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(ui.graphics.images.max_bytes));
        defer a.free(encoded);
        var image = try Image.load(a, encoded);
        errdefer image.deinit();
        return .{ .image = image, .path = try a.dupe(u8, path) };
    }
    pub fn deinit(self: *Asset, a: std.mem.Allocator) void {
        self.image.deinit();
        a.free(self.path);
    }
};
pub fn supported(path: []const u8) bool {
    const extension = std.fs.path.extension(path);
    for ([_][]const u8{ ".png", ".jpg", ".jpeg", ".gif", ".tif", ".tiff", ".bmp", ".webp" }) |candidate| if (std.ascii.eqlIgnoreCase(extension, candidate)) return true;
    return false;
}

pub fn element(b: *ui.Ui, image: Image, style: ui.Style) !ui.Element {
    var owned = image.clone();
    errdefer owned.deinit();
    return b.custom(Canvas, .{ .image = owned }, style);
}
const Canvas = struct {
    image: Image,
    zoom: ?f32 = null,
    scroll: ui.Point = .{},
    pub const LayoutState = void;
    pub const PrepaintState = void;
    pub fn requestLayout(_: *Canvas, cx: *ui.LayoutCx) !ui.LayoutResult(void) {
        return .{ .size = cx.available, .state = {} };
    }
    pub fn prepaint(_: *Canvas, _: *ui.PrepaintCx, _: ui.Rect, _: *void) !void {}
    pub fn paint(self: *Canvas, cx: *ui.PaintCx, bounds: ui.Rect, _: *void, _: *void) !void {
        try cx.painter.pushClip(bounds);
        defer cx.painter.popClip();
        const size = self.image.size();
        const rect = if (self.zoom) |zoom| ui.Rect{ .x = bounds.x + @max(0, (bounds.width - size.width * zoom) / 2) - self.scroll.x, .y = bounds.y + @max(0, (bounds.height - size.height * zoom) / 2) - self.scroll.y, .width = size.width * zoom, .height = size.height * zoom } else bounds;
        try cx.painter.drawImage(self.image, rect, .contain);
    }
    pub fn deinit(self: *Canvas) void {
        self.image.deinit();
    }
};
fn zoomElement(b: *ui.Ui, source: Image, zoom: f32, scroll: ui.Point) !ui.Element {
    var owned = source.clone();
    errdefer owned.deinit();
    return b.custom(Canvas, .{ .image = owned, .zoom = zoom, .scroll = scroll }, .{ .flex_grow = 1, .min_height = .{ .px = 0 }, .overflow = .hidden });
}

pub fn render(self: *const shell.Shell, b: *ui.Ui) !ui.Element {
    const c = self.colors;
    const asset = self.image orelse return error.NoImage;
    const size = asset.image.size();
    const v = components;
    const canvas = try zoomElement(b, asset.image, self.image_zoom, self.image_scroll);
    var path: []const u8 = asset.path;
    if (std.mem.startsWith(u8, path, self.workspace.root_path)) path = std.mem.trimStart(u8, path[self.workspace.root_path.len..], "/");
    return b.fluent().div()
        .grow()
        .min_h(.{ .px = 0 })
        .background(c.document)
        .overflow_hidden()
        .flex_col()
        .children(&.{
            try b.fluent().div()
                .h(.{ .px = v.metrics.file_header })
                .shrink_0()
                .gap_px(8)
                .items_center()
                .padding(.{ .left = 13, .right = 7 })
                .background(c.document)
                .flex()
                .children(.{
                    b.fluent().adopt(try v.text(b, path, c.muted, 12))
                        .style(.{ .flex_grow = 1, .min_width = .{ .px = 0 }, .overflow = .hidden }),
                    v.iconButton(b, c, .image_zoom_out, "Zoom image out", .minus, false),
                    v.actionButton(b, c, .image_zoom_reset, try std.fmt.allocPrint(b.allocator(), "{d:.0}%", .{self.image_zoom * 100}), false),
                    v.iconButton(b, c, .image_zoom_in, "Zoom image in", .plus, false),
                }).build(),
            try b.fluent().adopt(canvas)
                .id(.{ .string = "image-canvas" })
                .listeners(.{ .on_input = b.onInput(onInput) })
                .build(),
            try b.fluent().div()
                .h(.{ .px = 22 })
                .shrink_0()
                .padding(.{ .left = 13 })
                .items_center()
                .flex()
                .children(.{
                    v.text(b, try std.fmt.allocPrint(b.allocator(), "{d:.0} × {d:.0} px · {s}", .{ size.width, size.height, std.fs.path.extension(asset.path) }), c.muted, 11),
                }).build(),
        }).build();
}

fn onInput(self: *shell.Shell, event: *ui.Event(ui.Input), cx: *ui.Context(shell.Shell)) void {
    if (event.data != .scroll or self.image == null) return;
    const size = self.image.?.image.size();
    self.image_scroll.x = std.math.clamp(self.image_scroll.x + event.data.scroll.x, 0, @max(0, size.width * self.image_zoom - event.bounds.width));
    self.image_scroll.y = std.math.clamp(self.image_scroll.y + event.data.scroll.y, 0, @max(0, size.height * self.image_zoom - event.bounds.height));
    event.preventDefault();
    cx.notify();
}
