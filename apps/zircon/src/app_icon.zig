//! The editor's default icon is generated from geometry so runtime and packaged
//! assets can use the same pixels without another image-generation toolchain.
const std = @import("std");
const ui = @import("zircon_ui");
pub const size = 256;

pub fn create(a: std.mem.Allocator) !ui.graphics.images.Image {
    const bytes = try a.alloc(u8, size * size * 4);
    defer a.free(bytes);
    for (0..size) |y| for (0..size) |x| {
        var rgb: [3]u32 = @splat(0);
        var coverage: u32 = 0;
        for (0..4) |sy| for (0..4) |sx| {
            const color = sample(@as(f32, @floatFromInt(x)) + (@as(f32, @floatFromInt(sx)) + 0.5) / 4, @as(f32, @floatFromInt(y)) + (@as(f32, @floatFromInt(sy)) + 0.5) / 4) orelse continue;
            for (color, 0..) |channel, index| rgb[index] += channel;
            coverage += 1;
        };
        const pixel = bytes[(y * size + x) * 4 ..][0..4];
        for (0..3) |channel| pixel[channel] = if (coverage == 0) 0 else @intCast(rgb[channel] / coverage);
        pixel[3] = @intCast((coverage * 255 + 8) / 16);
    };
    return ui.graphics.images.Image.fromRgba(a, size, size, bytes);
}
fn sample(x: f32, y: f32) ?[3]u8 {
    if (x < 12 or x >= 244 or y < 12 or y >= 244) return null;
    const dx = @max(0, @max(60 - x, x - 196));
    const dy = @max(0, @max(60 - y, y - 196));
    if (dx * dx + dy * dy > 48 * 48) return null;
    if (@abs(x - 128) / 90 + @abs(y - 128) / 92 > 1) return .{ 18, 24, 38 };
    const top = x >= 90 and x < 166 and y >= 93 and y < 105;
    const bottom = x >= 90 and x < 166 and y >= 151 and y < 163;
    const diagonal = x >= 90 and x < 166 and y >= 105 and y < 151 and @abs((x - 166) * 46 + (y - 105) * 76) < 530;
    if (top or bottom or diagonal) return .{ 234, 243, 255 };
    if (x + y < 254) return .{ 94, 177, 245 };
    return if (x > 128) .{ 56, 111, 218 } else .{ 47, 78, 154 };
}
