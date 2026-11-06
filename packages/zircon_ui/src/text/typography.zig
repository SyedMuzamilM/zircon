//! Application typography shared by measurement, hit testing and GPU text.
const std = @import("std");
pub const CodeFont = enum { lilex, menlo, monaco };
pub const UiFont = enum { plex, system };
/// Value-owned so settings callbacks and committed frames never borrow JSON strings.
pub const FontName = struct {
    bytes: [256]u8 = @splat(0),
    len: u16 = 0,
    pub fn init(name: []const u8) !FontName {
        if (name.len == 0 or name.len > 255 or !std.unicode.utf8ValidateSlice(name)) return error.InvalidFontName;
        for (name) |byte| if (byte < 32 or byte == 127) return error.InvalidFontName;
        var result: FontName = .{ .len = @intCast(name.len) };
        @memcpy(result.bytes[0..name.len], name);
        return result;
    }
    pub fn slice(self: *const FontName) []const u8 {
        return self.bytes[0..self.len];
    }
};
pub const Typography = struct {
    code_family: FontName = .{},
    ui_family: FontName = .{},
    code_font: CodeFont = .lilex,
    ui_font: UiFont = .plex,
    ui_size: f32 = 13,
    ligatures: bool = false,
    pub fn validate(self: Typography) !void {
        inline for (.{ self.code_family, self.ui_family }) |family| {
            if (family.len > 255) return error.InvalidFontName;
            if (family.len > 0) _ = try FontName.init(family.slice());
        }
        if (!std.math.isFinite(self.ui_size) or self.ui_size < 10 or self.ui_size > 24) return error.InvalidTypography;
    }
};
