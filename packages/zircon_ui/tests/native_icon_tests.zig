const std = @import("std");
const native = @import("native");
const objc = native.objc;
const t = std.testing;

fn bitmap(image: objc.Id) !objc.Id {
    const representations = objc.send(objc.Id, image, "representations", .{});
    try t.expect(objc.send(usize, representations, "count", .{}) > 0);
    return objc.send(objc.Id, representations, "objectAtIndex:", .{@as(usize, 0)}) orelse error.NativeIconUnavailable;
}
fn colorAtCenter(image: objc.Id) ![4]f64 {
    const data = objc.send(objc.Id, image, "TIFFRepresentation", .{});
    const rep = objc.send(objc.Id, objc.class("NSBitmapImageRep"), "imageRepWithData:", .{data}) orelse return error.NativeIconUnavailable;
    const pixel_color = objc.send(objc.Id, rep, "colorAtX:y:", .{ objc.send(usize, rep, "pixelsWide", .{}) / 2, objc.send(usize, rep, "pixelsHigh", .{}) / 2 });
    const color = objc.send(objc.Id, pixel_color, "colorUsingColorSpace:", .{objc.send(objc.Id, objc.class("NSColorSpace"), "sRGBColorSpace", .{})});
    var result: [4]f64 = undefined;
    objc.send(void, color, "getRed:green:blue:alpha:", .{ &result[0], &result[1], &result[2], &result[3] });
    return result;
}
test "native icon copies premultiplied RGBA before releasing its image asset" {
    const pool = objc.Pool.init();
    defer pool.deinit();
    var image = try native.images.Image.fromRgba(t.allocator, 2, 1, &.{ 200, 100, 50, 128, 0, 255, 0, 255 });
    const icon = native.icon.create(image.view()) catch |err| {
        image.deinit();
        return err;
    };
    defer objc.release(icon);
    image.deinit();
    const rep = try bitmap(icon);
    try t.expectEqual(@as(usize, 2), objc.send(usize, rep, "pixelsWide", .{}));
    try t.expectEqual(@as(usize, 1), objc.send(usize, rep, "pixelsHigh", .{}));
    const bytes = objc.send(?[*]const u8, rep, "bitmapData", .{}) orelse return error.NativeIconUnavailable;
    try t.expectEqualSlices(u8, &.{ 100, 50, 25, 128, 0, 255, 0, 255 }, bytes[0..8]);
    try t.expect(objc.send(bool, objc.send(objc.Id, rep, "colorSpace", .{}), "isEqual:", .{objc.send(objc.Id, objc.class("NSColorSpace"), "sRGBColorSpace", .{})}));
}
test "application icon reaches AppKit after caller releases its reference" {
    const pool = objc.Pool.init();
    defer pool.deinit();
    const application = objc.send(objc.Id, objc.class("NSApplication"), "sharedApplication", .{});
    const previous = objc.retain(objc.send(objc.Id, application, "applicationIconImage", .{}));
    defer {
        objc.send(void, application, "setApplicationIconImage:", .{previous});
        objc.release(previous);
    }
    const View = struct {
        pub fn render(_: *const @This(), b: *native.ui.Ui) !native.ui.Element {
            return b.text("Icon ownership");
        }
    };
    var pixels: [16 * 16 * 4]u8 = undefined;
    for (0..16 * 16) |index| @memcpy(pixels[index * 4 ..][0..4], &[_]u8{ 255, 0, 0, 255 });
    var image = try native.images.Image.fromRgba(t.allocator, 16, 16, &pixels);
    var app = native.ui.App.init(.{ .allocator = t.allocator, .icon = image }) catch |err| {
        image.deinit();
        return err;
    };
    defer app.deinit();
    image.deinit();
    _ = try app.openWindow(View, .{ .visible = false }, .{});
    _ = try app.step(0);
    const icon = objc.send(objc.Id, application, "applicationIconImage", .{});
    const actual_color = try colorAtCenter(icon);
    // AppKit snapshots into the display's extended color space. Raw bitmap
    // fidelity is checked above; here the stored icon must remain opaque red.
    try t.expect(actual_color[0] > actual_color[1] + 0.5);
    try t.expect(actual_color[0] > actual_color[2] + 0.5);
    try t.expectApproxEqAbs(@as(f64, 1), actual_color[3], 0.01);
}

test "a discarded native window cannot publish its pending application icon" {
    const pool = objc.Pool.init();
    defer pool.deinit();
    const application = objc.send(objc.Id, objc.class("NSApplication"), "sharedApplication", .{});
    const before = objc.retain(objc.send(objc.Id, application, "applicationIconImage", .{}));
    defer objc.release(before);
    const Sink = struct {
        fn event(_: *anyopaque, _: native.ui.Input) !void {}
    };
    var context: u8 = 0;
    var image = try native.images.Image.fromRgba(t.allocator, 1, 1, &.{ 0, 255, 0, 255 });
    defer image.deinit();
    const surface = try native.window.open(t.allocator, .{ .visible = false, .icon = image.view() }, .{ .context = &context, .event = Sink.event });
    surface.deinit();
    try t.expectEqual(before, objc.send(objc.Id, application, "applicationIconImage", .{}));
}
