//! Typed event payloads and dispatcher-owned propagation/default controls.
const g = @import("../layout/geometry.zig");
pub const Input = @import("../platform/interface.zig").Input;
pub const Click = struct { position: g.Point = .{}, button: enum { primary, secondary, middle } = .primary };
pub const Phase = enum { capture, target, bubble };
pub fn Event(comptime T: type) type {
    return struct {
        data: T,
        phase: Phase = .target,
        bounds: g.Rect = .{},
        stopped: bool = false,
        prevented: bool = false,
        focus_requested: bool = false,
        capture_requested: bool = false,
        release_requested: bool = false,
        _surface: ?@import("../platform/interface.zig").Surface = null,
        _window_size: ?g.Size = null,
        pub fn textMetrics(e: *const @This()) !@import("../layout/measure.zig").Measurer {
            return (e._surface orelse return error.NoWindow).measurer();
        }
        pub fn windowSize(e: *const @This()) !g.Size {
            if (e._window_size) |size| return size;
            return (e._surface orelse return error.NoWindow).size();
        }
        pub fn readClipboard(e: *const @This(), allocator: @import("std").mem.Allocator) ![]u8 {
            const s = e._surface orelse return error.NoWindow;
            return s.ops.clipboard_read(s.context, allocator);
        }
        pub fn writeClipboard(e: *const @This(), bytes: []const u8) !void {
            const s = e._surface orelse return error.NoWindow;
            return s.ops.clipboard_write(s.context, bytes);
        }
        pub fn stopPropagation(e: *@This()) void {
            e.stopped = true;
        }
        pub fn preventDefault(e: *@This()) void {
            e.prevented = true;
        }
        pub fn focus(e: *@This()) void {
            e.focus_requested = true;
        }
        pub fn capturePointer(e: *@This()) void {
            e.capture_requested = true;
        }
        pub fn releasePointer(e: *@This()) void {
            e.release_requested = true;
        }
    };
}
