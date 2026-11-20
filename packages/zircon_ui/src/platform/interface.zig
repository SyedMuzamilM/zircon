//! Private platform seam. Native callbacks borrow payload bytes only until the
//! callback returns; framework dispatch never retains them. No OS types escape.
const std = @import("std");
const images = @import("../graphics/images.zig");
const scene = @import("../graphics/scene.zig");
const g = @import("../layout/geometry.zig");
const measure = @import("../layout/measure.zig");
const text_typography = @import("../text/typography.zig");
const style = @import("../ui/style.zig");
pub const Cursor = style.Cursor;
pub const WindowOptions = struct {
    title: []const u8 = "Zircon",
    width: f32 = 1080,
    height: f32 = 720,
    visible: bool = true,
    /// Borrowed only during window creation. macOS uses an application-wide
    /// Dock icon; other desktop adapters use their native window icon.
    icon: ?images.View = null,
    chrome: enum { system, integrated } = .system,
    menus: []const Menu = &.{},
    background: g.Color = .{ .r = 0.07, .g = 0.08, .b = 0.1 },
};
pub const Modifiers = packed struct(u8) { shift: bool = false, control: bool = false, alt: bool = false, command: bool = false, _padding: u4 = 0 };
/// Menus are copied by the platform during creation. A null action is a separator.
pub const MenuItem = struct { label: []const u8 = "", action: ?u32 = null, key: []const u8 = "", modifiers: Modifiers = .{ .command = true } };
pub const Menu = struct { label: []const u8, items: []const MenuItem };
pub const Key = enum { slash, comma, left_bracket, right_bracket, unknown, left, right, up, down, home, end, page_up, page_down, backspace, delete, enter, tab, escape, space, a, b, c, d, e, f, g, h, i, j, k, l, m, n, o, p, q, r, s, t, u, v, w, x, y, z, period, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12 };
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

/// Stable semantic identity within a window. A parent, when supplied, is
/// another accessibility element in the same committed frame.
pub const Accessibility = struct {
    pub const Role = enum { text_area, list, button };
    id: u64,
    role: Role,
    label: []const u8,
    parent: ?u64 = null,
    selected: bool = false,
};
pub const AccessibilityTree = struct {
    pub const Node = struct { element: Accessibility, index: u32 };
    nodes: []const Node = &.{},
    bounds: []const g.Rect = &.{},
    focused: ?u32 = null,
    text: ?TextSnapshot = null,
    viewport: g.Rect = .{},

    pub fn find(tree: AccessibilityTree, id: u64) ?Node {
        for (tree.nodes) |node| {
            if (node.element.id != id) continue;
            const bounds = tree.rect(node);
            return if (bounds.width > 0 and bounds.height > 0) node else null;
        }
        return null;
    }

    pub fn rect(tree: AccessibilityTree, node: Node) g.Rect {
        return tree.bounds[node.index].intersection(tree.viewport);
    }
};

pub const Input = union(enum) {
    pointer_down: Pointer,
    pointer_up: Pointer,
    pointer_move: Pointer,
    pointer_leave,
    files_hover: struct { position: g.Point, active: bool },
    files_drop: struct { position: g.Point, paths: []const []const u8 },
    scroll: struct { position: g.Point, x: f32, y: f32, modifiers: Modifiers = .{} },
    key_down: struct { key: Key, modifiers: Modifiers = .{}, repeat: bool = false },
    text: []const u8,
    edit: TextEdit,
    unmark: u64,
    resize: g.Size,
    focus: bool,
    action: u32,
    appearance: bool, // true for the system dark appearance
    close,
};
pub const Sink = struct {
    context: *anyopaque,
    event: *const fn (*anyopaque, Input) anyerror!void,
    drag_region: ?*const fn (*anyopaque, g.Point) bool = null,
    accessibility_press: ?*const fn (*anyopaque, u64) anyerror!bool = null,
};
pub const Surface = struct {
    pub const PathKind = enum { file, folder };
    context: *anyopaque,
    ops: *const Ops,
    pub const Ops = struct {
        font_families: ?*const fn (*anyopaque, std.mem.Allocator) anyerror![]text_typography.FontName = null,
        deinit: *const fn (*anyopaque) void,
        size: *const fn (*anyopaque) g.Size,
        present: *const fn (*anyopaque, scene.Frame) anyerror!bool,
        measurer: *const fn (*anyopaque) measure.Measurer,
        snapshot: *const fn (*anyopaque, scene.Frame, []const u8) anyerror!void,
        clipboard_read: *const fn (*anyopaque, std.mem.Allocator) anyerror![]u8,
        clipboard_write: *const fn (*anyopaque, []const u8) anyerror!void,
        consume_key: ?*const fn (*anyopaque) void = null,
        set_cursor: ?*const fn (*anyopaque, Cursor) void = null,
        set_text_input: ?*const fn (*anyopaque, ?TextSnapshot) void = null,
        set_accessibility: ?*const fn (*anyopaque, AccessibilityTree) void = null,
        accept_close: ?*const fn (*anyopaque) void = null,
        set_parent: ?*const fn (*anyopaque, ?Surface) void = null,
        raise: ?*const fn (*anyopaque) void = null,
        typography: ?*const fn (*anyopaque, text_typography.Typography) void = null,
        system_dark: ?*const fn (*anyopaque) bool = null,
        set_appearance: ?*const fn (*anyopaque, ?bool) void = null,
        choose_files: ?*const fn (*anyopaque, std.mem.Allocator) anyerror![][]u8 = null,
        choose_path: ?*const fn (*anyopaque, std.mem.Allocator, PathKind) anyerror!?[]u8 = null,
    };
    pub fn setCursor(s: Surface, cursor: Cursor) void {
        if (s.ops.set_cursor) |f| f(s.context, cursor);
    }
    pub fn systemDark(s: Surface) bool {
        return if (s.ops.system_dark) |f| f(s.context) else true;
    }
    pub fn setAppearance(s: Surface, dark: ?bool) void {
        if (s.ops.set_appearance) |f| f(s.context, dark);
    }
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
    pub fn fontFamilies(s: Surface, a: std.mem.Allocator) ![]text_typography.FontName {
        if (s.ops.font_families) |function| return function(s.context, a);
        return &.{};
    }
    pub fn setTypography(s: Surface, value: text_typography.Typography) void {
        if (s.ops.typography) |function| function(s.context, value);
    }
    /// Caller owns the slice and each selected absolute path. Empty means cancel.
    pub fn chooseFiles(s: Surface, allocator: std.mem.Allocator) ![][]u8 {
        const function = s.ops.choose_files orelse return error.NativeDialogUnavailable;
        return function(s.context, allocator);
    }
    pub fn choosePath(s: Surface, allocator: std.mem.Allocator, kind: PathKind) !?[]u8 {
        const function = s.ops.choose_path orelse return error.NativeDialogUnavailable;
        return function(s.context, allocator, kind);
    }
    pub fn snapshot(s: Surface, frame: scene.Frame, path: []const u8) !void {
        return s.ops.snapshot(s.context, frame, path);
    }
    pub fn setTextInput(s: Surface, value: ?TextSnapshot) void {
        if (s.ops.set_text_input) |function| function(s.context, value);
    }
    pub fn setAccessibility(s: Surface, value: AccessibilityTree) void {
        if (s.ops.set_accessibility) |function| function(s.context, value);
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
