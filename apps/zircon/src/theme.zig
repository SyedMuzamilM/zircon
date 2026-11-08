//! Application theme selection uses shared widget colors.
const std = @import("std");
const zircon_widgets = @import("zircon_widgets");
pub const Palette = zircon_widgets.Palette;
pub fn isLight(id: []const u8, system_dark: bool) bool {
    return std.mem.eql(u8, id, "zircon.light") or (std.mem.eql(u8, id, "zircon.system") and !system_dark);
}
