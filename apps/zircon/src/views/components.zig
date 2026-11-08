//! Small visual controls shared by workspace, panels and preferences. Icons are
//! shared SVG assets; actions keep their readable labels for keyboard/tests.
const std = @import("std");
const git = @import("zircon_git");
const ui = @import("zircon_ui");
const zircon_widgets = @import("zircon_widgets");
const commands_module = @import("../commands.zig");
const shell = @import("../shell.zig");
const theme_module = @import("../theme.zig");
const image_module = @import("image.zig");
const Shell = shell.Shell;
pub const Palette = theme_module.Palette;
pub const Icon = ui.controls.icons.Name;
pub const metrics = zircon_widgets.metrics;
pub const text = zircon_widgets.text;
pub const icon = zircon_widgets.icon;
pub const iconButtonStyle = zircon_widgets.iconButtonStyle;
pub const buttonStyle = zircon_widgets.buttonStyle;
pub const inputAppearance = zircon_widgets.inputAppearance;
pub const rule = zircon_widgets.rule;
pub const popoverBounds = zircon_widgets.popoverBounds;
pub const floatingPanel = zircon_widgets.floatingPanel;
pub fn gitFileColor(c: Palette, entry: git.Entry) ui.Color {
    if (entry.conflicted or entry.worktree == .deleted or entry.index == .deleted) return c.deleted;
    if (entry.index == .added or entry.index == .untracked or entry.worktree == .untracked) return c.added;
    return c.modified;
}
pub fn iconButton(b: *ui.Ui, c: Palette, action: commands_module.Command, label: []const u8, name: Icon, selected: bool) !ui.Element {
    return b.fluent().button(.{ .label = label, .tooltip = label, .tooltip_colors = .{ c.panel, c.text, c.line }, .children = &.{try icon(b, name, if (selected) c.accent else c.muted, 16)}, .on_click = b.onClickWith(Shell.onCommand, action), .style = iconButtonStyle(c, selected) }).build();
}
pub fn actionButton(b: *ui.Ui, c: Palette, action: commands_module.Command, label: []const u8, primary: bool) !ui.Element {
    const glyph: ?Icon = switch (action) {
        .open_path => .folder_open,
        .new_file, .install_bundled_extension => .plus,
        .find, .run_project_search, .project_search => .search,
        .find_next => .arrow_down,
        .find_previous => .arrow_up,
        .settings => .settings,
        .palette => .commands,
        .extensions, .install_extension => .extension,
        .split => .split,
        .dismiss => .close,
        .back_to_editor => .chevron_left,
        else => null,
    };
    var children: std.ArrayList(ui.Element) = .empty;
    const color = if (primary) c.on_primary else c.text;
    if (glyph) |name| try children.append(b.allocator(), try icon(b, name, color, 14));
    try children.append(b.allocator(), try text(b, label, color, 12));
    return b.fluent().button(.{ .label = label, .children = children.items, .on_click = b.onClickWith(Shell.onCommand, action), .style = buttonStyle(c, primary) }).build();
}
pub fn fileIcon(path: []const u8) Icon {
    const ext = std.fs.path.extension(path);
    if (std.ascii.eqlIgnoreCase(ext, ".zig")) return .zig;
    if (std.ascii.eqlIgnoreCase(ext, ".md")) return .markdown;
    if (image_module.supported(path)) return .image;
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

pub fn menuRow(b: *ui.Ui, c: Palette, action: commands_module.Command, label: []const u8, shortcut: []const u8, selected: bool) !ui.Element {
    const f = b.fluent();
    return f.button(.{ .label = label }).id(.{ .number = @backingInt(action) })
        .flex().h_px(30).shrink_0().items_center().gap_px(20).px_px(10)
        .rounded_px(metrics.control_radius).hover_bg(c.hover).overflow_hidden()
        .when(selected, .{ .background = c.selected })
        .on_click(b.onClickWith(Shell.onCommand, action))
        .child(f.text(label).grow().min_w_px(0).overflow_hidden().text_size(13).text_color(c.text))
        .child(f.text(shortcut).text_size(12).text_color(c.muted).shrink_0().overflow_hidden())
        .build();
}

/// Align to the invoking control, flip above it when needed, and stay inside
/// the window even when a split pane or sidebar is narrower than the menu.
/// Resolve semantic file icons everywhere through the active installed theme.
pub fn fileGlyph(self: *const Shell, b: *ui.Ui, path: []const u8, directory: bool, expanded: bool, size: f32) !ui.Element {
    if (self.extension_snapshot) |snapshot| if (snapshot.resolveIconTheme(self.active_icon_theme)) |theme| switch (theme.resolve(path, directory)) {
        .symbol => |symbol| return text(b, symbol, if (directory) self.colors.folder else fileColor(self.colors, path), size),
        .png => |asset| if (self.icons.find(asset.path)) |image| return image_module.element(b, image, .{ .width = .{ .px = size }, .height = .{ .px = size }, .flex_shrink = 0 }),
    };
    return icon(b, if (directory) (if (expanded) .folder_open else .folder) else fileIcon(path), if (directory) self.colors.muted else fileColor(self.colors, path), size);
}
