//! The user-supplied cobalt monogram. The embedded RGBA asset keeps portable
//! builds independent of native image decoding and matches the bundled icon.
const std = @import("std");
const ui = @import("zircon_ui");
pub const size = 256;
pub fn create(a: std.mem.Allocator) !ui.graphics.images.Image {
    return ui.graphics.images.Image.fromRgba(a, size, size, @embedFile("assets/zircon-logo.rgba"));
}
