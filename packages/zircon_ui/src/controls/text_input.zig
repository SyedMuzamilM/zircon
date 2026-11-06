//! A persistent single-line editable control. Bytes live in the entity; the
//! custom element copies its render snapshot into the frame and publishes IME
//! ranges. Selection positions are UTF-8 byte boundaries, never native UTF-16.
const std = @import("std");
const runtime = @import("../app/app.zig");
const Ui = @import("../ui/ui.zig").Ui;
const Element = @import("../ui/element.zig").Element;
const custom = @import("../ui/custom.zig");
const events = @import("../event/event.zig");
const p = @import("../platform/interface.zig");
const g = @import("../layout/geometry.zig");
const TextStyle = @import("../text/style.zig").TextStyle;
const icons = @import("icons.zig");
pub const TextInput = struct {
    pub const Appearance = struct {
        background: g.Color = g.Color.rgb(0x282c33),
        foreground: g.Color = g.Color.rgb(0xdce0e5),
        placeholder: g.Color = g.Color.rgb(0xa9afbc),
        selection: g.Color = g.Color.rgb(0x364357),
        caret: g.Color = g.Color.rgb(0x74ade8),
        focus_border: g.Color = g.Color.rgb(0x74ade8),
    };
    allocator: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,
    anchor: usize = 0,
    cursor: usize = 0,
    revision: u64 = 0,
    marked: ?p.TextRange = null,
    dragging: bool = false,
    placeholder: []const u8 = "Type here…",
    appearance: Appearance = .{},
    height: f32 = 30,
    font_size: f32 = 13,
    leading_icon: ?icons.Name = null,
    pub fn init(a: std.mem.Allocator, text: []const u8) !TextInput {
        if (!validLine(text)) return error.InvalidText;
        var input: TextInput = .{ .allocator = a };
        try input.bytes.appendSlice(a, text);
        input.anchor = text.len;
        input.cursor = text.len;
        return input;
    }
    pub fn deinit(self: *TextInput, _: std.mem.Allocator) void {
        self.bytes.deinit(self.allocator);
    }
    pub fn render(self: *const TextInput, b: *Ui) !Element {
        try (TextStyle{ .size = self.font_size }).validate();
        const field: Field = .{ .text = try b.allocator().dupe(u8, self.bytes.items), .placeholder = try b.allocator().dupe(u8, self.placeholder), .selection = self.selection(), .cursor = self.cursor, .revision = self.revision, .marked = self.marked, .appearance = self.appearance, .height = self.height, .font_size = self.font_size, .leading_icon = self.leading_icon };
        return b.listen(try b.key(.{ .string = "text-input" }, try b.custom(Field, field, .{ .height = .{ .px = self.height }, .overflow = .hidden })), .{ .focusable = true, .on_input = b.onInput(onInput) });
    }
    pub fn setAppearance(self: *TextInput, cx: *runtime.Context(TextInput), appearance: Appearance) void {
        if (std.meta.eql(self.appearance, appearance)) return;
        self.appearance = appearance;
        cx.notify();
    }
    pub fn copy(self: *const TextInput, a: std.mem.Allocator, output: *[]u8) !void {
        output.* = try a.dupe(u8, self.bytes.items);
    }
    pub fn selection(self: *const TextInput) p.TextRange {
        return .{ .start = @min(self.anchor, self.cursor), .end = @max(self.anchor, self.cursor) };
    }
    fn replace(self: *TextInput, range: p.TextRange, bytes: []const u8) !void {
        if (!validLine(bytes)) return;
        if (range.start > range.end or range.end > self.bytes.items.len or !boundary(self.bytes.items, range.start) or !boundary(self.bytes.items, range.end)) return error.InvalidTextRange;
        const new_length = self.bytes.items.len - (range.end - range.start) + bytes.len;
        try self.bytes.ensureTotalCapacity(self.allocator, new_length);
        const tail = self.bytes.items.len - range.end;
        const storage = self.bytes.items.ptr[0..self.bytes.capacity];
        const destination = storage[range.start + bytes.len ..][0..tail];
        const source = storage[range.end..][0..tail];
        if (range.start + bytes.len > range.end) std.mem.copyBackwards(u8, destination, source) else std.mem.copyForwards(u8, destination, source);
        self.bytes.items.len = new_length;
        @memcpy(self.bytes.items[range.start..][0..bytes.len], bytes);
        self.cursor = range.start + bytes.len;
        self.anchor = self.cursor;
        self.revision +%= 1;
    }
    fn onInput(self: *TextInput, e: *events.Event(events.Input), cx: *runtime.Context(TextInput)) !void {
        switch (e.data) {
            .pointer_down => |pointer| {
                if (pointer.button != .primary) return;
                const metrics = try e.textMetrics();
                const offset = metrics.index(self.bytes.items, .{ .size = self.font_size }, pointer.position.x - e.bounds.x - textInset(self.leading_icon));
                if (!pointer.modifiers.shift) self.anchor = offset;
                self.cursor = offset;
                self.dragging = true;
                e.focus();
                e.capturePointer();
                e.preventDefault();
            },
            .pointer_move => |pointer| {
                if (!self.dragging) return;
                const metrics = try e.textMetrics();
                self.cursor = metrics.index(self.bytes.items, .{ .size = self.font_size }, pointer.position.x - e.bounds.x - textInset(self.leading_icon));
                e.preventDefault();
            },
            .pointer_up => {
                self.dragging = false;
                e.releasePointer();
            },
            .focus => |focused| {
                if (!focused) self.dragging = false;
            },
            .text => |bytes| {
                try self.replace(self.selection(), bytes);
                self.marked = null;
                e.preventDefault();
            },
            .edit => |edit| {
                if (!validLine(edit.text)) return;
                try edit.validate(.{ .text = self.bytes.items, .revision = self.revision, .selection = self.selection(), .marked = self.marked, .caret = .{} });
                try self.replace(edit.range, edit.text);
                self.anchor = edit.range.start + edit.selection.start;
                self.cursor = edit.range.start + edit.selection.end;
                self.marked = if (edit.composing) .{ .start = edit.range.start, .end = edit.range.start + edit.text.len } else null;
                e.preventDefault();
            },
            .unmark => |revision| {
                if (revision != self.revision) return error.StaleTextSnapshot;
                self.marked = null;
            },
            .key_down => |key| {
                const command = key.modifiers.command or key.modifiers.control;
                if (command) switch (key.key) {
                    .a => {
                        self.anchor = 0;
                        self.cursor = self.bytes.items.len;
                    },
                    .c, .x => {
                        const selected = self.selection();
                        try e.writeClipboard(self.bytes.items[selected.start..selected.end]);
                        if (key.key == .x) try self.replace(selected, "");
                    },
                    .v => {
                        const bytes = try e.readClipboard(self.allocator);
                        defer self.allocator.free(bytes);
                        try self.replace(self.selection(), bytes);
                    },
                    else => return,
                } else switch (key.key) {
                    .left => {
                        if (!key.modifiers.shift and self.anchor != self.cursor) self.cursor = self.selection().start else self.cursor = previous(self.bytes.items, self.cursor);
                        if (!key.modifiers.shift) self.anchor = self.cursor;
                    },
                    .right => {
                        if (!key.modifiers.shift and self.anchor != self.cursor) self.cursor = self.selection().end else self.cursor = next(self.bytes.items, self.cursor);
                        if (!key.modifiers.shift) self.anchor = self.cursor;
                    },
                    .home => {
                        self.cursor = 0;
                        if (!key.modifiers.shift) self.anchor = 0;
                    },
                    .end => {
                        self.cursor = self.bytes.items.len;
                        if (!key.modifiers.shift) self.anchor = self.cursor;
                    },
                    .backspace, .delete => {
                        var range = self.selection();
                        if (range.start == range.end) {
                            if (key.key == .backspace) range.start = previous(self.bytes.items, self.cursor) else range.end = next(self.bytes.items, self.cursor);
                        }
                        try self.replace(range, "");
                    },
                    .escape => {
                        self.marked = null;
                    },
                    else => return,
                }
                self.marked = null;
                e.preventDefault();
            },
            else => return,
        }
        cx.notify();
    }
};
const Field = struct {
    text: []const u8,
    placeholder: []const u8,
    selection: p.TextRange,
    cursor: usize,
    revision: u64,
    marked: ?p.TextRange,
    appearance: TextInput.Appearance,
    height: f32,
    font_size: f32,
    leading_icon: ?icons.Name,
    pub const LayoutState = @import("../layout/measure.zig").Measurer;
    pub const PrepaintState = g.Rect;
    pub fn requestLayout(self: *Field, cx: *custom.LayoutCx) !custom.LayoutResult(LayoutState) {
        return .{ .size = .{ .width = cx.available.width, .height = self.height }, .state = cx.measurer };
    }
    pub fn prepaint(self: *Field, cx: *custom.PrepaintCx, bounds: g.Rect, metrics: *LayoutState) !g.Rect {
        const size = try metrics.text(metrics.context, "M", .{ .size = self.font_size });
        const caret: g.Rect = .{ .x = bounds.x + textInset(self.leading_icon) + metrics.caret(self.text, .{ .size = self.font_size }, self.cursor), .y = bounds.y + @max(0, bounds.height - size.height) / 2, .width = 1, .height = @min(size.height, bounds.height) };
        if (cx.focused) {
            try cx.setTextInput(.{ .text = self.text, .revision = self.revision, .selection = self.selection, .marked = self.marked, .caret = caret });
            try cx.requestFrameAfter(0.5 - @mod(cx.time, 0.5));
        }
        return caret;
    }
    pub fn paint(self: *Field, cx: *custom.PaintCx, bounds: g.Rect, metrics: *LayoutState, caret: *g.Rect) !void {
        try cx.painter.fillRect(.{ .bounds = bounds, .color = self.appearance.background, .radius = 3 });
        if (cx.focused) try cx.painter.strokeRect(bounds, self.appearance.focus_border, 1);
        try cx.painter.pushClip(bounds);
        defer cx.painter.popClip();
        if (self.leading_icon) |icon| try icons.draw(icon, cx.painter, .{ .x = bounds.x + 8, .y = bounds.y + (bounds.height - 14) / 2, .width = 14, .height = 14 }, self.appearance.placeholder);
        const inset = textInset(self.leading_icon);
        const content: g.Rect = .{ .x = bounds.x + inset, .y = caret.y, .width = @max(0, bounds.width - inset - 8), .height = caret.height };
        if (self.selection.start != self.selection.end) {
            const left = metrics.caret(self.text, .{ .size = self.font_size }, self.selection.start);
            const right = metrics.caret(self.text, .{ .size = self.font_size }, self.selection.end);
            try cx.painter.fillRect(.{ .bounds = .{ .x = content.x + left, .y = content.y, .width = right - left, .height = content.height }, .color = self.appearance.selection });
        }
        try cx.painter.drawText(.{ .bounds = content, .text = if (self.text.len == 0) self.placeholder else self.text, .style = .{ .size = self.font_size, .color = if (self.text.len == 0) self.appearance.placeholder else self.appearance.foreground } });
        if (cx.focused and @mod(cx.time, 1.0) < 0.5) try cx.painter.fillRect(.{ .bounds = caret.*, .color = self.appearance.caret });
    }
};
fn textInset(leading: ?icons.Name) f32 {
    return if (leading != null) 28 else 8;
}
fn validLine(bytes: []const u8) bool {
    return std.unicode.utf8ValidateSlice(bytes) and std.mem.indexOfAny(u8, bytes, "\r\n\x00") == null;
}
fn boundary(bytes: []const u8, at: usize) bool {
    return at == bytes.len or bytes[at] & 0xc0 != 0x80;
}
fn previous(bytes: []const u8, at: usize) usize {
    if (at == 0) return 0;
    var i = at - 1;
    while (i > 0 and bytes[i] & 0xc0 == 0x80) : (i -= 1) {}
    return i;
}
fn next(bytes: []const u8, at: usize) usize {
    if (at == bytes.len) return at;
    var i = at + 1;
    while (i < bytes.len and bytes[i] & 0xc0 == 0x80) : (i += 1) {}
    return i;
}
