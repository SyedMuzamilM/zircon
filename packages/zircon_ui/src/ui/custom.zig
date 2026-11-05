//! Custom elements keep all phase storage in their frame arena. Entity state is
//! copied/read during render; custom phases never retain a borrowed entity.
const std = @import("std");
const g = @import("../layout/geometry.zig");
const measure = @import("../layout/measure.zig");
const Painter = @import("../graphics/painter.zig").Painter;
const platform = @import("../platform/interface.zig");
pub const LayoutCx = struct { allocator: std.mem.Allocator, available: g.Size, measurer: measure.Measurer };
pub const PrepaintCx = struct {
    allocator: std.mem.Allocator,
    focused: bool = false,
    text_input: ?*?platform.TextSnapshot = null,
    pub fn setTextInput(cx: *PrepaintCx, snapshot: platform.TextSnapshot) !void {
        if (!cx.focused) return;
        const target = cx.text_input orelse return error.NoTextInputTarget;
        if (target.* != null) return error.DuplicateTextInputTarget;
        try snapshot.validate();
        var owned = snapshot;
        owned.text = try cx.allocator.dupe(u8, snapshot.text);
        target.* = owned;
    }
};
pub const PaintCx = struct { painter: *Painter, measurer: measure.Measurer, focused: bool = false, text_input: ?*?platform.TextSnapshot = null };
pub fn LayoutResult(comptime State: type) type {
    return struct { size: g.Size, state: State };
}
pub const Custom = struct {
    object: *anyopaque,
    measure: *const fn (*anyopaque, *LayoutCx) anyerror!g.Size,
    paint: *const fn (*anyopaque, *PaintCx, g.Rect) anyerror!void,
    destroy: *const fn (*anyopaque) void,
};
pub fn create(comptime T: type, a: std.mem.Allocator, value: T) !Custom {
    comptime {
        for (.{ "LayoutState", "PrepaintState", "requestLayout", "prepaint", "paint" }) |name| if (!@hasDecl(T, name)) @compileError("custom element requires " ++ name);
    }
    const Adapter = struct {
        value: T,
        layout: ?T.LayoutState = null,
        prepaint: ?T.PrepaintState = null,
        fn measure(raw: *anyopaque, cx: *LayoutCx) !g.Size {
            const self: *@This() = @ptrCast(@alignCast(raw));
            const result: LayoutResult(T.LayoutState) = try self.value.requestLayout(cx);
            self.layout = result.state;
            return result.size;
        }
        fn paint(raw: *anyopaque, cx: *PaintCx, bounds: g.Rect) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            var before: PrepaintCx = .{ .allocator = cx.painter.allocator, .focused = cx.focused, .text_input = cx.text_input };
            self.prepaint = try self.value.prepaint(&before, bounds, &self.layout.?);
            try self.value.paint(cx, bounds, &self.layout.?, &self.prepaint.?);
        }
        fn destroy(raw: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (@hasDecl(T, "deinit")) self.value.deinit();
        }
    };
    const object = try a.create(Adapter);
    object.* = .{ .value = value };
    return .{ .object = object, .measure = Adapter.measure, .paint = Adapter.paint, .destroy = Adapter.destroy };
}
