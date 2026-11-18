//! Eager frame-owned elements with GPUI-style chaining. Copies alias one draft;
//! build is idempotent, while mutations after build fail the staging frame.
const std = @import("std");
const style_module = @import("../text/style.zig");
const adapter = @import("adapter.zig");
const elements = @import("element.zig");
const styles = @import("style.zig");
const tree = @import("tree.zig");
const builder = @import("ui.zig");
const TextStyle = style_module.TextStyle;
const Draft = struct {
    element: elements.Element,
    children: std.ArrayList(elements.Element) = .empty,
    accepts_children: bool,
    finished: bool = false,
    failure: ?anyerror = null,
};
pub const Fluent = struct {
    ui: builder.Ui,
    epoch: u64,
    fn valid(self: Fluent) bool {
        return !self.ui.frame.retiring and self.ui.frame.epoch == self.epoch;
    }
    fn failed(self: Fluent, err: anyerror) Chain {
        if (self.valid() and self.ui.frame.fluent_error == null) self.ui.frame.fluent_error = err;
        return .{ .factory = self, .value = .{ .failed = err } };
    }
    fn wrap(self: Fluent, value: anyerror!elements.Element, accepts_children: bool) Chain {
        const element = value catch |err| return self.failed(err);
        const draft = self.ui.allocator().create(Draft) catch |err| return self.failed(err);
        draft.* = .{ .element = element, .accepts_children = accepts_children };
        return .{ .factory = self, .value = .{ .draft = draft } };
    }
    pub fn div(self: Fluent) Chain {
        if (!self.valid()) return self.failed(error.InvalidFrame);
        var ui = self.ui;
        return self.wrap(ui.div(.{}, .{}), true);
    }
    /// Rows and stacks use the same eager children and rollback rules as div.
    pub fn row(self: Fluent) Chain {
        return self.div().flex();
    }
    pub fn column(self: Fluent) Chain {
        return self.div().flex_col();
    }
    pub fn stack(self: Fluent) Chain {
        return self.div().stack();
    }
    /// Render an entity through its normal const lease, tracking the dependency
    /// in this frame before decorating the resulting element.
    pub fn view(self: Fluent, handle: anytype) Chain {
        if (!self.valid()) return self.failed(error.InvalidFrame);
        var ui = self.ui;
        return self.wrap(ui.view(handle), false);
    }
    pub fn text(self: Fluent, bytes: []const u8) Chain {
        if (!self.valid()) return self.failed(error.InvalidFrame);
        var ui = self.ui;
        return self.wrap(ui.text(bytes), false);
    }
    pub fn textFmt(self: Fluent, comptime format: []const u8, args: anytype) Chain {
        if (!self.valid()) return self.failed(error.InvalidFrame);
        var ui = self.ui;
        return self.wrap(ui.textFmt(format, args), false);
    }
    pub fn button(self: Fluent, options: builder.Button) Chain {
        if (!self.valid()) return self.failed(error.InvalidFrame);
        var ui = self.ui;
        var actual = options;
        actual.children = &.{};
        return self.wrap(ui.button(actual), true).children(options.children);
    }
    pub fn adopt(self: Fluent, value: anytype) Chain {
        if (!self.valid()) return self.failed(error.InvalidFrame);
        return self.wrap(resolve(value), false);
    }
};
pub const Chain = struct {
    factory: Fluent,
    value: union(enum) { draft: *Draft, failed: anyerror },
    fn fail(self: Chain, err: anyerror) Chain {
        if (self.factory.valid()) {
            if (self.factory.ui.frame.fluent_error == null) self.factory.ui.frame.fluent_error = err;
            if (self.value == .draft and self.value.draft.failure == null) self.value.draft.failure = err;
        }
        return .{ .factory = self.factory, .value = .{ .failed = err } };
    }
    fn draft(self: Chain, mutable: bool) !*Draft {
        if (!self.factory.valid()) return error.InvalidFrame;
        const result = switch (self.value) {
            .draft => |value| value,
            .failed => |err| return err,
        };
        if (result.failure) |err| return err;
        _ = try self.factory.ui.frame.get(result.element);
        if (mutable and result.finished) return error.BuilderFinished;
        return result;
    }
    pub fn build(self: Chain) !elements.Element {
        return self.finish() catch |err| {
            _ = self.fail(err);
            return err;
        };
    }
    fn finish(self: Chain) !elements.Element {
        const value = try self.draft(false);
        if (value.finished) return value.element;
        const frame = self.factory.ui.frame;
        try frame.nodes.items[value.element.index].style.validate();
        if (value.accepts_children) {
            const indices = try frame.prepareChildren(value.children.items);
            frame.nodes.items[value.element.index].children = indices;
            for (indices) |index| frame.nodes.items[index].parent = value.element.index;
        }
        value.finished = true;
        return value.element;
    }
    pub fn child(self: Chain, child_value: anytype) Chain {
        const value = self.draft(true) catch |err| return self.fail(err);
        if (!value.accepts_children) return self.fail(error.ElementCannotHaveChildren);
        if (@TypeOf(child_value) == Chain) {
            if (child_value.factory.ui.frame != self.factory.ui.frame or child_value.factory.epoch != self.factory.epoch) return self.fail(error.InvalidFrame);
            if (child_value.value == .draft and child_value.value.draft == value) return self.fail(error.CyclicElement);
        }
        const element = resolve(child_value) catch |err| return self.fail(err);
        const node = self.factory.ui.frame.get(element) catch |err| return self.fail(err);
        if (element.index == value.element.index) return self.fail(error.CyclicElement);
        if (node.parent != null) return self.fail(error.ElementAlreadyParented);
        for (value.children.items) |existing| if (existing.index == element.index) return self.fail(error.DuplicateChild);
        value.children.append(self.factory.ui.allocator(), element) catch |err| return self.fail(err);
        return self;
    }
    pub fn children(self: Chain, values: anytype) Chain {
        var next = self;
        switch (@typeInfo(@TypeOf(values))) {
            .@"struct" => |info| {
                if (!info.is_tuple) @compileError("fluent children require a tuple, array or slice");
                inline for (info.field_names) |name| next = next.child(@field(values, name));
            },
            .array => for (values) |value| {
                next = next.child(value);
            },
            .pointer => |info| switch (info.size) {
                .one => if (@typeInfo(info.child) == .array) {
                    const slice: []const @typeInfo(info.child).array.child = values;
                    return self.children(slice);
                } else return self.children(values.*),
                .slice => for (values) |value| {
                    next = next.child(value);
                },
                else => @compileError("fluent children require a tuple, array or slice"),
            },
            else => @compileError("fluent children require a tuple, array or slice"),
        }
        return next;
    }
    pub fn style(self: Chain, value: styles.Style) Chain {
        const record = self.draft(true) catch |err| return self.fail(err);
        self.factory.ui.frame.nodes.items[record.element.index].style = value;
        return self;
    }
    pub fn when(self: Chain, condition: bool, changes: anytype) Chain {
        const record = self.draft(true) catch |err| return self.fail(err);
        inline for (@typeInfo(@TypeOf(changes)).@"struct".field_names) |field| {
            if (!@hasField(styles.Style, field)) @compileError("unknown style field: " ++ field);
            if (condition) @field(self.factory.ui.frame.nodes.items[record.element.index].style, field) = @field(changes, field);
        }
        return self;
    }
    /// Set only the named fields. Existing text/padding/layout fields survive.
    pub fn refine(self: Chain, changes: anytype) Chain {
        return self.when(true, changes);
    }
    pub fn text_style(self: Chain, value: TextStyle) Chain {
        return self.refine(.{ .text = value });
    }
    pub fn direction(self: Chain, value: styles.Direction) Chain {
        return self.refine(.{ .direction = value });
    }
    pub fn items(self: Chain, value: styles.Align) Chain {
        return self.refine(.{ .align_items = value });
    }
    pub fn justify(self: Chain, value: styles.Justify) Chain {
        return self.refine(.{ .justify_content = value });
    }
    pub fn grow_by(self: Chain, value: f32) Chain {
        return self.refine(.{ .flex_grow = value });
    }
    pub fn shrink_by(self: Chain, value: f32) Chain {
        return self.refine(.{ .flex_shrink = value });
    }
    pub fn min_w(self: Chain, value: styles.Length) Chain {
        return self.refine(.{ .min_width = value });
    }
    pub fn max_w(self: Chain, value: styles.Length) Chain {
        return self.refine(.{ .max_width = value });
    }
    pub fn min_h(self: Chain, value: styles.Length) Chain {
        return self.refine(.{ .min_height = value });
    }
    pub fn max_h(self: Chain, value: styles.Length) Chain {
        return self.refine(.{ .max_height = value });
    }
    pub fn margin(self: Chain, value: styles.Insets) Chain {
        return self.refine(.{ .margin = value });
    }
    pub fn background(self: Chain, value: ?styles.Color) Chain {
        return self.refine(.{ .background = value });
    }
    pub fn hover_background(self: Chain, value: ?styles.Color) Chain {
        return self.refine(.{ .hover_background = value });
    }
    pub fn id(self: Chain, key: elements.Key) Chain {
        const record = self.draft(true) catch |err| return self.fail(err);
        var ui = self.factory.ui;
        _ = ui.key(key, record.element) catch |err| return self.fail(err);
        return self;
    }
    pub fn on_click(self: Chain, handler: ?anyerror!adapter.ClickHandler) Chain {
        const record = self.draft(true) catch |err| return self.fail(err);
        const callback = if (handler) |actual| actual catch |err| return self.fail(err) else null;
        const node = &self.factory.ui.frame.nodes.items[record.element.index];
        if (node.kind != .button) return self.fail(error.ClickRequiresButton);
        node.kind.button.on_click = callback;
        return self;
    }
    pub fn on_input(self: Chain, handler: anyerror!adapter.InputHandler) Chain {
        const record = self.draft(true) catch |err| return self.fail(err);
        const callback = handler catch |err| return self.fail(err);
        self.factory.ui.frame.nodes.items[record.element.index].on_input = callback;
        return self;
    }
    pub fn on_capture(self: Chain, handler: anyerror!adapter.InputHandler) Chain {
        return self.listeners(.{ .on_capture = handler });
    }
    /// Applies typed handlers without changing unspecified focus/input state.
    pub fn listeners(self: Chain, options: builder.Ui.Listeners) Chain {
        const record = self.draft(true) catch |err| return self.fail(err);
        const input_handler = if (options.on_input) |handler| handler catch |err| return self.fail(err) else null;
        const capture_handler = if (options.on_capture) |handler| handler catch |err| return self.fail(err) else null;
        const node = &self.factory.ui.frame.nodes.items[record.element.index];
        if (input_handler) |handler| node.on_input = handler;
        if (capture_handler) |handler| node.on_capture = handler;
        if (options.focusable) |value| node.focusable = value;
        return self;
    }
    pub fn cache(self: Chain) Chain {
        const record = self.draft(true) catch |err| return self.fail(err);
        self.factory.ui.frame.nodes.items[record.element.index].cache = true;
        return self;
    }
    pub fn focusable(self: Chain) Chain {
        return self.listeners(.{ .focusable = true });
    }
    pub fn autofocus(self: Chain) Chain {
        const record = self.draft(true) catch |err| return self.fail(err);
        self.factory.ui.frame.nodes.items[record.element.index].autofocus = true;
        return self;
    }
    pub fn request_focus(self: Chain, generation: u64) Chain {
        const record = self.draft(true) catch |err| return self.fail(err);
        self.factory.ui.frame.nodes.items[record.element.index].focus_request = generation;
        return self;
    }
    pub fn modal(self: Chain) Chain {
        const record = self.draft(true) catch |err| return self.fail(err);
        self.factory.ui.frame.nodes.items[record.element.index].modal = true;
        return self;
    }
    pub fn drag_region(self: Chain) Chain {
        const record = self.draft(true) catch |err| return self.fail(err);
        self.factory.ui.frame.nodes.items[record.element.index].drag_region = true;
        return self;
    }
    pub fn grid_cols(self: Chain, columns: u16) Chain {
        return self.refine(.{ .direction = @as(styles.Direction, .grid), .grid_columns = columns });
    }
    pub fn flex_wrap(self: Chain) Chain {
        return self.refine(.{ .flex_wrap = true });
    }
    pub fn stack(self: Chain) Chain {
        return self.when(true, .{ .direction = @as(styles.Direction, .stack) });
    }
    pub fn flex(self: Chain) Chain {
        return self.when(true, .{ .direction = @as(styles.Direction, .row) });
    }
    pub fn flex_col(self: Chain) Chain {
        return self.when(true, .{ .direction = @as(styles.Direction, .column) });
    }
    pub fn items_center(self: Chain) Chain {
        return self.when(true, .{ .align_items = @as(styles.Align, .center) });
    }
    pub fn justify_center(self: Chain) Chain {
        return self.when(true, .{ .justify_content = @as(styles.Justify, .center) });
    }
    pub fn justify_between(self: Chain) Chain {
        return self.when(true, .{ .justify_content = @as(styles.Justify, .space_between) });
    }
    pub fn grow(self: Chain) Chain {
        return self.when(true, .{ .flex_grow = @as(f32, 1) });
    }
    pub fn shrink_0(self: Chain) Chain {
        return self.when(true, .{ .flex_shrink = @as(f32, 0) });
    }
    pub fn w_full(self: Chain) Chain {
        return self.when(true, .{ .width = styles.Length{ .percent = 100 } });
    }
    pub fn h_full(self: Chain) Chain {
        return self.when(true, .{ .height = styles.Length{ .percent = 100 } });
    }
    pub fn w(self: Chain, value: styles.Length) Chain {
        return self.when(true, .{ .width = value });
    }
    pub fn h(self: Chain, value: styles.Length) Chain {
        return self.when(true, .{ .height = value });
    }
    pub fn w_px(self: Chain, value: f32) Chain {
        return self.when(true, .{ .width = styles.Length.pixels(value) });
    }
    pub fn h_px(self: Chain, value: f32) Chain {
        return self.when(true, .{ .height = styles.Length.pixels(value) });
    }
    pub fn min_w_px(self: Chain, value: f32) Chain {
        return self.when(true, .{ .min_width = styles.Length.pixels(value) });
    }
    pub fn min_h_px(self: Chain, value: f32) Chain {
        return self.when(true, .{ .min_height = styles.Length.pixels(value) });
    }
    pub fn gap_px(self: Chain, value: f32) Chain {
        return self.when(true, .{ .gap = value });
    }
    pub fn p_px(self: Chain, value: f32) Chain {
        return self.when(true, .{ .padding = styles.Insets.all(value) });
    }
    pub fn padding(self: Chain, value: styles.Insets) Chain {
        return self.when(true, .{ .padding = value });
    }
    pub fn p(self: Chain, units: f32) Chain {
        return self.when(true, .{ .padding = styles.Insets.all(units * 4) });
    }
    pub fn p_2(self: Chain) Chain {
        return self.when(true, .{ .padding = styles.Insets.all(8) });
    }
    pub fn p_3(self: Chain) Chain {
        return self.when(true, .{ .padding = styles.Insets.all(12) });
    }
    pub fn p_4(self: Chain) Chain {
        return self.when(true, .{ .padding = styles.Insets.all(16) });
    }
    pub fn gap_2(self: Chain) Chain {
        return self.when(true, .{ .gap = @as(f32, 8) });
    }
    pub fn bg(self: Chain, value: styles.Color) Chain {
        return self.when(true, .{ .background = @as(?styles.Color, value) });
    }
    pub fn hover_bg(self: Chain, value: styles.Color) Chain {
        return self.when(true, .{ .hover_background = @as(?styles.Color, value) });
    }
    pub fn rounded_px(self: Chain, value: f32) Chain {
        return self.when(true, .{ .radius = value });
    }
    pub fn opacity(self: Chain, value: f32) Chain {
        return self.when(true, .{ .opacity = value });
    }
    pub fn scroll_y_px(self: Chain, value: f32) Chain {
        return self.when(true, .{ .scroll_y = value });
    }
    pub fn cursor(self: Chain, value: styles.Cursor) Chain {
        return self.when(true, .{ .cursor = @as(?styles.Cursor, value) });
    }
    pub fn overflow_hidden(self: Chain) Chain {
        const record = self.draft(true) catch |err| return self.fail(err);
        self.factory.ui.frame.nodes.items[record.element.index].style.overflow = .hidden;
        return self;
    }
    pub fn text_size(self: Chain, value: f32) Chain {
        const record = self.draft(true) catch |err| return self.fail(err);
        self.factory.ui.frame.nodes.items[record.element.index].style.text.size = value;
        return self;
    }
    pub fn text_color(self: Chain, value: styles.Color) Chain {
        const record = self.draft(true) catch |err| return self.fail(err);
        self.factory.ui.frame.nodes.items[record.element.index].style.text.color = value;
        return self;
    }
    pub fn px_px(self: Chain, value: f32) Chain {
        const record = self.draft(true) catch |err| return self.fail(err);
        const inset = &self.factory.ui.frame.nodes.items[record.element.index].style.padding;
        inset.left = value;
        inset.right = value;
        return self;
    }
};
fn resolve(value: anytype) !elements.Element {
    if (@TypeOf(value) == Chain) return value.build();
    if (@TypeOf(value) == elements.Element) return value;
    if (@typeInfo(@TypeOf(value)) == .error_union and @typeInfo(@TypeOf(value)).error_union.payload == elements.Element) return try value;
    @compileError("fluent child must be Chain, Element or !Element");
}
