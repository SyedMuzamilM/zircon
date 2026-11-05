//! Private platform seam. Native callbacks borrow payload bytes only until the
//! callback returns; framework dispatch never retains them. No OS types escape.
const std = @import("std");
const g = @import("../layout/geometry.zig");
const scene = @import("../graphics/scene.zig");
const measure = @import("../layout/measure.zig");
pub const WindowOptions = struct {
    title: []const u8 = "Zircon",
    width: f32 = 1080,
    height: f32 = 720,
    visible: bool = true,
    chrome: enum { system, integrated } = .system,
    background: g.Color = .{ .r = 0.07, .g = 0.08, .b = 0.1 },
};
pub const Modifiers = packed struct(u8) { shift: bool = false, control: bool = false, alt: bool = false, command: bool = false, _padding: u4 = 0 };
pub const Key = enum { comma, unknown, left, right, up, down, home, end, page_up, page_down, backspace, delete, enter, tab, escape, space, a, b, c, d, e, f, g, h, i, j, k, l, m, n, o, p, q, r, s, t, u, v, w, x, y, z };
pub const Pointer = struct { position: g.Point, button: enum { primary, secondary, middle } = .primary, modifiers: Modifiers = .{}, clicks: u8 = 1 };
/// Ordered UTF-8 byte range. Neither endpoint may split a code point.
pub const TextRange = struct {
    start: usize,
    end: usize,
    pub fn validate(range: TextRange, text: []const u8) !void {
        if (range.start > range.end or range.end > text.len) return error.InvalidTextRange;
        inline for (.{ range.start, range.end }) |offset| if (offset < text.len and text[offset] & 0xc0 == 0x80) return error.InvalidTextRange;
    }
};
/// The committed focused provider's owned text and logical caret geometry.
/// Platform adapters borrow it until the next successful frame or teardown.
pub const TextSnapshot = struct {
    /// Surrounding text may be a bounded document excerpt. Selection/marked
    /// ranges are local bytes; bases locate the excerpt in the full document.
    text: []const u8,
    base_byte: usize = 0,
    base_utf16: usize = 0,
    revision: u64,
    selection: TextRange,
    marked: ?TextRange = null,
    caret: g.Rect,
    pub fn validate(value: TextSnapshot) !void {
        if (!std.unicode.utf8ValidateSlice(value.text)) return error.InvalidUtf8;
        if (value.base_byte > std.math.maxInt(usize) - value.text.len) return error.InvalidTextRange;
        var utf16_length: usize = 0;
        for (value.text) |byte| if (byte & 0xc0 != 0x80) {
            utf16_length += if (byte >= 0xf0) @as(usize, 2) else 1;
        };
        if (value.base_utf16 > std.math.maxInt(usize) - utf16_length) return error.InvalidTextRange;
        try value.selection.validate(value.text);
        if (value.marked) |marked| try marked.validate(value.text);
        inline for (.{ "x", "y", "width", "height" }) |field| if (!std.math.isFinite(@field(value.caret, field))) return error.InvalidTextCaret;
        if (value.caret.width < 0 or value.caret.height < 0) return error.InvalidTextCaret;
    }
};
/// Replacement uses absolute document bytes against exactly `revision`;
/// selection is relative to inserted text. Models must refuse stale revisions.
pub const TextEdit = struct {
    revision: u64,
    range: TextRange,
    text: []const u8,
    selection: TextRange,
    composing: bool = false,
    pub fn validate(edit: TextEdit, snapshot: TextSnapshot) !void {
        if (edit.revision != snapshot.revision) return error.StaleTextSnapshot;
        if (edit.range.start < snapshot.base_byte or edit.range.end < snapshot.base_byte) return error.InvalidTextRange;
        try (TextRange{ .start = edit.range.start - snapshot.base_byte, .end = edit.range.end - snapshot.base_byte }).validate(snapshot.text);
        if (!std.unicode.utf8ValidateSlice(edit.text)) return error.InvalidUtf8;
        try edit.selection.validate(edit.text);
    }
};
pub const Input = union(enum) {
    pointer_down: Pointer,
    pointer_up: Pointer,
    pointer_move: Pointer,
    scroll: struct { position: g.Point, x: f32, y: f32, modifiers: Modifiers = .{} },
    key_down: struct { key: Key, modifiers: Modifiers = .{}, repeat: bool = false },
    text: []const u8,
    edit: TextEdit,
    unmark: u64,
    resize: g.Size,
    focus: bool,
    close,
};
pub const Sink = struct {
    context: *anyopaque,
    event: *const fn (*anyopaque, Input) anyerror!void,
    drag_region: ?*const fn (*anyopaque, g.Point) bool = null,
};
pub const Surface = struct {
    context: *anyopaque,
    ops: *const Ops,
    pub const Ops = struct {
        deinit: *const fn (*anyopaque) void,
        size: *const fn (*anyopaque) g.Size,
        present: *const fn (*anyopaque, scene.Frame) anyerror!bool,
        measurer: *const fn (*anyopaque) measure.Measurer,
        snapshot: *const fn (*anyopaque, scene.Frame, []const u8) anyerror!void,
        clipboard_read: *const fn (*anyopaque, std.mem.Allocator) anyerror![]u8,
        clipboard_write: *const fn (*anyopaque, []const u8) anyerror!void,
        set_text_input: ?*const fn (*anyopaque, ?TextSnapshot) void = null,
        accept_close: ?*const fn (*anyopaque) void = null,
        set_parent: ?*const fn (*anyopaque, ?Surface) void = null,
        raise: ?*const fn (*anyopaque) void = null,
    };
    pub fn deinit(s: Surface) void {
        s.ops.deinit(s.context);
    }
    pub fn size(s: Surface) g.Size {
        return s.ops.size(s.context);
    }
    pub fn present(s: Surface, frame: scene.Frame) !bool {
        return s.ops.present(s.context, frame);
    }
    pub fn measurer(s: Surface) measure.Measurer {
        return s.ops.measurer(s.context);
    }
    pub fn snapshot(s: Surface, frame: scene.Frame, path: []const u8) !void {
        return s.ops.snapshot(s.context, frame, path);
    }
    pub fn setTextInput(s: Surface, value: ?TextSnapshot) void {
        if (s.ops.set_text_input) |function| function(s.context, value);
    }
    /// Completes an accepted close request. The native object stays allocated
    /// until ordinary window teardown outside the event callback.
    pub fn acceptClose(s: Surface) void {
        if (s.ops.accept_close) |function| function(s.context);
    }
    pub fn setParent(s: Surface, parent: ?Surface) void {
        if (s.ops.set_parent) |f| f(s.context, parent);
    }
    pub fn raise(s: Surface) void {
        if (s.ops.raise) |f| f(s.context);
    }
};
