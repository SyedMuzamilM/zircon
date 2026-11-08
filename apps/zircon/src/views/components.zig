//! Small visual controls shared by workspace, panels and preferences. Icons are
//! shared SVG assets; actions keep their readable labels for keyboard/tests.
const std = @import("std");
const git = @import("zircon_git");
const ui = @import("zircon_ui");
const commands_module = @import("../commands.zig");
const shell = @import("../shell.zig");
const theme_module = @import("../theme.zig");
const image_module = @import("image.zig");
const Shell = shell.Shell;
pub const Palette = theme_module.Palette;
pub const Icon = ui.controls.icons.Name;
pub const metrics = struct {
    pub const control_radius = ui.controls.metrics.control_radius;
    pub const popover_radius = ui.controls.metrics.popover_radius;
    pub const titlebar: f32 = 34;
    pub const tabs: f32 = 32;
    pub const status: f32 = 24;
    pub const file_header: f32 = 32;
    pub const tree_row: f32 = 24;
    pub const divider: f32 = 5;
    pub const control: f32 = 28;
    pub const icon_control: f32 = 22;
    pub const small_gap: f32 = 4;
    pub const inset: f32 = 12;
};
pub fn text(b: *ui.Ui, bytes: []const u8, color: ui.Color, size: f32) !ui.Element {
    return b.fluent().text(bytes).style(.{ .text = .{ .size = size, .color = color }, .overflow = .hidden, .flex_shrink = 0 }).build();
}
pub fn icon(b: *ui.Ui, name: Icon, color: ui.Color, size: f32) !ui.Element {
    return ui.controls.icons.element(b, name, color, size);
}
pub fn iconButton(b: *ui.Ui, c: Palette, action: commands_module.Command, label: []const u8, name: Icon, selected: bool) !ui.Element {
    return b.fluent().button(.{ .label = label, .tooltip = label, .tooltip_colors = .{ c.panel, c.text, c.line }, .children = &.{try icon(b, name, if (selected) c.accent else c.muted, 16)}, .on_click = b.onClickWith(Shell.onCommand, action), .style = iconButtonStyle(c, selected) }).build();
}
pub fn iconButtonStyle(c: Palette, selected: bool) ui.Style {
    return .{ .width = .{ .px = 24 }, .height = .{ .px = metrics.icon_control }, .flex_shrink = 0, .align_items = .center, .justify_content = .center, .radius = metrics.control_radius, .background = if (selected) c.selected else null, .hover_background = c.hover };
}
pub fn buttonStyle(c: Palette, primary: bool) ui.Style {
    return .{ .direction = .row, .height = .{ .px = metrics.control }, .gap = 6, .align_items = .center, .justify_content = .center, .padding = .{ .left = 8, .right = 8 }, .radius = metrics.control_radius, .background = if (primary) c.primary else c.element, .hover_background = if (primary) c.primary_hover else c.hover, .text = .{ .size = 12, .color = if (primary) c.on_primary else c.text }, .flex_shrink = 0 };
}
pub fn inputAppearance(c: Palette) ui.controls.TextInput.Appearance {
    return .{ .background = c.document, .border = c.line, .foreground = c.text, .placeholder = c.muted, .selection = c.selection, .caret = c.accent, .focus_border = c.accent };
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
pub fn rule(b: *ui.Ui, c: Palette) !ui.Element {
    return b.fluent().div().h(.{ .px = 1 }).shrink_0().background(c.line).children(.{}).build();
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
pub fn popoverBounds(viewport: ui.Size, anchor: ui.Rect, requested: ui.Size) ui.Rect {
    const inset: f32 = 6;
    const width = @min(requested.width, @max(0, viewport.width - inset * 2));
    const height = @min(requested.height, @max(0, viewport.height - inset * 2));
    const below = anchor.y + anchor.height + 4;
    const preferred_y = if (below + height <= viewport.height - inset) below else anchor.y - height - 4;
    return .{ .x = std.math.clamp(anchor.x + anchor.width - width, inset, @max(inset, viewport.width - width - inset)), .y = std.math.clamp(preferred_y, inset, @max(inset, viewport.height - height - inset)), .width = width, .height = height };
}

pub fn floatingPanel(b: *ui.Ui, c: Palette, size: ui.Size, padding: ui.Insets, gap: f32, children: []const ui.Element) !ui.Element {
    return b.fluent().div().w(.{ .px = size.width }).h(.{ .px = size.height }).shrink_0().stack().children(.{ b.custom(PanelSurface, .{ .colors = c }, .{ .flex_grow = 1 }), b.fluent().div().padding(padding).gap_px(gap).overflow_hidden().flex_col().children(children) }).build();
}
const PanelSurface = struct {
    colors: Palette,
    pub const LayoutState = void;
    pub const PrepaintState = void;
    pub fn requestLayout(_: *PanelSurface, cx: *ui.LayoutCx) !ui.LayoutResult(void) {
        return .{ .size = cx.available, .state = {} };
    }
    pub fn prepaint(_: *PanelSurface, _: *ui.PrepaintCx, _: ui.Rect, _: *void) !void {}
    pub fn paint(self: *PanelSurface, cx: *ui.PaintCx, bounds: ui.Rect, _: *void, _: *void) !void {
        for ([_]f32{ 10, 6, 3 }) |spread| try cx.painter.fillRect(.{ .bounds = .{ .x = bounds.x - spread, .y = bounds.y - spread / 2 + 2, .width = bounds.width + spread * 2, .height = bounds.height + spread }, .radius = metrics.popover_radius + spread, .color = .{ .r = 0, .g = 0, .b = 0, .a = 0.035 } });
        try cx.painter.fillRect(.{ .bounds = bounds, .radius = metrics.popover_radius, .color = self.colors.line });
        try cx.painter.fillRect(.{ .bounds = .{ .x = bounds.x + 1, .y = bounds.y + 1, .width = @max(0, bounds.width - 2), .height = @max(0, bounds.height - 2) }, .radius = metrics.popover_radius - 1, .color = self.colors.panel });
    }
};

/// Resolve semantic file icons everywhere through the active installed theme.
pub fn fileGlyph(self: *const Shell, b: *ui.Ui, path: []const u8, directory: bool, expanded: bool, size: f32) !ui.Element {
    if (self.extension_snapshot) |snapshot| if (snapshot.resolveIconTheme(self.active_icon_theme)) |theme| switch (theme.resolve(path, directory)) {
        .symbol => |symbol| return text(b, symbol, if (directory) self.colors.folder else fileColor(self.colors, path), size),
        .png => |asset| if (self.icons.find(asset.path)) |image| return image_module.element(b, image, .{ .width = .{ .px = size }, .height = .{ .px = size }, .flex_shrink = 0 }),
    };
    return icon(b, if (directory) (if (expanded) .folder_open else .folder) else fileIcon(path), if (directory) self.colors.muted else fileColor(self.colors, path), size);
}
pub fn gitFileColor(c: Palette, entry: git.Entry) ui.Color {
    if (entry.conflicted or entry.worktree == .deleted or entry.index == .deleted) return c.deleted;
    if (entry.index == .added or entry.index == .untracked or entry.worktree == .untracked) return c.added;
    return c.modified;
}
