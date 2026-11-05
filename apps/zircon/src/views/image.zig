//! Image ownership stays outside frame arenas. Each committed image element
//! retains the immutable decoded pixels until the frame is retired.
const std = @import("std");
const ui = @import("zircon_ui");
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
    pub const LayoutState = void;
    pub const PrepaintState = void;
    pub fn requestLayout(_: *Canvas, cx: *ui.LayoutCx) !ui.LayoutResult(void) {
        return .{ .size = cx.available, .state = {} };
    }
    pub fn prepaint(_: *Canvas, _: *ui.PrepaintCx, _: ui.Rect, _: *void) !void {}
    pub fn paint(self: *Canvas, cx: *ui.PaintCx, bounds: ui.Rect, _: *void, _: *void) !void {
        try cx.painter.pushClip(bounds);
        defer cx.painter.popClip();
        try cx.painter.drawImage(self.image, bounds, .contain);
    }
    pub fn deinit(self: *Canvas) void {
        self.image.deinit();
    }
};
pub fn render(self: *const @import("../shell.zig").Shell, b: *ui.Ui) !ui.Element {
    const c = self.colors;
    const asset = self.image orelse return error.NoImage;
    const size = asset.image.size();
    const view = @import("../view.zig");
    return b.column(.{ .flex_grow = 1, .background = c.document, .overflow = .hidden }, &.{
        try b.row(.{ .height = .{ .px = 38 }, .flex_shrink = 0, .gap = 12, .align_items = .center, .padding = .{ .left = 16, .right = 16 }, .background = c.chrome }, &.{
            try view.commandButton(b, c, .back_to_editor, "Editor", false),
            try b.styled(try b.text(std.fs.path.basename(asset.path)), .{ .flex_grow = 1, .text = .{ .size = 13, .color = c.text } }),
            try b.styled(try b.textFmt("{d:.0} × {d:.0} px", .{ size.width, size.height }), .{ .text = .{ .size = 12, .color = c.muted } }),
        }),
        try element(b, asset.image, .{ .flex_grow = 1, .min_height = .{ .px = 0 }, .padding = ui.Insets.all(24), .overflow = .hidden }),
    });
}
