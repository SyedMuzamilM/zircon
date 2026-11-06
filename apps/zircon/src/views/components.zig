//! Small visual controls shared by workspace, panels and preferences. Icons are
//! framework geometry; actions keep their readable labels for keyboard/tests.
const std = @import("std");
const ui = @import("zircon_ui");
const Shell = @import("../shell.zig").Shell;
pub const Palette = @import("../theme.zig").Palette;
pub const Icon = ui.controls.icons.Name;
pub const metrics = struct {
    pub const titlebar: f32 = 34;
    pub const tabs: f32 = 32;
    pub const status: f32 = 24;
    pub const file_header: f32 = 32;
    pub const tree_row: f32 = 24;
    pub const divider: f32 = 5;
};
pub fn text(b: *ui.Ui, bytes: []const u8, color: ui.Color, size: f32) !ui.Element {
    return b.styled(try b.text(bytes), .{ .text = .{ .size = size, .color = color }, .overflow = .hidden, .flex_shrink = 0 });
}
pub fn icon(b: *ui.Ui, name: Icon, color: ui.Color, size: f32) !ui.Element {
    return ui.controls.icons.element(b, name, color, size);
}
pub fn iconButton(b: *ui.Ui, c: Palette, action: @import("../commands.zig").Command, label: []const u8, name: Icon, selected: bool) !ui.Element {
    return b.button(.{ .label = label, .children = &.{try icon(b, name, if (selected) c.accent else c.muted, 16)}, .on_click = try b.onClickWith(action, Shell.onCommand), .style = .{ .width = .{ .px = 28 }, .height = .{ .px = 26 }, .flex_shrink = 0, .align_items = .center, .justify_content = .center, .radius = 3, .background = if (selected) c.selected else null, .hover_background = if (selected) c.selected else c.hover } });
}
pub fn rule(b: *ui.Ui, c: Palette) !ui.Element {
    return b.div(.{ .height = .{ .px = 1 }, .flex_shrink = 0, .background = c.line }, &.{});
}
pub fn fileIcon(path: []const u8) Icon {
    const ext = std.fs.path.extension(path);
    if (std.ascii.eqlIgnoreCase(ext, ".zig")) return .zig;
    if (std.ascii.eqlIgnoreCase(ext, ".md")) return .markdown;
    if (@import("image.zig").supported(path)) return .image;
    for ([_][]const u8{ ".rs", ".json", ".js", ".ts", ".tsx", ".c", ".h", ".py", ".toml", ".zon" }) |candidate| if (std.ascii.eqlIgnoreCase(ext, candidate)) return .code;
    return .file;
}
pub fn fileColor(c: Palette, path: []const u8) ui.Color {
    const ext = std.fs.path.extension(path);
    if (std.ascii.eqlIgnoreCase(ext, ".zig") or std.ascii.eqlIgnoreCase(ext, ".zon")) return ui.Color.rgb(0xb8bf8d);
    if (std.ascii.eqlIgnoreCase(ext, ".rs")) return ui.Color.rgb(0xd3a17f);
    if (std.ascii.eqlIgnoreCase(ext, ".json")) return ui.Color.rgb(0xd7ba7d);
    return c.muted;
}
