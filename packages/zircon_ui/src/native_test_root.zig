//! Private root for opt-in native tests. Never imported by the portable core.
pub const metal = @import("graphics/backends/metal.zig");
pub const images = @import("graphics/images.zig");
const painter = @import("graphics/painter.zig");
pub const scene = @import("graphics/scene.zig");
pub const icon = @import("platform/macos/icon.zig");
pub const objc = @import("platform/macos/objc.zig");
pub const window = @import("platform/macos/window.zig");
const window_test = @import("platform/macos/window_test.zig");
pub const ui = @import("root.zig");
pub const text = @import("text/shaping.zig");
pub const Painter = painter.Painter;

test {
    _ = window_test;
}
