//! ImageIO/CoreGraphics decoding through direct Zig declarations. No native
//! object escapes the adapter. ImageIO handles PNG/JPEG/GIF first-frame data;
//! thumbnail transforms normalize EXIF orientation before RGBA extraction.
const std = @import("std");
const images = @import("../../graphics/images.zig");
const objc = @import("objc.zig");
const Ref = *const anyopaque;
extern "c" fn CFDataCreate(?Ref, [*]const u8, isize) ?Ref;
extern "c" fn CFRelease(Ref) void;
extern "c" fn CFDictionaryCreate(?Ref, [*]const Ref, [*]const Ref, isize, ?*const anyopaque, ?*const anyopaque) ?Ref;
extern "c" const kCFTypeDictionaryKeyCallBacks: extern struct { version: isize, retain: ?*const anyopaque, release: ?*const anyopaque, copyDescription: ?*const anyopaque, equal: ?*const anyopaque, hash: ?*const anyopaque };
extern "c" const kCFTypeDictionaryValueCallBacks: extern struct { version: isize, retain: ?*const anyopaque, release: ?*const anyopaque, copyDescription: ?*const anyopaque, equal: ?*const anyopaque };
extern "c" const kCFBooleanTrue: Ref;
extern "c" fn CFNumberCreate(?Ref, isize, *const anyopaque) ?Ref;
extern "c" fn CGImageSourceCreateWithData(Ref, ?Ref) ?Ref;
extern "c" fn CGImageSourceGetCount(Ref) usize;
extern "c" fn CGImageSourceCopyPropertiesAtIndex(Ref, usize, ?Ref) ?Ref;
extern "c" fn CGImageSourceCreateThumbnailAtIndex(Ref, usize, Ref) ?Ref;
extern "c" fn CFDictionaryGetValue(Ref, Ref) ?Ref;
extern "c" fn CFNumberGetValue(Ref, isize, *anyopaque) bool;
extern "c" const kCGImagePropertyPixelWidth: Ref;
extern "c" const kCGImagePropertyPixelHeight: Ref;
extern "c" const kCGImageSourceCreateThumbnailFromImageAlways: Ref;
extern "c" const kCGImageSourceCreateThumbnailWithTransform: Ref;
extern "c" const kCGImageSourceThumbnailMaxPixelSize: Ref;
extern "c" fn CGImageGetWidth(Ref) usize;
extern "c" fn CGImageGetHeight(Ref) usize;
extern "c" fn CGColorSpaceCreateWithName(Ref) ?Ref;
extern "c" const kCGColorSpaceSRGB: Ref;
extern "c" fn CGBitmapContextCreate(?*anyopaque, usize, usize, usize, usize, Ref, u32) ?Ref;
extern "c" fn CGContextSetInterpolationQuality(Ref, i32) void;
extern "c" fn CGContextDrawImage(Ref, objc.CGRect, Ref) void;
pub const Decoded = struct { width: u32, height: u32, pixels: []u8 };
pub fn decode(a: std.mem.Allocator, bytes: []const u8) !Decoded {
    const data = CFDataCreate(null, bytes.ptr, @intCast(bytes.len)) orelse return error.NativeImageAllocationFailed;
    defer CFRelease(data);
    const source = CGImageSourceCreateWithData(data, null) orelse return error.InvalidImage;
    defer CFRelease(source);
    if (CGImageSourceGetCount(source) == 0) return error.InvalidImage;
    const properties = CGImageSourceCopyPropertiesAtIndex(source, 0, null) orelse return error.InvalidImage;
    defer CFRelease(properties);
    const source_width = try propertyDimension(properties, kCGImagePropertyPixelWidth);
    const source_height = try propertyDimension(properties, kCGImagePropertyPixelHeight);
    _ = try images.byteCount(source_width, source_height);
    const max_side: i64 = @max(source_width, source_height);
    const number = CFNumberCreate(null, 4, &max_side) orelse return error.NativeImageAllocationFailed;
    defer CFRelease(number);
    const keys = [_]Ref{ kCGImageSourceCreateThumbnailFromImageAlways, kCGImageSourceCreateThumbnailWithTransform, kCGImageSourceThumbnailMaxPixelSize };
    const values = [_]Ref{ kCFBooleanTrue, kCFBooleanTrue, number };
    const options = CFDictionaryCreate(null, &keys, &values, keys.len, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks) orelse return error.NativeImageAllocationFailed;
    defer CFRelease(options);
    const image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) orelse return error.InvalidImage;
    defer CFRelease(image);
    const width = std.math.cast(u32, CGImageGetWidth(image)) orelse return error.InvalidImageSize;
    const height = std.math.cast(u32, CGImageGetHeight(image)) orelse return error.InvalidImageSize;
    const length = try images.byteCount(width, height);
    const pixels = try a.alloc(u8, length);
    errdefer a.free(pixels);
    @memset(pixels, 0);
    const color_space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB) orelse return error.NativeImageAllocationFailed;
    defer CFRelease(color_space);
    // kCGBitmapByteOrder32Big | kCGImageAlphaPremultipliedLast is RGBA8.
    const context = CGBitmapContextCreate(pixels.ptr, width, height, 8, @as(usize, width) * 4, color_space, (4 << 12) | 1) orelse return error.NativeImageAllocationFailed;
    defer CFRelease(context);
    CGContextSetInterpolationQuality(context, 1);
    CGContextDrawImage(context, .{ .size = .{ .width = @floatFromInt(width), .height = @floatFromInt(height) } }, image);
    return .{ .width = width, .height = height, .pixels = pixels };
}
fn propertyDimension(properties: Ref, key: Ref) !u32 {
    const value = CFDictionaryGetValue(properties, key) orelse return error.InvalidImage;
    var dimension: i64 = 0;
    if (!CFNumberGetValue(value, 4, &dimension) or dimension <= 0 or dimension > images.max_dimension) return error.InvalidImageSize;
    return @intCast(dimension);
}
