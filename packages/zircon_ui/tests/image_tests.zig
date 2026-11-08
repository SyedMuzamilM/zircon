//! Portable asset/painter behavior; decoding and GPU pixels have native tests.
const std = @import("std");
const ui = @import("zircon_ui");
const images = ui.graphics.images;
const t = std.testing;
const rgba = [_]u8{ 255, 128, 64, 128, 0, 255, 0, 255 };
test "application retains an icon and validates a window override before taking its model" {
    const View = struct {
        pub fn render(_: *const @This(), b: *ui.Ui) !ui.Element {
            return b.text("Icon");
        }
    };
    var image = try images.Image.fromRgba(t.allocator, 1, 1, &.{ 12, 34, 56, 255 });
    const pixels = image.view().pixels;
    var app = ui.App.init(.{ .allocator = t.allocator, .icon = image }) catch |err| {
        image.deinit();
        return err;
    };
    defer app.deinit();
    image.deinit();
    _ = try app.openWindow(View, .{ .visible = false }, .{});
    try t.expectEqualSlices(u8, &.{ 12, 34, 56, 255 }, pixels);
    try t.expectError(error.InvalidImage, app.openWindow(View, .{ .visible = false, .icon = .{ .id = 0, .width = 1, .height = 1, .pixels = pixels } }, .{}));
}
test "image assets copy once premultiply alpha and retain immutable identity" {
    var input = rgba;
    var image = try images.Image.fromRgba(t.allocator, 2, 1, &input);
    var clone = image.clone();
    defer clone.deinit();
    try t.expectEqual(image.id(), clone.id());
    try t.expectEqual(ui.Size{ .width = 2, .height = 1 }, image.size());
    @memset(&input, 0);
    try t.expectEqualSlices(u8, &.{ 128, 64, 32, 128, 0, 255, 0, 255 }, image.view().pixels);
    image.deinit();
    try t.expectEqual(@as(u8, 255), clone.view().pixels[5]);
    var other = try images.Image.fromRgba(t.allocator, 2, 1, &rgba);
    defer other.deinit();
    try t.expect(other.id() != clone.id());
}
test "image limits reject overflow invalid byte lengths and invalid identities" {
    try t.expectError(error.InvalidImageSize, images.Image.fromRgba(t.allocator, 0, 1, ""));
    try t.expectError(error.InvalidImageSize, images.Image.fromRgba(t.allocator, 16385, 1, ""));
    try t.expectError(error.ImageTooLarge, images.Image.fromRgba(t.allocator, 16384, 16384, ""));
    try t.expectError(error.InvalidImage, images.Image.fromRgba(t.allocator, 2, 1, "short"));
    try t.expectError(error.InvalidImage, (images.View{ .id = 0, .width = 2, .height = 1, .pixels = &rgba }).validate());
}
test "image fit geometry clips contain cover and stretch without copying pixels" {
    var image = try images.Image.fromRgba(t.allocator, 2, 1, &rgba);
    defer image.deinit();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var painter = try ui.graphics.Painter.init(arena.allocator(), .{ .width = 100, .height = 100 });
    painter.opacity = 0.5;
    try painter.drawImage(image, .{ .width = 100, .height = 100 }, .contain);
    try painter.drawImage(image, .{ .width = 100, .height = 100 }, .cover);
    try painter.pushClip(.{ .x = 25, .y = 25, .width = 25, .height = 25 });
    try painter.drawImage(image, .{ .width = 100, .height = 100 }, .stretch);
    painter.popClip();
    const frame = try painter.finish(.black);
    try t.expectEqual(@as(usize, 3), frame.items.len);
    try t.expectEqual(ui.Rect{ .x = 0, .y = 25, .width = 100, .height = 50 }, frame.items[0].rect);
    try t.expectEqual(ui.Rect{ .x = 0.25, .width = 0.5, .height = 1 }, frame.items[1].uv);
    try t.expectEqual(ui.Rect{ .x = 25, .y = 25, .width = 25, .height = 25 }, frame.items[2].clip);
    try t.expectEqual(@as(f32, 0.5), frame.items[0].color.a);
    try t.expectEqual(image.view().pixels.ptr, frame.items[0].image.?.pixels.ptr);
}
test "image construction allocation failure leaves source ownership unchanged" {
    try t.checkAllAllocationFailures(t.allocator, allocationCase, .{});
}
fn allocationCase(a: std.mem.Allocator) !void {
    var image = try images.Image.fromRgba(a, 2, 1, &rgba);
    defer image.deinit();
    try t.expectEqual(@as(u8, 255), rgba[0]);
}
