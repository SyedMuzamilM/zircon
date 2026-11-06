//! Real GPU tests, enabled separately on macOS. Pixel checks use Apple's PNG
//! decoder through direct Zig runtime bindings, with no browser/window mock.
const std = @import("std");
const native = @import("native");
const t = std.testing;
const objc = native.objc;
extern "c" fn CGBitmapContextCreate(?*anyopaque, usize, usize, usize, usize, ?native.text.CFRef, u32) ?*anyopaque;
extern "c" fn CGContextRelease(*anyopaque) void;
extern "c" fn CGContextTranslateCTM(*anyopaque, f64, f64) void;
extern "c" fn CGContextSetGrayFillColor(*anyopaque, f64, f64) void;
extern "c" fn CGContextSetShouldAntialias(*anyopaque, bool) void;
extern "c" fn CGContextSetShouldSmoothFonts(*anyopaque, bool) void;
extern "c" fn CGContextSetAllowsFontSubpixelPositioning(*anyopaque, bool) void;
extern "c" fn CGContextSetShouldSubpixelPositionFonts(*anyopaque, bool) void;
extern "c" fn CGContextSetAllowsFontSubpixelQuantization(*anyopaque, bool) void;
extern "c" fn CGContextSetShouldSubpixelQuantizeFonts(*anyopaque, bool) void;
extern "c" fn CTFontGetGlyphsForCharacters(native.text.CFRef, [*]const u16, [*]u16, isize) bool;
extern "c" fn CTFontDrawGlyphs(native.text.CFRef, [*]const u16, [*]const objc.CGPoint, usize, *anyopaque) void;
test "fractional Metal glyph coverage matches direct CoreText rasterization" {
    const pool = objc.Pool.init();
    defer pool.deinit();
    const renderer = try native.metal.create(t.allocator);
    defer native.metal.destroy(renderer);
    var dir = t.tmpDir(.{});
    defer dir.cleanup();
    const parent = try dir.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(parent);
    const path = try std.fs.path.join(t.allocator, &.{ parent, "fractional.png" });
    defer t.allocator.free(path);
    const bounds = native.ui.Rect{ .x = 10.25, .y = 12.5, .width = 40, .height = 20 };
    try native.metal.snapshot(renderer, .{ .background = .black, .items = &.{.{ .kind = .text, .rect = bounds, .clip = .{ .width = 80, .height = 48 }, .color = .white, .font_size = 14, .mono = true, .text = "F" }} }, .{ .width = 80, .height = 48 }, path);
    const bytes = try dir.dir.readFileAlloc(t.io, "fractional.png", t.allocator, .limited(1024 * 1024));
    defer t.allocator.free(bytes);
    const data = objc.send(objc.Id, objc.class("NSData"), "dataWithBytes:length:", .{ @as(*const anyopaque, @ptrCast(bytes.ptr)), bytes.len });
    const bitmap = objc.send(objc.Id, objc.class("NSBitmapImageRep"), "imageRepWithData:", .{data});
    var reference: [80 * 48]u8 = @splat(0);
    const context = CGBitmapContextCreate(&reference, 80, 48, 8, 80, null, 7) orelse return error.ReferenceRasterFailed;
    defer CGContextRelease(context);
    CGContextSetGrayFillColor(context, 1, 1);
    CGContextSetShouldAntialias(context, true);
    CGContextSetShouldSmoothFonts(context, false);
    CGContextSetAllowsFontSubpixelPositioning(context, true);
    CGContextSetShouldSubpixelPositionFonts(context, true);
    CGContextSetAllowsFontSubpixelQuantization(context, false);
    CGContextSetShouldSubpixelQuantizeFonts(context, false);
    const layout = try renderer.text.layout("F", 14, true);
    var ascent: f64 = 0;
    var descent: f64 = 0;
    _ = native.text.CTLineGetTypographicBounds(layout.line, &ascent, &descent, null);
    const baseline = bounds.y + @max(0, (bounds.height - ascent - descent) / 2) + ascent;
    CGContextTranslateCTM(context, bounds.x, 48 - baseline);
    const font = try renderer.text.font(14, true);
    var glyph: u16 = 0;
    try t.expect(CTFontGetGlyphsForCharacters(font, &.{@as(u16, 'F')}, @ptrCast(&glyph), 1));
    CTFontDrawGlyphs(font, @ptrCast(&glyph), &.{objc.CGPoint{}}, 1, context);
    var total: f64 = 0;
    var error_sum: f64 = 0;
    for (0..80) |x| {
        var expected: f64 = 0;
        var actual: f64 = 0;
        for (0..48) |y| {
            expected += @as(f64, @floatFromInt(reference[y * 80 + x])) / 255;
            const color = objc.send(objc.Id, bitmap, "colorAtX:y:", .{ x, y });
            var red: f64 = 0;
            var green: f64 = 0;
            var blue: f64 = 0;
            var alpha: f64 = 0;
            objc.send(void, color, "getRed:green:blue:alpha:", .{ &red, &green, &blue, &alpha });
            actual += red;
        }
        total += expected;
        error_sum += @abs(actual - expected);
    }
    try t.expect(total > 10);
    try t.expect(error_sum / total < 0.03);
}
const shapes = [_]native.scene.Primitive{
    .{ .kind = .rect, .rect = .{ .x = 10, .y = 10, .width = 50, .height = 40 }, .clip = .{ .x = 20, .y = 20, .width = 20, .height = 20 }, .color = .{ .r = 1, .g = 0, .b = 0 } },
    .{ .kind = .rect, .rect = .{ .x = 25, .y = 25, .width = 20, .height = 20 }, .clip = .{ .width = 240, .height = 150 }, .color = .{ .r = 0, .g = 1, .b = 0 } },
    .{ .kind = .rect, .rect = .{ .x = 70, .y = 10, .width = 30, .height = 30 }, .clip = .{ .width = 240, .height = 150 }, .color = .{ .r = 0, .g = 0, .b = 1 }, .radius = 8 },
    .{ .kind = .text, .rect = .{ .x = 10, .y = 70, .width = 220, .height = 30 }, .clip = .{ .width = 240, .height = 150 }, .color = .white, .font_size = 16, .mono = true, .text = "Zircon UI / 日本" },
    .{ .kind = .line, .rect = .{ .x = 115, .y = 5, .width = 50, .height = 50 }, .clip = .{ .width = 240, .height = 150 }, .color = .white, .segment = .{ .start = .{ .x = 120, .y = 10 }, .end = .{ .x = 160, .y = 50 }, .width = 6 } },
    .{ .kind = .line, .rect = .{ .x = 174, .y = 14, .width = 52, .height = 12 }, .clip = .{ .x = 180, .y = 0, .width = 20, .height = 40 }, .color = .{ .r = 1, .g = 0, .b = 0 }, .segment = .{ .start = .{ .x = 180, .y = 20 }, .end = .{ .x = 220, .y = 20 }, .width = 10 } },
};
test "Metal preserves clipping painter order rounding and native glyph rendering" {
    const pool = objc.Pool.init();
    defer pool.deinit();
    const renderer = try native.metal.create(t.allocator);
    defer native.metal.destroy(renderer);
    var dir = t.tmpDir(.{});
    defer dir.cleanup();
    const parent = try dir.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(parent);
    const path = try std.fs.path.join(t.allocator, &.{ parent, "scene.png" });
    defer t.allocator.free(path);
    const frame: native.scene.Frame = .{ .items = &shapes, .background = .black };
    const descriptor = objc.send(objc.Id, objc.class("MTLTextureDescriptor"), "texture2DDescriptorWithPixelFormat:width:height:mipmapped:", .{ @as(usize, 80), @as(usize, 240), @as(usize, 150), false });
    objc.send(void, descriptor, "setStorageMode:", .{@as(usize, 0)});
    objc.send(void, descriptor, "setUsage:", .{@as(usize, 4)});
    const target = objc.send(objc.Id, renderer.device, "newTextureWithDescriptor:", .{descriptor});
    defer objc.release(target);
    try t.expect(target != null);
    for (0..8) |_| try native.metal.draw(renderer, frame, .{ .width = 240, .height = 150 }, 1, target, null, false);
    try native.metal.snapshot(renderer, frame, .{ .width = 240, .height = 150 }, path);
    const bytes = try dir.dir.readFileAlloc(t.io, "scene.png", t.allocator, .limited(4 * 1024 * 1024));
    defer t.allocator.free(bytes);
    try t.expect(std.mem.startsWith(u8, bytes, "\x89PNG\r\n\x1a\n"));
    const data = objc.send(objc.Id, objc.class("NSData"), "dataWithBytes:length:", .{ @as(*const anyopaque, @ptrCast(bytes.ptr)), bytes.len });
    const bitmap = objc.send(objc.Id, objc.class("NSBitmapImageRep"), "imageRepWithData:", .{data});
    try t.expect(bitmap != null);
    try pixel(bitmap, 15, 15, .{ 0, 0, 0 });
    try pixel(bitmap, 22, 22, .{ 1, 0, 0 });
    try pixel(bitmap, 30, 30, .{ 0, 1, 0 });
    try pixel(bitmap, 42, 22, .{ 0, 0, 0 });
    try pixel(bitmap, 70, 10, .{ 0, 0, 0 });
    try pixel(bitmap, 85, 25, .{ 0, 0, 1 });
    try pixel(bitmap, 140, 30, .{ 1, 1, 1 });
    try pixel(bitmap, 118, 9, .{ 1, 1, 1 }); // Round cap extends past endpoint.
    try pixel(bitmap, 120, 30, .{ 0, 0, 0 }); // Outside diagonal stroke.
    try pixel(bitmap, 190, 20, .{ 1, 0, 0 });
    try pixel(bitmap, 201, 20, .{ 0, 0, 0 }); // Clip cuts the stroke itself.
    const stats = native.metal.stats(renderer);
    try t.expectEqual(@as(u64, 9), stats.frames);
    try t.expect(stats.glyphs > 0);
    try t.expectEqual(@as(usize, 4 * 1024 * 1024), stats.atlas_bytes);
    try t.expect(stats.layout_bytes <= 4 * 1024 * 1024);
    try t.expect(stats.instance_bytes > 0);
    var invalid = shapes[4];
    invalid.segment.?.width = std.math.nan(f32);
    try t.expectError(error.InvalidScene, native.metal.snapshot(renderer, .{ .items = &.{invalid}, .background = .black }, .{ .width = 240, .height = 150 }, path));
    invalid.segment = null;
    try t.expectError(error.InvalidScene, native.metal.snapshot(renderer, .{ .items = &.{invalid}, .background = .black }, .{ .width = 240, .height = 150 }, path));
}
fn pixel(bitmap: objc.Id, x: usize, y: usize, expected: [3]f64) !void {
    const color = objc.send(objc.Id, bitmap, "colorAtX:y:", .{ x, y });
    var red: f64 = 0;
    var green: f64 = 0;
    var blue: f64 = 0;
    var alpha: f64 = 0;
    objc.send(void, color, "getRed:green:blue:alpha:", .{ &red, &green, &blue, &alpha });
    try t.expectApproxEqAbs(expected[0], red, 0.02);
    try t.expectApproxEqAbs(expected[1], green, 0.02);
    try t.expectApproxEqAbs(expected[2], blue, 0.02);
    try t.expectApproxEqAbs(@as(f64, 1), alpha, 0.02);
}

test "renderer allocation failure unwinds native resource initialization" {
    const pool = objc.Pool.init();
    defer pool.deinit();
    for (0..2) |index| {
        var failing = std.testing.FailingAllocator.init(t.allocator, .{ .fail_index = index });
        try t.expectError(error.OutOfMemory, native.metal.create(failing.allocator()));
    }
}
