//! Typed payloads for direct entity-handler calls. Tree dispatch is not built yet.
const Point = @import("../layout/geometry.zig").Point;
pub const Click = struct { position: Point = .{}, button: enum { primary, secondary, middle } = .primary };
pub fn Event(comptime T: type) type {
    return struct {
        data: T,
    };
}
