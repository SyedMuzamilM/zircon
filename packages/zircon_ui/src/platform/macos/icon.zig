//! AppKit owns an independent bitmap copy. No Image view or allocator escapes
//! the call, and the application retains the resulting NSImage after creation.
const std = @import("std");
const images = @import("../../graphics/images.zig");
const objc = @import("objc.zig");

/// Returns one owned NSImage reference. The caller releases it after assigning
/// applicationIconImage, or when a later native window preparation fails.
pub fn create(view: images.View) !objc.Id {
    try view.validate();
    const bitmap = objc.send(objc.Id, objc.send(objc.Id, objc.class("NSBitmapImageRep"), "alloc", .{}), "initWithBitmapDataPlanes:pixelsWide:pixelsHigh:bitsPerSample:samplesPerPixel:hasAlpha:isPlanar:colorSpaceName:bitmapFormat:bytesPerRow:bitsPerPixel:", .{
        @as(?*anyopaque, null), @as(usize, view.width), @as(usize, view.height), @as(usize, 8), @as(usize, 4), true, false, objc.string("NSDeviceRGBColorSpace"), @as(usize, 0), @as(usize, view.width) * 4, @as(usize, 32),
    }) orelse return error.NativeIconAllocationFailed;
    defer objc.release(bitmap);
    const pixels = objc.send(?[*]u8, bitmap, "bitmapData", .{}) orelse return error.NativeIconAllocationFailed;
    const stride = objc.send(usize, bitmap, "bytesPerRow", .{});
    const row_bytes = @as(usize, view.width) * 4;
    if (stride < row_bytes or stride > std.math.maxInt(usize) / @as(usize, view.height)) return error.NativeIconAllocationFailed;
    for (0..view.height) |row| @memcpy(pixels[row * stride ..][0..row_bytes], view.pixels[row * row_bytes ..][0..row_bytes]);
    const srgb = objc.send(objc.Id, objc.class("NSColorSpace"), "sRGBColorSpace", .{});
    const tagged = objc.send(objc.Id, bitmap, "bitmapImageRepByRetaggingWithColorSpace:", .{srgb}) orelse return error.NativeIconAllocationFailed;
    const image = objc.send(objc.Id, objc.send(objc.Id, objc.class("NSImage"), "alloc", .{}), "initWithSize:", .{objc.CGSize{ .width = @floatFromInt(view.width), .height = @floatFromInt(view.height) }}) orelse return error.NativeIconAllocationFailed;
    objc.send(void, image, "addRepresentation:", .{tagged});
    return image;
}
