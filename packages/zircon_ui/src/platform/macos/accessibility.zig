//! AppKit objects are created on demand and read only the committed frame.
const std = @import("std");
const shaping = @import("../../text/shaping.zig");
const platform = @import("../interface.zig");
const objc = @import("objc.zig");
const Id = objc.Id;
const Sel = *opaque {};
const Range = extern struct { location: usize = 0, length: usize = 0 };
const Tree = platform.AccessibilityTree;
extern "c" fn objc_allocateClassPair(Id, [*:0]const u8, usize) Id;
extern "c" fn objc_registerClassPair(Id) void;
extern "c" fn objc_disposeClassPair(Id) void;
extern "c" fn class_addIvar(Id, [*:0]const u8, usize, u8, [*:0]const u8) bool;
extern "c" fn class_addMethod(Id, Sel, *const anyopaque, [*:0]const u8) bool;
extern "c" fn object_getInstanceVariable(Id, [*:0]const u8, *?*anyopaque) ?*anyopaque;
extern "c" fn object_setInstanceVariable(Id, [*:0]const u8, ?*anyopaque) ?*anyopaque;
extern "c" fn sel_registerName([*:0]const u8) Sel;
extern "c" fn NSAccessibilityPostNotification(Id, Id) void;
var element_class: Id = null;

const Entry = struct {
    context: *Context,
    object: Id,
    id: u64,

    fn node(self: *const Entry) ?Tree.Node {
        return self.context.tree.find(self.id);
    }

    fn text(self: *const Entry) ?platform.TextSnapshot {
        const value = self.node() orelse return null;
        if (value.element.role != .text_area or self.context.tree.focused != value.index) return null;
        return self.context.tree.text;
    }
};

pub const Context = struct {
    allocator: std.mem.Allocator,
    view: Id,
    window: Id,
    sink: platform.Sink,
    tree: Tree = .{},
    entries: std.ArrayList(*Entry) = .empty,
    observed: bool = false,

    pub fn deinit(self: *Context) void {
        self.tree = .{};
        for (self.entries.items) |item| self.detach(item);
        self.entries.deinit(self.allocator);
    }

    pub fn update(self: *Context, tree: Tree) void {
        if (!self.observed) {
            self.tree = tree;
            return;
        }
        const old_focus = focusedId(self.tree);
        const old_selection = selectedId(self.tree);
        const old_text = self.tree.text;
        self.tree = tree;
        var index = self.entries.items.len;
        while (index != 0) {
            index -= 1;
            const item = self.entries.items[index];
            if (item.node() != null) continue;
            _ = self.entries.swapRemove(index);
            self.detach(item);
        }
        const focus = focusedId(tree);
        const selection = selectedId(tree);
        if (old_focus != focus) {
            self.notify(if (focus) |id| self.object(id) else self.view, "AXFocusedUIElementChanged");
        } else if (focus != null and old_text != null and tree.text != null) {
            const previous = old_text.?;
            const current = tree.text.?;
            if (previous.revision != current.revision) self.notify(self.object(focus.?), "AXValueChanged");
            if (previous.base_utf16 != current.base_utf16 or !std.meta.eql(previous.selection, current.selection)) {
                self.notify(self.object(focus.?), "AXSelectedTextChanged");
            }
        }
        if (old_selection != selection) {
            const parent = if (selection) |id| tree.find(id).?.element.parent else null;
            self.notify(if (parent) |id| self.object(id) else self.view, "AXSelectedChildrenChanged");
        }
    }

    fn detach(self: *Context, item: *Entry) void {
        _ = object_setInstanceVariable(item.object, "zirconAccessibility", null);
        objc.release(item.object);
        self.allocator.destroy(item);
    }

    fn notify(_: *Context, target: Id, name: []const u8) void {
        if (target != null) NSAccessibilityPostNotification(target, objc.string(name));
    }

    fn object(self: *Context, id: u64) Id {
        if (self.tree.find(id) == null) return null;
        for (self.entries.items) |item| {
            if (item.id == id) return item.object;
        }
        self.entries.ensureUnusedCapacity(self.allocator, 1) catch return null;
        const item = self.allocator.create(Entry) catch return null;
        const result = objc.send(Id, objc.send(Id, element_class, "alloc", .{}), "init", .{}) orelse {
            self.allocator.destroy(item);
            return null;
        };
        item.* = .{ .context = self, .object = result, .id = id };
        _ = object_setInstanceVariable(result, "zirconAccessibility", item);
        self.entries.appendAssumeCapacity(item);
        return result;
    }

    pub fn children(self: *Context, parent: ?u64, selected_only: bool) Id {
        self.observed = true;
        const result = objc.send(Id, objc.class("NSMutableArray"), "array", .{});
        for (self.tree.nodes) |node| {
            if (node.element.parent != parent or (selected_only and !node.element.selected)) continue;
            const bounds = self.tree.rect(node);
            if (bounds.width <= 0 or bounds.height <= 0) continue;
            if (self.object(node.element.id)) |child| objc.send(void, result, "addObject:", .{@as(Id, child)});
        }
        return result;
    }

    pub fn focused(self: *Context) Id {
        self.observed = true;
        return if (focusedId(self.tree)) |id| self.object(id) else null;
    }
};

fn focusedId(tree: Tree) ?u64 {
    const focused = tree.focused orelse return null;
    for (tree.nodes) |node| {
        if (node.index == focused) return node.element.id;
    }
    return null;
}

fn selectedId(tree: Tree) ?u64 {
    for (tree.nodes) |node| {
        if (!node.element.selected) continue;
        const bounds = tree.rect(node);
        if (bounds.width > 0 and bounds.height > 0) return node.element.id;
    }
    return null;
}

fn entry(object: Id) ?*Entry {
    var raw: ?*anyopaque = null;
    _ = object_getInstanceVariable(object, "zirconAccessibility", &raw);
    return if (raw) |value| @ptrCast(@alignCast(value)) else null;
}

fn isElement(object: Id, _: Sel) callconv(.c) bool {
    const self = entry(object) orelse return false;
    return self.node() != null;
}

fn axLabel(object: Id, _: Sel) callconv(.c) Id {
    const node = (entry(object) orelse return null).node() orelse return null;
    return objc.string(node.element.label);
}

fn axRole(object: Id, _: Sel) callconv(.c) Id {
    const node = (entry(object) orelse return null).node() orelse return null;
    return objc.string(switch (node.element.role) {
        .text_area => "AXTextArea",
        .list => "AXList",
        .button => "AXButton",
    });
}

fn axParent(object: Id, _: Sel) callconv(.c) Id {
    const self = entry(object) orelse return null;
    const node = self.node() orelse return null;
    return if (node.element.parent) |id| self.context.object(id) else self.context.view;
}

fn axFrame(object: Id, _: Sel) callconv(.c) objc.CGRect {
    const self = entry(object) orelse return .{};
    const node = self.node() orelse return .{};
    const rect = self.context.tree.rect(node);
    const local: objc.CGRect = .{ .origin = .{ .x = rect.x, .y = rect.y }, .size = .{ .width = rect.width, .height = rect.height } };
    const window_rect = objc.send(objc.CGRect, self.context.view, "convertRect:toView:", .{ local, @as(Id, null) });
    return objc.send(objc.CGRect, self.context.window, "convertRectToScreen:", .{window_rect});
}

fn axChildren(object: Id, _: Sel) callconv(.c) Id {
    const self = entry(object) orelse return null;
    return self.context.children(self.id, false);
}

fn axSelectedChildren(object: Id, _: Sel) callconv(.c) Id {
    const self = entry(object) orelse return null;
    return self.context.children(self.id, true);
}

fn axFocused(object: Id, _: Sel) callconv(.c) bool {
    const self = entry(object) orelse return false;
    return focusedId(self.context.tree) == self.id;
}

fn axSelected(object: Id, _: Sel) callconv(.c) bool {
    const node = (entry(object) orelse return false).node() orelse return false;
    return node.element.selected;
}

fn axPress(object: Id, _: Sel) callconv(.c) bool {
    const self = entry(object) orelse return false;
    const invoke = self.context.sink.accessibility_press orelse return false;
    return invoke(self.context.sink.context, self.id) catch false;
}

fn axValue(object: Id, _: Sel) callconv(.c) Id {
    const text = (entry(object) orelse return null).text() orelse return null;
    return objc.string(text.text);
}

fn axSelection(object: Id, _: Sel) callconv(.c) Id {
    const text = (entry(object) orelse return null).text() orelse return null;
    return objc.string(text.text[text.selection.start..text.selection.end]);
}

fn axSelectionRange(object: Id, _: Sel) callconv(.c) Range {
    const text = (entry(object) orelse return .{}).text() orelse return .{};
    const start = shaping.byteToUtf16(text.text, text.selection.start);
    return .{ .location = start, .length = shaping.byteToUtf16(text.text, text.selection.end) - start };
}

fn axNumberOfCharacters(object: Id, _: Sel) callconv(.c) isize {
    const text = (entry(object) orelse return 0).text() orelse return 0;
    return @intCast(shaping.byteToUtf16(text.text, text.text.len));
}

fn axStringForRange(object: Id, _: Sel, range: Range) callconv(.c) Id {
    const text = (entry(object) orelse return null).text() orelse return null;
    const count = shaping.byteToUtf16(text.text, text.text.len);
    if (range.location > count or range.length > count - range.location) return null;
    const start = shaping.utf16ToByte(text.text, range.location);
    const end = shaping.utf16ToByte(text.text, range.location + range.length);
    if (shaping.byteToUtf16(text.text, start) != range.location or shaping.byteToUtf16(text.text, end) != range.location + range.length) return null;
    return objc.string(text.text[start..end]);
}

fn add(class: Id, comptime method: anytype, name: [:0]const u8, encoding: [:0]const u8) !void {
    if (!class_addMethod(class, sel_registerName(name.ptr), @ptrCast(&method), encoding.ptr)) return error.NativeClassRegistrationFailed;
}

pub fn register() !void {
    if (element_class != null) return;
    const class = objc_allocateClassPair(objc.class("NSAccessibilityElement"), "ZirconAccessibilityElement", 0) orelse return error.NativeClassRegistrationFailed;
    errdefer objc_disposeClassPair(class);
    if (!class_addIvar(class, "zirconAccessibility", @sizeOf(?*anyopaque), @intCast(@ctz(@as(usize, @alignOf(?*anyopaque)))), "^v")) return error.NativeClassRegistrationFailed;
    try add(class, isElement, "isAccessibilityElement", "B@:");
    try add(class, axLabel, "accessibilityLabel", "@@:");
    try add(class, axRole, "accessibilityRole", "@@:");
    try add(class, axParent, "accessibilityParent", "@@:");
    try add(class, axFrame, "accessibilityFrame", "{CGRect={CGPoint=dd}{CGSize=dd}}@:");
    try add(class, axChildren, "accessibilityChildren", "@@:");
    try add(class, axSelectedChildren, "accessibilitySelectedChildren", "@@:");
    try add(class, axFocused, "isAccessibilityFocused", "B@:");
    try add(class, axSelected, "isAccessibilitySelected", "B@:");
    try add(class, axPress, "accessibilityPerformPress", "B@:");
    try add(class, axValue, "accessibilityValue", "@@:");
    try add(class, axSelection, "accessibilitySelectedText", "@@:");
    try add(class, axSelectionRange, "accessibilitySelectedTextRange", "{_NSRange=QQ}@:");
    try add(class, axNumberOfCharacters, "accessibilityNumberOfCharacters", "q@:");
    try add(class, axStringForRange, "accessibilityStringForRange:", "@@:{_NSRange=QQ}");
    objc_registerClassPair(class);
    element_class = class;
}
