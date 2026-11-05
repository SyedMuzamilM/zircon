//! Frame-local declarative builder. Copies every borrowed text/children slice.
const std = @import("std");
const tree = @import("tree.zig");
const elements = @import("element.zig");
const styles = @import("style.zig");
const adapter = @import("adapter.zig");
const runtime = @import("../app/app.zig");
const identity = @import("../entity/entity.zig");
pub const Button = struct { label: []const u8, on_click: ?adapter.ClickHandler = null, style: styles.Style = .{} };
pub const Ui = struct {
    frame: *tree.Frame,
    owner: identity.Token,
    /// Renders another entity through a const borrow and records its version in
    /// this frame. The child entity owns its state and generated event handlers.
    pub fn view(ui: *Ui, handle: anytype) !elements.Element {
        return render(ui.frame.app orelse return error.NoFrameApplication, handle, ui.frame);
    }
    /// The reader follows App.read's pointer-free result contract. Use an owned
    /// output argument when a view needs to copy a larger snapshot.
    pub fn watch(ui: *Ui, handle: anytype, comptime reader: anytype, args: anytype) WatchResult(@TypeOf(reader)) {
        const app = ui.frame.app orelse return error.NoFrameApplication;
        const result = try app.read(handle, reader, args);
        try ui.frame.watch(handle.token(), try app.version(handle));
        return result;
    }
    pub fn text(ui: *Ui, value: []const u8) !elements.Element {
        if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidUtf8;
        return ui.frame.append(.{ .kind = .{ .text = try ui.frame.allocator().dupe(u8, value) } });
    }
    pub fn textFmt(ui: *Ui, comptime format: []const u8, args: anytype) !elements.Element {
        return ui.text(try std.fmt.allocPrint(ui.frame.allocator(), format, args));
    }
    pub fn button(ui: *Ui, options: Button) !elements.Element {
        try options.style.validate();
        if (!std.unicode.utf8ValidateSlice(options.label)) return error.InvalidUtf8;
        return ui.frame.append(.{ .style = options.style, .focusable = true, .kind = .{ .button = .{ .label = try ui.frame.allocator().dupe(u8, options.label), .on_click = options.on_click } } });
    }
    pub fn onClick(ui: *Ui, comptime callback: anytype) adapter.ClickHandler {
        return adapter.click(ui.owner, callback);
    }
    pub fn onInput(ui: *Ui, comptime callback: anytype) adapter.InputHandler {
        return adapter.input(ui.owner, callback);
    }
    pub fn onClickWith(ui: *Ui, value: anytype, comptime callback: anytype) !adapter.ClickHandler {
        return adapter.clickWith(ui.allocator(), ui.owner, value, callback);
    }
    pub fn onInputWith(ui: *Ui, value: anytype, comptime callback: anytype) !adapter.InputHandler {
        return adapter.inputWith(ui.allocator(), ui.owner, value, callback);
    }
    pub const Listeners = struct { on_input: ?adapter.InputHandler = null, on_capture: ?adapter.InputHandler = null, focusable: bool = false };
    pub fn listen(ui: *Ui, element: elements.Element, options: Listeners) !elements.Element {
        _ = try ui.frame.get(element);
        const node = &ui.frame.nodes.items[element.index];
        node.on_input = options.on_input;
        node.on_capture = options.on_capture;
        node.focusable = options.focusable;
        return element;
    }
    /// Takes focus when this logical element first enters a committed frame.
    pub fn autofocus(ui: *Ui, element: elements.Element) !elements.Element {
        _ = try ui.frame.get(element);
        ui.frame.nodes.items[element.index].autofocus = true;
        return element;
    }
    /// Changing this generation requests focus after a successful frame. It is
    /// useful when a command activates an already existing logical control.
    pub fn requestFocus(ui: *Ui, element: elements.Element, generation: u64) !elements.Element {
        _ = try ui.frame.get(element);
        ui.frame.nodes.items[element.index].focus_request = generation;
        return element;
    }
    /// Restricts keyboard traversal and pointer routing to this subtree.
    pub fn modal(ui: *Ui, element: elements.Element) !elements.Element {
        _ = try ui.frame.get(element);
        ui.frame.nodes.items[element.index].modal = true;
        return element;
    }
    pub fn custom(ui: *Ui, comptime T: type, value: T, style: styles.Style) !elements.Element {
        try style.validate();
        if (ui.frame.retiring) return error.InvalidFrame;
        if (ui.frame.nodes.items.len >= std.math.maxInt(u32)) return error.ElementCapacityExceeded;
        // Reserve both registries before taking ownership of value. Every error
        // leaves it with the caller; after creation there is no fallible step.
        try ui.frame.nodes.ensureUnusedCapacity(ui.allocator(), 1);
        try ui.frame.cleanups.ensureUnusedCapacity(ui.allocator(), 1);
        const custom_value = try @import("custom.zig").create(T, ui.frame.allocator(), value);
        ui.frame.cleanups.appendAssumeCapacity(.{ .object = custom_value.object, .destroy = custom_value.destroy });
        ui.frame.nodes.appendAssumeCapacity(.{ .style = style, .kind = .{ .custom = custom_value } });
        return .{ .index = @intCast(ui.frame.nodes.items.len - 1), .frame_epoch = ui.frame.epoch };
    }
    pub fn allocator(ui: *Ui) std.mem.Allocator {
        return ui.frame.allocator();
    }
    pub fn viewport(ui: *const Ui) @import("../layout/geometry.zig").Size {
        return ui.frame.viewport;
    }
    pub fn dragRegion(ui: *Ui, element: elements.Element) !elements.Element {
        _ = try ui.frame.get(element);
        ui.frame.nodes.items[element.index].drag_region = true;
        return element;
    }
    pub fn animate(ui: *Ui, key_value: u64, target: f32, transition: @import("../animation/timeline.zig").Transition) !f32 {
        const timeline = ui.frame.timeline orelse return target;
        const track = (@as(u128, ui.owner.slot) << 96) | (@as(u128, ui.owner.generation) << 64) | key_value;
        return timeline.sample(track, target, transition, ui.frame.time);
    }
    pub fn animateColor(ui: *Ui, key_value: u64, target: styles.Color, transition: @import("../animation/timeline.zig").Transition) !styles.Color {
        if (key_value > std.math.maxInt(u64) / 4) return error.InvalidAnimationKey;
        return .{ .r = std.math.clamp(try ui.animate(key_value * 4, target.r, transition), 0, 1), .g = std.math.clamp(try ui.animate(key_value * 4 + 1, target.g, transition), 0, 1), .b = std.math.clamp(try ui.animate(key_value * 4 + 2, target.b, transition), 0, 1), .a = std.math.clamp(try ui.animate(key_value * 4 + 3, target.a, transition), 0, 1) };
    }
    pub const Presence = struct { visible: bool, opacity: f32 };
    /// Keep the exiting element in the tree while its opacity approaches zero.
    pub fn presence(ui: *Ui, key_value: u64, visible: bool, transition: @import("../animation/timeline.zig").Transition) !Presence {
        const opacity = std.math.clamp(try ui.animate(key_value, if (visible) 1 else 0, transition), 0, 1);
        return .{ .visible = visible or opacity > 0.001, .opacity = opacity };
    }
    /// Reserves four consecutive scalar keys, like animateColor. Width and
    /// height stay nonnegative when an underdamped spring overshoots its target.
    pub fn animateRect(ui: *Ui, key_value: u64, target: @import("../layout/geometry.zig").Rect, transition: @import("../animation/timeline.zig").Transition) !@import("../layout/geometry.zig").Rect {
        if (key_value > std.math.maxInt(u64) / 4) return error.InvalidAnimationKey;
        if (target.width < 0 or target.height < 0) return error.InvalidAnimation;
        return .{ .x = try ui.animate(key_value * 4, target.x, transition), .y = try ui.animate(key_value * 4 + 1, target.y, transition), .width = @max(0, try ui.animate(key_value * 4 + 2, target.width, transition)), .height = @max(0, try ui.animate(key_value * 4 + 3, target.height, transition)) };
    }
    pub fn column(ui: *Ui, style: styles.Style, children: []const elements.Element) !elements.Element {
        var actual = style;
        actual.direction = .column;
        return ui.div(actual, children);
    }
    pub fn row(ui: *Ui, style: styles.Style, children: []const elements.Element) !elements.Element {
        var actual = style;
        actual.direction = .row;
        return ui.div(actual, children);
    }
    pub fn stack(ui: *Ui, style: styles.Style, children: []const elements.Element) !elements.Element {
        var actual = style;
        actual.direction = .stack;
        return ui.div(actual, children);
    }
    pub fn div(ui: *Ui, style: styles.Style, children: []const elements.Element) !elements.Element {
        try style.validate();
        for (children, 0..) |child, i| {
            if ((try ui.frame.get(child)).parent != null) return error.ElementAlreadyParented;
            for (children[0..i]) |previous| if (previous.index == child.index) return error.DuplicateChild;
        }
        const indices = try ui.frame.allocator().alloc(u32, children.len);
        for (children, 0..) |child, i| indices[i] = child.index;
        const parent = try ui.frame.append(.{ .style = style, .children = indices, .kind = .container });
        for (indices) |index| ui.frame.nodes.items[index].parent = parent.index;
        return parent;
    }
    pub fn styled(ui: *Ui, element: elements.Element, style: styles.Style) !elements.Element {
        _ = try ui.frame.get(element);
        try style.validate();
        ui.frame.nodes.items[element.index].style = style;
        return element;
    }
    pub fn key(ui: *Ui, value: elements.Key, element: elements.Element) !elements.Element {
        _ = try ui.frame.get(element);
        const owned: elements.Key = switch (value) {
            .number => value,
            .string => |s| .{ .string = try ui.frame.allocator().dupe(u8, s) },
        };
        ui.frame.nodes.items[element.index].key = owned;
        return element;
    }
};
pub fn render(app: *runtime.App, handle: anytype, frame: *tree.Frame) !elements.Element {
    const T = @TypeOf(handle).State;
    comptime adapter.requireView(T);
    frame.app = app;
    try frame.watch(handle.token(), try app.version(handle));
    const Render = struct {
        fn call(value: *const T, target: *tree.Frame, token: identity.Token) !elements.Element {
            var ui: Ui = .{ .frame = target, .owner = token };
            return value.render(&ui);
        }
    };
    return app.read(handle, Render.call, .{ frame, handle.token() });
}
fn WatchResult(comptime F: type) type {
    const result = @typeInfo(F).@"fn".return_type.?;
    return anyerror!(if (@typeInfo(result) == .error_union) @typeInfo(result).error_union.payload else result);
}
