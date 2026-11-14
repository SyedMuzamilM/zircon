//! Immutable image assets. Pixel bytes live once outside frame arenas. A clone
//! retains the asset on its creator thread; workers may read retained views but
//! must return ownership to that thread before releasing them. Pixels use
//! premultiplied RGBA8 with logical top-left row order.
const std = @import("std");
const builtin = @import("builtin");
const zircon_options = @import("zircon_options");
const geometry = @import("../layout/geometry.zig");
const images = @import("../platform/macos/images.zig");
const Size = geometry.Size;
pub const max_dimension = 16384;
pub const max_bytes = 64 * 1024 * 1024;
pub const Fit = enum { contain, cover, stretch };
var next_identity = std.atomic.Value(u64).init(1);
const Storage = struct {
    allocator: std.mem.Allocator,
    owner: std.Thread.Id,
    references: usize = 1,
    identity: u64,
    width: u32,
    height: u32,
    pixels: []const u8,
};
/// A borrowed view lasts while an owning Image reference exists. Native draw
/// synchronously uploads a missing texture, so it never retains these bytes.
pub const View = struct {
    id: u64,
    width: u32,
    height: u32,
    pixels: []const u8,
    pub fn validate(view: View) !void {
        const count = try byteCount(view.width, view.height);
        if (view.id == 0 or view.pixels.len != count) return error.InvalidImage;
    }
};
pub const Image = struct {
    storage: *Storage,
    /// Copies straight RGBA8 input and premultiplies alpha once. Ownership of
    /// the caller's source bytes is unchanged on success and failure.
    pub fn fromRgba(a: std.mem.Allocator, width: u32, height: u32, bytes: []const u8) !Image {
        const count = try byteCount(width, height);
        if (bytes.len != count) return error.InvalidImage;
        const pixels = try a.dupe(u8, bytes);
        errdefer a.free(pixels);
        var i: usize = 0;
        while (i < pixels.len) : (i += 4) {
            const alpha: u16 = pixels[i + 3];
            inline for (0..3) |channel| pixels[i + channel] = @intCast((@as(u16, pixels[i + channel]) * alpha + 127) / 255);
        }
        return adopt(a, width, height, pixels);
    }
    /// Decodes the first frame through the native image adapter. The decoder
    /// applies orientation and returns normalized, premultiplied RGBA8 bytes.
    pub fn load(a: std.mem.Allocator, encoded: []const u8) !Image {
        if (comptime builtin.os.tag != .macos or !zircon_options.native) return error.ImageDecodingUnavailable;
        if (encoded.len == 0 or encoded.len > max_bytes) return error.InvalidImage;
        const decoded = try images.decode(a, encoded);
        errdefer a.free(decoded.pixels);
        return adopt(a, decoded.width, decoded.height, decoded.pixels);
    }
    /// Rasterizes SVG bytes through the native macOS SVG decoder.
    pub fn loadSvg(a: std.mem.Allocator, encoded: []const u8) !Image {
        if (comptime builtin.os.tag != .macos or !zircon_options.native) return error.ImageDecodingUnavailable;
        if (encoded.len == 0 or encoded.len > max_bytes) return error.InvalidImage;
        const decoded = try images.decodeSvg(a, encoded);
        errdefer a.free(decoded.pixels);
        return adopt(a, decoded.width, decoded.height, decoded.pixels);
    }
    fn adopt(a: std.mem.Allocator, width: u32, height: u32, pixels: []u8) !Image {
        const identity = try reserveIdentity();
        const storage = try a.create(Storage);
        storage.* = .{ .allocator = a, .owner = std.Thread.getCurrentId(), .identity = identity, .width = width, .height = height, .pixels = pixels };
        return .{ .storage = storage };
    }
    pub fn clone(image: Image) Image {
        std.debug.assert(image.storage.owner == std.Thread.getCurrentId() and image.storage.references < std.math.maxInt(usize));
        image.storage.references += 1;
        return image;
    }
    pub fn deinit(image: *Image) void {
        const storage = image.storage;
        std.debug.assert(storage.owner == std.Thread.getCurrentId() and storage.references > 0);
        storage.references -= 1;
        if (storage.references == 0) {
            const a = storage.allocator;
            a.free(storage.pixels);
            a.destroy(storage);
        }
        image.* = undefined;
    }
    pub fn size(image: Image) Size {
        return .{ .width = @floatFromInt(image.storage.width), .height = @floatFromInt(image.storage.height) };
    }
    pub fn id(image: Image) u64 {
        return image.storage.identity;
    }
    pub fn view(image: Image) View {
        return .{ .id = image.storage.identity, .width = image.storage.width, .height = image.storage.height, .pixels = image.storage.pixels };
    }
};
pub const load = Image.load;
pub const loadSvg = Image.loadSvg;
pub fn byteCount(width: u32, height: u32) !usize {
    if (width == 0 or height == 0 or width > max_dimension or height > max_dimension) return error.InvalidImageSize;
    const pixels = std.math.mul(usize, width, height) catch return error.InvalidImageSize;
    const bytes = std.math.mul(usize, pixels, 4) catch return error.InvalidImageSize;
    if (bytes > max_bytes) return error.ImageTooLarge;
    return bytes;
}
fn reserveIdentity() !u64 {
    var current = next_identity.load(.monotonic);
    while (true) {
        if (current == std.math.maxInt(u64)) return error.ImageIdentityExhausted;
        if (next_identity.cmpxchgWeak(current, current + 1, .monotonic, .monotonic)) |actual| current = actual else return current;
    }
}
