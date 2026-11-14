//! Allocation-free fixed-height virtualization for large scrollable content.
//! The list owns no rows and never materializes an element per item. Callers
//! retain the scroll offset and provide a paint callback for visible rows.

const std = @import("std");
const geometry = @import("../layout/geometry.zig");
const custom = @import("../ui/custom.zig");
const scroll = @import("scroll.zig");
pub const PaintItem = *const fn (*anyopaque, usize, geometry.Rect, *custom.PaintCx) anyerror!void;
pub const OffsetForIndex = *const fn (*anyopaque, usize) f32;
pub const IndexForOffset = *const fn (*anyopaque, f32) usize;

pub const UniformList = struct {
    item_count: usize,
    item_height: f32,
    offset: f32 = 0,
    overscan: usize = 2,
    context: *anyopaque,
    paint_item: PaintItem,

    pub const LayoutState = struct {
        content_height: f32,
        viewport_height: f32,
    };

    pub const PrepaintState = struct {
        visible: scroll.VisibleRows,
    };

    pub fn requestLayout(self: *UniformList, cx: *custom.LayoutCx) !custom.LayoutResult(LayoutState) {
        if (!std.math.isFinite(self.item_height) or self.item_height <= 0) return error.InvalidListMetrics;
        if (!std.math.isFinite(self.offset) or self.offset < 0) return error.InvalidListOffset;
        const count: f32 = @floatFromInt(self.item_count);
        const content_height = count * self.item_height;
        if (!std.math.isFinite(content_height)) return error.InvalidListMetrics;
        return .{
            .size = .{ .width = cx.available.width, .height = cx.available.height },
            .state = .{ .content_height = content_height, .viewport_height = @max(0, cx.available.height) },
        };
    }

    pub fn prepaint(self: *UniformList, _: *custom.PrepaintCx, bounds: geometry.Rect, state: *LayoutState) !PrepaintState {
        const viewport = @max(0, @min(bounds.height, state.viewport_height));
        const visible = try scroll.visibleRows(self.item_count, self.item_height, self.offset, viewport, self.overscan);
        return .{ .visible = visible };
    }

    pub fn paint(self: *UniformList, cx: *custom.PaintCx, bounds: geometry.Rect, _: *LayoutState, state: *PrepaintState) !void {
        const visible = state.visible;
        try cx.painter.pushClip(bounds);
        defer cx.painter.popClip();
        for (visible.start..visible.end) |index| {
            const y = bounds.y + visible.top + @as(f32, @floatFromInt(index - visible.start)) * self.item_height;
            try self.paint_item(self.context, index, .{ .x = bounds.x, .y = y, .width = bounds.width, .height = self.item_height }, cx);
        }
    }
};

pub fn uniformList(item_count: usize, item_height: f32, offset: f32, overscan: usize, context: *anyopaque, paint_item: PaintItem) UniformList {
    return .{ .item_count = item_count, .item_height = item_height, .offset = offset, .overscan = overscan, .context = context, .paint_item = paint_item };
}

/// Variable-height virtualization. The caller supplies prefix-sum/index
/// functions; an indexed tree can make both operations logarithmic for very
/// large collections.
pub const VariableList = struct {
    item_count: usize,
    offset: f32 = 0,
    overscan: usize = 2,
    context: *anyopaque,
    offset_for_index: OffsetForIndex,
    index_for_offset: IndexForOffset,
    paint_item: PaintItem,

    pub const LayoutState = struct { content_height: f32, viewport_height: f32 };
    pub const PrepaintState = struct { start: usize, end: usize, first_top: f32 };

    pub fn requestLayout(self: *VariableList, cx: *custom.LayoutCx) !custom.LayoutResult(LayoutState) {
        if (!std.math.isFinite(self.offset) or self.offset < 0) return error.InvalidListOffset;
        const content_height = self.offset_for_index(self.context, self.item_count);
        if (!std.math.isFinite(content_height) or content_height < 0) return error.InvalidListMetrics;
        return .{ .size = .{ .width = cx.available.width, .height = cx.available.height }, .state = .{ .content_height = content_height, .viewport_height = @max(0, cx.available.height) } };
    }

    pub fn prepaint(self: *VariableList, _: *custom.PrepaintCx, bounds: geometry.Rect, state: *LayoutState) !PrepaintState {
        if (self.item_count == 0) return .{ .start = 0, .end = 0, .first_top = 0 };
        const clamped = @min(self.offset, @max(0, state.content_height - state.viewport_height));
        const first = @min(self.item_count, self.index_for_offset(self.context, clamped));
        const start = first -| self.overscan;
        var end = @min(self.item_count, self.index_for_offset(self.context, clamped + @max(0, bounds.height)) +| self.overscan +| 1);
        if (end < start) end = start;
        return .{ .start = start, .end = end, .first_top = self.offset_for_index(self.context, start) - clamped };
    }

    pub fn paint(self: *VariableList, cx: *custom.PaintCx, bounds: geometry.Rect, _: *LayoutState, state: *PrepaintState) !void {
        try cx.painter.pushClip(bounds);
        defer cx.painter.popClip();
        const scroll_top = self.offset_for_index(self.context, state.start) - state.first_top;
        for (state.start..state.end) |index| {
            const top = bounds.y + self.offset_for_index(self.context, index) - scroll_top;
            const bottom = bounds.y + self.offset_for_index(self.context, index + 1) - scroll_top;
            try self.paint_item(self.context, index, .{ .x = bounds.x, .y = top, .width = bounds.width, .height = @max(0, bottom - top) }, cx);
        }
    }
};

pub fn variableList(item_count: usize, offset: f32, overscan: usize, context: *anyopaque, offset_for_index: OffsetForIndex, index_for_offset: IndexForOffset, paint_item: PaintItem) VariableList {
    return .{ .item_count = item_count, .offset = offset, .overscan = overscan, .context = context, .offset_for_index = offset_for_index, .index_for_offset = index_for_offset, .paint_item = paint_item };
}
