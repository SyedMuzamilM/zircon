//! Actual decoder and Metal texture tests. No browser or UI-process focus is
//! needed: offscreen GPU output is decoded and checked at known pixel centers.
const std = @import("std");
const native = @import("native");
const t = std.testing;
const objc = native.objc;
const pattern = [_]u8{
    255, 0, 0,   255, 0,   255, 0,   255,
    0,   0, 255, 255, 255, 255, 255, 255,
};
fn encode(a: std.mem.Allocator, pixels: []const u8, width: usize, height: usize, format: usize) ![]u8 {
    const bitmap = objc.send(objc.Id, objc.send(objc.Id, objc.class("NSBitmapImageRep"), "alloc", .{}), "initWithBitmapDataPlanes:pixelsWide:pixelsHigh:bitsPerSample:samplesPerPixel:hasAlpha:isPlanar:colorSpaceName:bitmapFormat:bytesPerRow:bitsPerPixel:", .{ @as(?*anyopaque, null), width, height, @as(usize, 8), @as(usize, 4), true, false, objc.string("NSDeviceRGBColorSpace"), @as(usize, 2), width * 4, @as(usize, 32) }) orelse return error.BitmapUnavailable;
    defer objc.release(bitmap);
    const raw = objc.send(?[*]u8, bitmap, "bitmapData", .{}) orelse return error.BitmapUnavailable;
    @memcpy(raw[0..pixels.len], pixels);
    const properties = objc.send(objc.Id, objc.class("NSDictionary"), "dictionary", .{});
    const data = objc.send(objc.Id, bitmap, "representationUsingType:properties:", .{ format, properties }) orelse return error.BitmapUnavailable;
    const bytes = objc.send(?[*]const u8, data, "bytes", .{}) orelse return error.BitmapUnavailable;
    const length = objc.send(usize, data, "length", .{});
    return a.dupe(u8, bytes[0..length]);
}
test "ImageIO decodes PNG JPEG and GIF first frames into top-left RGBA" {
    const pool = objc.Pool.init();
    defer pool.deinit();
    for ([_]usize{ 4, 3, 2 }) |format| {
        const encoded = try encode(t.allocator, &pattern, 2, 2, format);
        defer t.allocator.free(encoded);
        var image = try native.images.Image.load(t.allocator, encoded);
        defer image.deinit();
        try t.expectEqual(@as(u32, 2), image.view().width);
        try t.expectEqual(@as(u32, 2), image.view().height);
        if (format != 3) try t.expectEqualSlices(u8, &pattern, image.view().pixels);
    }
    try t.expectError(error.InvalidImage, native.images.Image.load(t.allocator, "not an image"));
}
test "ImageIO preserves premultiplied alpha and rejects decode allocation failure" {
    const pool = objc.Pool.init();
    defer pool.deinit();
    const pixels = [_]u8{ 200, 100, 50, 128, 0, 255, 0, 0 };
    const encoded = try encode(t.allocator, &pixels, 2, 1, 4);
    defer t.allocator.free(encoded);
    var image = try native.images.Image.load(t.allocator, encoded);
    defer image.deinit();
    const decoded = image.view().pixels;
    try t.expect(@abs(@as(i16, 100) - decoded[0]) <= 1);
    try t.expect(@abs(@as(i16, 50) - decoded[1]) <= 1);
    try t.expect(@abs(@as(i16, 25) - decoded[2]) <= 1);
    try t.expectEqual(@as(u8, 128), decoded[3]);
    try t.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, decoded[4..8]);
    for (0..2) |fail| {
        var allocator = t.FailingAllocator.init(t.allocator, .{ .fail_index = fail });
        try t.expectError(error.OutOfMemory, native.images.Image.load(allocator.allocator(), encoded));
    }
}
fn bitmapFromBytes(bytes: []const u8) !objc.Id {
    const data = objc.send(objc.Id, objc.class("NSData"), "dataWithBytes:length:", .{ @as(*const anyopaque, bytes.ptr), bytes.len });
    return objc.send(objc.Id, objc.class("NSBitmapImageRep"), "imageRepWithData:", .{data}) orelse error.BitmapUnavailable;
}
fn pixel(bitmap: objc.Id, x: usize, y: usize, expected: [3]f64) !void {
    const color = objc.send(objc.Id, bitmap, "colorAtX:y:", .{ x, y });
    var r: f64 = 0;
    var g: f64 = 0;
    var b: f64 = 0;
    var a: f64 = 0;
    objc.send(void, color, "getRed:green:blue:alpha:", .{ &r, &g, &b, &a });
    try t.expectApproxEqAbs(expected[0], r, 0.025);
    try t.expectApproxEqAbs(expected[1], g, 0.025);
    try t.expectApproxEqAbs(expected[2], b, 0.025);
    try t.expectApproxEqAbs(@as(f64, 1), a, 0.025);
}
test "Metal image sampling preserves orientation alpha clipping and painter order" {
    const pool = objc.Pool.init();
    defer pool.deinit();
    var image = try native.images.Image.fromRgba(t.allocator, 2, 2, &pattern);
    defer image.deinit();
    var alpha = try native.images.Image.fromRgba(t.allocator, 1, 1, &.{ 255, 0, 0, 128 });
    defer alpha.deinit();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var painter = try native.Painter.init(arena.allocator(), .{ .width = 100, .height = 100 });
    try painter.drawImage(image, .{ .x = 0, .y = 0, .width = 40, .height = 40 }, .stretch);
    try painter.fillRect(.{ .bounds = .{ .x = 45, .y = 0, .width = 40, .height = 40 }, .color = .{ .r = 0, .g = 0, .b = 1 } });
    try painter.drawImage(alpha, .{ .x = 45, .y = 0, .width = 40, .height = 40 }, .stretch);
    try painter.pushClip(.{ .x = 0, .y = 60, .width = 20, .height = 20 });
    painter.opacity = 0.5;
    try painter.drawImage(image, .{ .x = 0, .y = 50, .width = 40, .height = 40 }, .stretch);
    painter.popClip();
    painter.opacity = 1;
    try painter.fillRect(.{ .bounds = .{ .x = 5, .y = 5, .width = 5, .height = 5 }, .color = .{ .r = 1, .g = 1, .b = 0 } });
    try painter.drawText(.{ .bounds = .{ .x = 50, .y = 60, .width = 40, .height = 20 }, .text = "Image", .style = .{ .size = 12 } });
    const frame = try painter.finish(.black);
    const renderer = try native.metal.create(t.allocator);
    defer native.metal.destroy(renderer);
    var dir = t.tmpDir(.{});
    defer dir.cleanup();
    const parent = try dir.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(parent);
    const path = try std.fs.path.join(t.allocator, &.{ parent, "images.png" });
    defer t.allocator.free(path);
    try native.metal.snapshot(renderer, frame, .{ .width = 100, .height = 100 }, path);
    const bytes = try dir.dir.readFileAlloc(t.io, "images.png", t.allocator, .limited(1024 * 1024));
    defer t.allocator.free(bytes);
    const bitmap = try bitmapFromBytes(bytes);
    try pixel(bitmap, 2, 2, .{ 1, 0, 0 });
    try pixel(bitmap, 35, 2, .{ 0, 1, 0 });
    try pixel(bitmap, 2, 35, .{ 0, 0, 1 });
    try pixel(bitmap, 35, 35, .{ 1, 1, 1 });
    try pixel(bitmap, 60, 15, .{ 128.0 / 255.0, 0, 127.0 / 255.0 });
    try pixel(bitmap, 7, 7, .{ 1, 1, 0 });
    try pixel(bitmap, 10, 55, .{ 0, 0, 0 });
    try pixel(bitmap, 2, 79, .{ 0, 0, 0.5 });
    try pixel(bitmap, 30, 75, .{ 0, 0, 0 });
    var text_pixels: usize = 0;
    for (60..80) |y| for (50..90) |x| {
        const color = objc.send(objc.Id, bitmap, "colorAtX:y:", .{ x, y });
        var red: f64 = 0;
        var green: f64 = 0;
        var blue: f64 = 0;
        var alpha_value: f64 = 0;
        objc.send(void, color, "getRed:green:blue:alpha:", .{ &red, &green, &blue, &alpha_value });
        if (red > 0.5 and green > 0.5 and blue > 0.5) text_pixels += 1;
    };
    try t.expect(text_pixels > 10);
    const first = native.metal.stats(renderer);
    try t.expectEqual(@as(u64, 2), first.image_uploads);
    try t.expect(first.glyphs > 0);
    try t.expectEqual(@as(usize, 20), first.image_bytes);
    try native.metal.snapshot(renderer, frame, .{ .width = 100, .height = 100 }, path);
    const second = native.metal.stats(renderer);
    try t.expectEqual(first.image_uploads, second.image_uploads);
    try t.expect(second.image_hits > first.image_hits);
}

extern "c" const kCGImagePropertyOrientation: *const anyopaque;
extern "c" fn CGImageSourceCreateWithData(objc.Id, objc.Id) objc.Id;
extern "c" fn CGImageSourceCreateImageAtIndex(objc.Id, usize, objc.Id) objc.Id;
extern "c" fn CGImageDestinationCreateWithData(objc.Id, objc.Id, usize, objc.Id) objc.Id;
extern "c" fn CGImageDestinationAddImage(objc.Id, objc.Id, objc.Id) void;
extern "c" fn CGImageDestinationFinalize(objc.Id) bool;
extern "c" fn CFRelease(*const anyopaque) void;
test "ImageIO applies JPEG EXIF orientation before publishing dimensions" {
    const pool = objc.Pool.init();
    defer pool.deinit();
    var pixels: [8 * 4 * 4]u8 = undefined;
    for (0..8 * 4) |i| {
        @memcpy(pixels[i * 4 ..][0..4], if (i / 8 < 2) &[_]u8{ 255, 0, 0, 255 } else &[_]u8{ 0, 0, 255, 255 });
    }
    const png = try encode(t.allocator, &pixels, 8, 4, 4);
    defer t.allocator.free(png);
    const data = objc.send(objc.Id, objc.class("NSData"), "dataWithBytes:length:", .{ @as(*const anyopaque, png.ptr), png.len });
    const source = CGImageSourceCreateWithData(data, null) orelse return error.BitmapUnavailable;
    defer CFRelease(source);
    const cgimage = CGImageSourceCreateImageAtIndex(source, 0, null) orelse return error.BitmapUnavailable;
    defer CFRelease(cgimage);
    const out = objc.send(objc.Id, objc.class("NSMutableData"), "data", .{});
    const destination = CGImageDestinationCreateWithData(out, objc.string("public.jpeg"), 1, null) orelse return error.BitmapUnavailable;
    defer CFRelease(destination);
    const rotation = objc.send(objc.Id, objc.class("NSNumber"), "numberWithInt:", .{@as(c_int, 6)});
    const properties = objc.send(objc.Id, objc.class("NSDictionary"), "dictionaryWithObject:forKey:", .{ rotation, @as(objc.Id, @constCast(kCGImagePropertyOrientation)) });
    CGImageDestinationAddImage(destination, cgimage, properties);
    try t.expect(CGImageDestinationFinalize(destination));
    const bytes = objc.send(?[*]const u8, out, "bytes", .{}) orelse return error.BitmapUnavailable;
    const length = objc.send(usize, out, "length", .{});
    var image = try native.images.Image.load(t.allocator, bytes[0..length]);
    defer image.deinit();
    try t.expectEqual(@as(u32, 4), image.view().width);
    try t.expectEqual(@as(u32, 8), image.view().height);
}
test "Metal image cache eviction keeps earlier batches and in-flight textures alive" {
    const pool = objc.Pool.init();
    defer pool.deinit();
    var assets: [70]native.images.Image = undefined;
    var initialized: usize = 0;
    defer for (assets[0..initialized]) |*asset| asset.deinit();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var painter = try native.Painter.init(arena.allocator(), .{ .width = 70, .height = 4 });
    for (&assets, 0..) |*asset, i| {
        asset.* = try native.images.Image.fromRgba(t.allocator, 1, 1, &.{ @intCast(i * 3), @intCast(255 - i * 3), 0, 255 });
        initialized += 1;
        try painter.drawImage(asset.*, .{ .x = @floatFromInt(i), .width = 1, .height = 4 }, .stretch);
    }
    const frame = try painter.finish(.black);
    const renderer = try native.metal.create(t.allocator);
    defer native.metal.destroy(renderer);
    const descriptor = objc.send(objc.Id, objc.class("MTLTextureDescriptor"), "texture2DDescriptorWithPixelFormat:width:height:mipmapped:", .{ @as(usize, 80), @as(usize, 70), @as(usize, 4), false });
    objc.send(void, descriptor, "setStorageMode:", .{@as(usize, 0)});
    objc.send(void, descriptor, "setUsage:", .{@as(usize, 4)});
    const target = objc.send(objc.Id, renderer.device, "newTextureWithDescriptor:", .{descriptor}) orelse return error.BitmapUnavailable;
    defer objc.release(target);
    for (0..8) |_| try native.metal.draw(renderer, frame, .{ .width = 70, .height = 4 }, 1, target, null, false);
    const stats = native.metal.stats(renderer);
    try t.expectEqual(@as(usize, 64), stats.image_textures);
    try t.expectEqual(@as(usize, 64 * 4), stats.image_bytes);
    var dir = t.tmpDir(.{});
    defer dir.cleanup();
    const parent = try dir.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(parent);
    const path = try std.fs.path.join(t.allocator, &.{ parent, "cache.png" });
    defer t.allocator.free(path);
    try native.metal.snapshot(renderer, frame, .{ .width = 70, .height = 4 }, path);
    const png = try dir.dir.readFileAlloc(t.io, "cache.png", t.allocator, .limited(1024 * 1024));
    defer t.allocator.free(png);
    const bitmap = try bitmapFromBytes(png);
    try pixel(bitmap, 0, 1, .{ 0, 1, 0 });
    try pixel(bitmap, 69, 1, .{ 207.0 / 255.0, 48.0 / 255.0, 0 });
    // Teardown below waits pending submissions before releasing all resources.
    try native.metal.draw(renderer, frame, .{ .width = 70, .height = 4 }, 1, target, null, false);
}

test "failed image scene preparation releases retained batch textures" {
    const pool = objc.Pool.init();
    defer pool.deinit();
    var image = try native.images.Image.fromRgba(t.allocator, 2, 2, &pattern);
    defer image.deinit();
    const items = [_]native.scene.Primitive{.{ .kind = .image, .rect = .{ .width = 10, .height = 10 }, .clip = .{ .width = 10, .height = 10 }, .color = .white, .image = image.view() }};
    for (0..3) |extra| {
        var failing = t.FailingAllocator.init(t.allocator, .{});
        const renderer = try native.metal.create(failing.allocator());
        defer native.metal.destroy(renderer);
        const descriptor = objc.send(objc.Id, objc.class("MTLTextureDescriptor"), "texture2DDescriptorWithPixelFormat:width:height:mipmapped:", .{ @as(usize, 80), @as(usize, 10), @as(usize, 10), false });
        objc.send(void, descriptor, "setStorageMode:", .{@as(usize, 0)});
        objc.send(void, descriptor, "setUsage:", .{@as(usize, 4)});
        const target = objc.send(objc.Id, renderer.device, "newTextureWithDescriptor:", .{descriptor}) orelse return error.BitmapUnavailable;
        defer objc.release(target);
        failing.fail_index = failing.alloc_index + extra;
        try t.expectError(error.OutOfMemory, native.metal.draw(renderer, .{ .items = &items, .background = .black }, .{ .width = 10, .height = 10 }, 1, target, null, false));
        try t.expectEqual(@as(u64, 0), native.metal.stats(renderer).frames);
    }
}
