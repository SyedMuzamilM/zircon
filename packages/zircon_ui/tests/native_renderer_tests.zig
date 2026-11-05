//! Real GPU tests, enabled separately on macOS. Pixel checks use Apple's PNG
//! decoder through direct Zig runtime bindings, with no browser/window mock.
const std = @import("std");
const native = @import("native");
const t = std.testing;
const objc = native.objc;
const shapes = [_]native.scene.Primitive{
    .{ .kind = .rect, .rect = .{ .x = 10, .y = 10, .width = 50, .height = 40 }, .clip = .{ .x = 20, .y = 20, .width = 20, .height = 20 }, .color = .{ .r = 1, .g = 0, .b = 0 } },
    .{ .kind = .rect, .rect = .{ .x = 25, .y = 25, .width = 20, .height = 20 }, .clip = .{ .width = 240, .height = 150 }, .color = .{ .r = 0, .g = 1, .b = 0 } },
    .{ .kind = .rect, .rect = .{ .x = 70, .y = 10, .width = 30, .height = 30 }, .clip = .{ .width = 240, .height = 150 }, .color = .{ .r = 0, .g = 0, .b = 1 }, .radius = 8 },
    .{ .kind = .text, .rect = .{ .x = 10, .y = 70, .width = 220, .height = 30 }, .clip = .{ .width = 240, .height = 150 }, .color = .white, .font_size = 16, .mono = true, .text = "Zircon UI / 日本" },
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
    const stats = native.metal.stats(renderer);
    try t.expectEqual(@as(u64, 9), stats.frames);
    try t.expect(stats.glyphs > 0);
    try t.expectEqual(@as(usize, 4 * 1024 * 1024), stats.atlas_bytes);
    try t.expect(stats.layout_bytes <= 4 * 1024 * 1024);
    try t.expect(stats.instance_bytes > 0);
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
