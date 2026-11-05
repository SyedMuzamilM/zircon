//! Private root for opt-in native tests. Never imported by the portable core.
pub const text = @import("text/shaping.zig");
pub const metal = @import("graphics/backends/metal.zig");
pub const objc = @import("platform/macos/objc.zig");
pub const scene = @import("graphics/scene.zig");
pub const geometry = @import("layout/geometry.zig");
