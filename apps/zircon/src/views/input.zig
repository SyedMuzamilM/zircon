//! Text input lifecycle only. Feature modules own text, configuration and layout.

const std = @import("std");
const ui = @import("zircon_ui");
pub const Handle = ui.Entity(ui.controls.TextInput);

pub const Options = struct {
    placeholder: []const u8 = "",
    icon: ?ui.controls.icons.Name = null,
    height: f32 = 30,
    font_size: f32 = 13,
    borderless: bool = false,
    transparent_background: bool = false,
};

pub fn create(cx: anytype, a: std.mem.Allocator, options: Options) !Handle {
    var value = try ui.controls.TextInput.init(a, "");
    errdefer value.deinit(a);
    apply(&value, options);
    return cx.createChild(ui.controls.TextInput, value);
}

fn apply(value: *ui.controls.TextInput, options: Options) void {
    value.placeholder = options.placeholder;
    value.leading_icon = options.icon;
    value.height = options.height;
    value.font_size = options.font_size;
    value.show_focus_border = !options.borderless;
    if (options.borderless) value.appearance.border = .transparent;
    if (options.transparent_background) value.appearance.background = .transparent;
}

pub fn reset(cx: anytype, handle: Handle, bytes: []const u8, options: Options) !void {
    const Update = struct {
        fn call(value: *ui.controls.TextInput, context: *ui.Context(ui.controls.TextInput), content: []const u8, settings: Options) !void {
            try value.bytes.ensureTotalCapacity(value.allocator, content.len);
            value.bytes.clearRetainingCapacity();
            value.bytes.appendSliceAssumeCapacity(content);
            value.cursor = content.len;
            value.anchor = content.len;
            value.marked = null;
            value.dragging = false;
            value.revision +%= 1;
            apply(value, settings);
            context.notify();
        }
    };
    try cx.update(handle, Update.call, .{ bytes, options });
}

pub fn read(cx: anytype, handle: Handle, a: std.mem.Allocator) ![]u8 {
    var bytes: []u8 = undefined;
    try cx.read(handle, ui.controls.TextInput.copy, .{ a, &bytes });
    return bytes;
}

pub fn text(b: *ui.Ui, handle: Handle) ![]u8 {
    var bytes: []u8 = undefined;
    try b.watch(handle, ui.controls.TextInput.copy, .{ b.allocator(), &bytes });
    return bytes;
}

pub fn appearance(cx: anytype, handle: Handle, colors: ui.controls.TextInput.Appearance, borderless: bool) !void {
    const Update = struct {
        fn call(value: *ui.controls.TextInput, context: *ui.Context(ui.controls.TextInput), palette: ui.controls.TextInput.Appearance, no_border: bool) void {
            var actual = palette;
            // Transparency belongs to the control's layout, independently of theme colors.
            if (no_border or value.appearance.border.a == 0) actual.border = .transparent;
            if (value.appearance.background.a == 0) actual.background = .transparent;
            value.setAppearance(context, actual);
        }
    };
    try cx.update(handle, Update.call, .{ colors, borderless });
}
