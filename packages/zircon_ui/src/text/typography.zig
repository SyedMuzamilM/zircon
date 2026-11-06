//! Application typography shared by measurement, hit testing and GPU text.
const std = @import("std");
pub const CodeFont = enum { lilex, menlo, monaco };
pub const UiFont = enum { plex, system };
pub const Typography = struct {
    code_font: CodeFont = .lilex,
    ui_font: UiFont = .plex,
    ui_size: f32 = 13,
    ligatures: bool = false,
    pub fn validate(self: Typography) !void {
        if (!std.math.isFinite(self.ui_size) or self.ui_size < 10 or self.ui_size > 24) return error.InvalidTypography;
    }
};
