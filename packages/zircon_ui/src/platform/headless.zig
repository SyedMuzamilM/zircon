//! In-memory platform adapter for the ordinary window runtime.
const std = @import("std");
const scene = @import("../graphics/scene.zig");
const g = @import("../layout/geometry.zig");
const measure = @import("../layout/measure.zig");
const p = @import("interface.zig");
const State = struct { allocator: std.mem.Allocator, dimensions: g.Size, metrics: measure.FixedMetrics = .{}, clipboard: []u8 = &.{} };
pub fn open(a: std.mem.Allocator, options: p.WindowOptions, _: p.Sink) !p.Surface {
    const s = try a.create(State);
    s.* = .{ .allocator = a, .dimensions = .{ .width = options.width, .height = options.height } };
    return .{ .context = s, .ops = &ops };
}
fn state(raw: *anyopaque) *State {
    return @ptrCast(@alignCast(raw));
}
fn destroy(raw: *anyopaque) void {
    const s = state(raw);
    const a = s.allocator;
    a.free(s.clipboard);
    a.destroy(s);
}
fn size(raw: *anyopaque) g.Size {
    return state(raw).dimensions;
}
fn present(_: *anyopaque, _: scene.Frame) !bool {
    return true;
}
fn measurer(raw: *anyopaque) measure.Measurer {
    return state(raw).metrics.measurer();
}
fn snapshot(_: *anyopaque, _: scene.Frame, _: []const u8) !void {
    return error.NativeNotEnabled;
}
fn readClipboard(raw: *anyopaque, a: std.mem.Allocator) ![]u8 {
    return a.dupe(u8, state(raw).clipboard);
}
fn writeClipboard(raw: *anyopaque, bytes: []const u8) !void {
    const s = state(raw);
    const copy = try s.allocator.dupe(u8, bytes);
    s.allocator.free(s.clipboard);
    s.clipboard = copy;
}
const ops: p.Surface.Ops = .{ .deinit = destroy, .size = size, .present = present, .measurer = measurer, .snapshot = snapshot, .clipboard_read = readClipboard, .clipboard_write = writeClipboard };
