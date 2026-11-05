//! Typed events carry callback-scoped propagation control, never a render pointer.
const Point = @import("../layout/geometry.zig").Point;
pub const Click = struct { position: Point = .{}, button: enum { primary, secondary, middle } = .primary };
pub const DispatchControl = struct { stop_propagation: bool = false, prevent_default: bool = false, capture_pointer: bool = false };
pub fn Event(comptime T: type) type {
    return struct {
        data: T,
        control: *DispatchControl,
        pub fn stopPropagation(event: *@This()) void {
            event.control.stop_propagation = true;
        }
        pub fn preventDefault(event: *@This()) void {
            event.control.prevent_default = true;
        }
        pub fn capturePointer(event: *@This()) void {
            event.control.capture_pointer = true;
        }
    };
}
