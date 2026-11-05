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
        return ui.frame.append(.{ .style = options.style, .kind = .{ .button = .{ .label = try ui.frame.allocator().dupe(u8, options.label), .on_click = options.on_click } } });
    }
    pub fn onClick(ui: *Ui, comptime callback: anytype) adapter.ClickHandler {
        return adapter.click(ui.owner, callback);
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
    const Render = struct {
        fn call(value: *const T, target: *tree.Frame, token: identity.Token) !elements.Element {
            var ui: Ui = .{ .frame = target, .owner = token };
            return value.render(&ui);
        }
    };
    return app.read(handle, Render.call, .{ frame, handle.token() });
}
