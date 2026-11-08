//! Private root for opt-in native tests. Never imported by the portable core.
pub const text = @import("text/shaping.zig");
pub const metal = @import("graphics/backends/metal.zig");
pub const objc = @import("platform/macos/objc.zig");
pub const scene = @import("graphics/scene.zig");
pub const images = @import("graphics/images.zig");
pub const icon = @import("platform/macos/icon.zig");
pub const Painter = @import("graphics/painter.zig").Painter;

test {
    _ = @import("platform/macos/window_test.zig");
}

pub const window = @import("platform/macos/window.zig");

pub const ui = @import("root.zig");
