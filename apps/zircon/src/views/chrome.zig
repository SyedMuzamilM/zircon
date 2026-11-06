//! Workspace chrome follows the reference's hierarchy: project/branch at the
//! top, file tabs and tools around the canvas, panel selectors in the status bar.
const std = @import("std");
const ui = @import("zircon_ui");
const Shell = @import("../shell.zig").Shell;
const v = @import("components.zig");
pub fn titlebar(self: *const Shell, b: *ui.Ui) !ui.Element {
    const c = self.colors;
    var items: std.ArrayList(ui.Element) = .empty;
    try items.append(b.allocator(), try b.div(.{ .width = .{ .px = 70 }, .flex_shrink = 0 }, &.{}));
    try items.append(b.allocator(), try b.button(.{ .label = "Open", .children = &.{ try v.text(b, std.fs.path.basename(self.workspace.root_path), c.text, 13), try v.icon(b, .chevron_down, c.muted, 12) }, .on_click = try b.onClickWith(@import("../commands.zig").Command.open_path, Shell.onCommand), .style = .{ .direction = .row, .height = .{ .px = 28 }, .gap = 6, .align_items = .center, .padding = .{ .left = 5, .right = 5 }, .radius = 3, .hover_background = c.hover, .flex_shrink = 1, .min_width = .{ .px = 0 }, .max_width = .{ .viewport_width = 40 }, .overflow = .hidden } }));
    if (self.git.status) |status| if (status.branch.len > 0) try items.append(b.allocator(), try b.button(.{ .label = "Git changes", .children = &.{ try v.icon(b, .branch, c.muted, 14), try v.text(b, status.branch, c.muted, 12) }, .on_click = try b.onClickWith(@import("../commands.zig").Command.git_changes, Shell.onCommand), .style = .{ .direction = .row, .height = .{ .px = 28 }, .gap = 5, .align_items = .center, .padding = .{ .left = 5, .right = 5 }, .radius = 3, .hover_background = c.hover, .flex_shrink = 1, .overflow = .hidden } }));
    try items.append(b.allocator(), try b.div(.{ .flex_grow = 1 }, &.{}));
    try items.appendSlice(b.allocator(), &.{ try v.iconButton(b, c, .quick_open, "Go to file", .search, false), try v.iconButton(b, c, .workspace_menu, "Workspace menu", .more, self.menu_open) });
    const row = try b.dragRegion(try b.key(.{ .string = "toolbar" }, try b.row(.{ .height = .{ .px = v.metrics.titlebar - 1 }, .flex_shrink = 0, .align_items = .center, .gap = 6, .padding = .{ .left = 8, .right = 8 }, .background = c.chrome }, items.items)));
    return b.column(.{ .height = .{ .px = v.metrics.titlebar }, .flex_shrink = 0 }, &.{ row, try v.rule(b, c) });
}
pub fn tabs(self: *const Shell, b: *ui.Ui, width: f32) !ui.Element {
    const c = self.colors;
    var items: std.ArrayList(ui.Element) = .empty;
    try items.append(b.allocator(), try navigation(self, b, if (self.active > 0) self.active - 1 else null, "previous-tab", .chevron_left));
    try items.append(b.allocator(), try navigation(self, b, if (self.active + 1 < self.tabs.items.len) self.active + 1 else null, "next-tab", .chevron_right));
    const utility = self.panel != .editor and self.panel != .markdown;
    const source_room = @max(0, width - 104 - if (utility) @as(f32, 210) else 0);
    const capacity = if (utility and width < 520) @as(usize, 0) else @max(@as(usize, 1), @as(usize, @intFromFloat(@floor(source_room / 174))));
    const first = if (capacity == 0) @min(self.active, self.tabs.items.len) else if (self.active >= capacity) self.active - capacity + 1 else 0;
    const end = @min(self.tabs.items.len, first + capacity);
    for (self.tabs.items[first..end], first..) |tab, index| {
        const record = try self.workspace.getConst(tab.document);
        const selected = index == self.active and (self.panel == .editor or self.panel == .markdown);
        const background = if (selected) c.document else c.tab_bar;
        const accessible = try std.fmt.allocPrint(b.allocator(), "{s}{s}", .{ record.title(), if (record.dirty()) " •" else "" });
        const title = try b.listen(try b.button(.{ .label = accessible, .children = &.{ try v.icon(b, v.fileIcon(record.path orelse ""), v.fileColor(c, record.path orelse ""), 14), try v.text(b, record.title(), if (selected) c.text else c.muted, 13) }, .on_click = try b.onClickWith(@as(u32, @intCast(index)), Shell.onTab), .style = .{ .direction = .row, .flex_grow = 1, .min_width = .{ .px = 0 }, .gap = 7, .align_items = .center, .padding = .{ .left = 11, .right = 6 }, .hover_background = if (selected) c.document else c.hover, .overflow = .hidden } }), .{ .on_input = try b.onInputWith(tab.document, Shell.onTabDrag) });
        const close = try b.key(.{ .string = "close" }, try b.button(.{ .label = "Close tab", .children = &.{if (record.dirty()) try b.div(.{ .width = .{ .px = 5 }, .height = .{ .px = 5 }, .radius = 3, .background = c.muted }, &.{}) else try v.icon(b, .close, c.muted, 12)}, .on_click = try b.onClickWith(@as(u32, @intCast(index)), Shell.onCloseTab), .style = .{ .width = .{ .px = 24 }, .flex_shrink = 0, .align_items = .center, .justify_content = .center, .hover_background = c.hover } }));
        const measured = @min(@as(f32, 174), @max(@as(f32, 110), @as(f32, @floatFromInt(record.title().len)) * 7.2 + 57));
        try items.append(b.allocator(), try b.key(.{ .number = @import("../panes.zig").key(tab.document) }, try b.column(.{ .width = .{ .px = measured }, .min_width = .{ .px = 90 }, .flex_shrink = 1, .background = background }, &.{ try b.row(.{ .flex_grow = 1 }, &.{ try b.div(.{ .width = .{ .px = 1 }, .flex_shrink = 0, .background = c.line }, &.{}), title, close, try b.div(.{ .width = .{ .px = 1 }, .flex_shrink = 0, .background = c.line }, &.{}) }), try b.div(.{ .height = .{ .px = 1 }, .background = if (selected) c.document else c.line, .flex_shrink = 0 }, &.{}) })));
    }
    if (self.panel != .editor and self.panel != .markdown) {
        const name: []const u8 = switch (self.panel) {
            .git_diff => if (self.git.selected_commit.len > 0) "Commit changes" else "Uncommitted changes",
            .extensions => "Extensions",
            .search => "Project search",
            .image => if (self.image) |asset| std.fs.path.basename(asset.path) else "Image",
            else => unreachable,
        };
        const glyph: v.Icon = switch (self.panel) {
            .git_diff => .branch,
            .extensions => .extension,
            .search => .search,
            .image => .image,
            else => unreachable,
        };
        try items.append(b.allocator(), try b.key(.{ .string = "active-tool-tab" }, try b.row(.{ .height = .{ .px = v.metrics.tabs }, .min_width = .{ .px = 130 }, .max_width = .{ .px = 210 }, .flex_grow = 0, .gap = 7, .align_items = .center, .padding = .{ .left = 12, .right = 4 }, .background = c.document, .overflow = .hidden, .flex_shrink = 0 }, &.{ try v.icon(b, glyph, c.muted, 14), try b.styled(try v.text(b, name, c.text, 13), .{ .flex_shrink = 1, .min_width = .{ .px = 0 }, .text = .{ .size = 13, .color = c.text }, .overflow = .hidden }), try v.iconButton(b, c, .back_to_editor, "Close view", .close, false) })));
    }
    try items.append(b.allocator(), try b.column(.{ .flex_grow = 1 }, &.{ try b.div(.{ .flex_grow = 1 }, &.{}), try v.rule(b, c) }));
    try items.appendSlice(b.allocator(), &.{ try v.iconButton(b, c, .new_file, "New file", .plus, false), try v.iconButton(b, c, .split, if (self.secondary == null) "Split editor" else "Close split", .split, self.secondary != null) });
    return b.key(.{ .string = "tabs" }, try b.row(.{ .height = .{ .px = v.metrics.tabs }, .flex_shrink = 0, .background = c.tab_bar, .overflow = .hidden, .padding = .{ .right = 4 } }, items.items));
}
fn navigation(self: *const Shell, b: *ui.Ui, index: ?usize, key: []const u8, name: v.Icon) !ui.Element {
    const c = self.colors;
    var color = c.muted;
    if (index == null) color.a = 0.4;
    return b.key(.{ .string = key }, try b.button(.{ .label = key, .children = &.{try v.icon(b, name, color, 14)}, .on_click = if (index) |target| try b.onClickWith(@as(u32, @intCast(target)), Shell.onTab) else null, .style = .{ .width = .{ .px = 26 }, .flex_shrink = 0, .align_items = .center, .justify_content = .center, .hover_background = if (index != null) c.hover else null } }));
}
pub fn fileHeader(self: *const Shell, b: *ui.Ui, record: *const @import("zircon_workspace").Record) !ui.Element {
    const c = self.colors;
    var path = record.path orelse record.title();
    if (std.mem.startsWith(u8, path, self.workspace.root_path) and path.len > self.workspace.root_path.len) path = std.mem.trimStart(u8, path[self.workspace.root_path.len..], "/");
    const name = try v.text(b, path, c.muted, 12);
    var children: std.ArrayList(ui.Element) = .empty;
    try children.append(b.allocator(), try b.styled(name, .{ .flex_grow = 1, .min_width = .{ .px = 0 }, .text = .{ .size = 12, .mono = true, .color = c.muted }, .overflow = .hidden }));
    try children.append(b.allocator(), try v.iconButton(b, c, .find, "Find", .search, false));
    if (@import("zircon_editor").syntax.languageForPath(record.path orelse "") == .markdown) try children.append(b.allocator(), try v.iconButton(b, c, .markdown_preview, "Preview", .markdown, self.panel == .markdown));
    try children.append(b.allocator(), try v.iconButton(b, c, .split, "Split editor", .split, self.secondary != null));
    return b.key(.{ .string = "file-toolbar" }, try b.row(.{ .height = .{ .px = v.metrics.file_header }, .flex_shrink = 0, .padding = .{ .left = 13, .right = 7 }, .align_items = .center, .gap = 4, .background = c.document, .overflow = .hidden }, children.items));
}
pub fn statusbar(self: *const Shell, b: *ui.Ui) !ui.Element {
    const c = self.colors;
    var items: std.ArrayList(ui.Element) = .empty;
    try items.appendSlice(b.allocator(), &.{ try v.iconButton(b, c, .toggle_sidebar, "Toggle sidebar", .sidebar, self.sidebar_visible), try v.iconButton(b, c, .project_files, "Project files", .folder, self.sidebar_visible and self.left_panel == .project), try v.iconButton(b, c, .git_changes, "Git changes", .branch, self.sidebar_visible and self.left_panel == .git_changes), try v.iconButton(b, c, .git_history, "Git history", .history, self.sidebar_visible and self.left_panel == .git_history), try v.iconButton(b, c, .project_search, "Project search", .search, self.panel == .search) });
    if (self.status.len > 0) try items.append(b.allocator(), try b.styled(try v.text(b, self.status, if (self.status_is_error) c.warning else c.muted, 11), .{ .flex_shrink = 1, .min_width = .{ .px = 0 }, .max_width = .{ .percent = 35 }, .text = .{ .size = 11, .color = if (self.status_is_error) c.warning else c.muted }, .overflow = .hidden }));
    if (self.tab_drag) |drag| if (drag.moved) try items.append(b.allocator(), try v.text(b, "Drop on tabs or the right editor edge · Esc cancels", c.muted, 11));
    try items.append(b.allocator(), try b.div(.{ .flex_grow = 1 }, &.{}));
    if (self.tabs.items.len > 0 and b.viewport().width >= 650) {
        const id = if (self.active_pane == .secondary and self.secondary != null) self.secondary.?.document else self.tabs.items[self.active].document;
        const state = if (self.active_pane == .secondary and self.secondary != null) &self.secondary.?.editor else &self.tabs.items[self.active].editor;
        var snapshot = try self.workspace.snapshot(id);
        defer snapshot.deinit();
        const point = try snapshot.pointAt(@min(state.primary().head, snapshot.byteLen()));
        const location = try std.fmt.allocPrint(b.allocator(), "{d}:{d}", .{ point.line + 1, point.byte_column + 1 });
        try items.append(b.allocator(), try v.text(b, location, c.muted, 11));
        try items.append(b.allocator(), try v.text(b, try std.fmt.allocPrint(b.allocator(), "Spaces: {d}", .{state.tab_width}), c.muted, 11));
        const language = switch (state.language) {
            .plain => "Plain text",
            .zig => "Zig",
            .rust => "Rust",
            .json => "JSON",
            .markdown => "Markdown",
            .custom => "Extension",
        };
        try items.append(b.allocator(), try v.text(b, language, c.muted, 11));
    }
    try items.appendSlice(b.allocator(), &.{ try v.iconButton(b, c, .extensions, "Extensions", .extension, self.panel == .extensions), try v.iconButton(b, c, .settings, "Settings", .settings, false) });
    return b.key(.{ .string = "status" }, try b.column(.{ .height = .{ .px = v.metrics.status }, .flex_shrink = 0, .background = c.chrome }, &.{ try v.rule(b, c), try b.row(.{ .flex_grow = 1, .align_items = .center, .gap = 4, .padding = .{ .left = 5, .right = 5 }, .overflow = .hidden }, items.items) }));
}
pub fn menu(self: *const Shell, b: *ui.Ui) !ui.Element {
    const c = self.colors;
    var items: std.ArrayList(ui.Element) = .empty;
    inline for (.{ .{ @import("../commands.zig").Command.open_path, "Open file…", "⌘O" }, .{ @import("../commands.zig").Command.palette, "Command palette", "⇧⌘P" }, .{ @import("../commands.zig").Command.extensions, "Extensions", "" }, .{ @import("../commands.zig").Command.settings, "Settings", "⌘," } }) |entry| {
        try items.append(b.allocator(), try b.button(.{ .label = entry[1], .children = &.{ try b.styled(try v.text(b, entry[1], c.text, 13), .{ .flex_grow = 1, .text = .{ .size = 13, .color = c.text } }), try v.text(b, entry[2], c.muted, 12) }, .on_click = try b.onClickWith(entry[0], Shell.onCommand), .style = .{ .direction = .row, .height = .{ .px = 32 }, .flex_shrink = 0, .align_items = .center, .padding = .{ .left = 10, .right = 10 }, .radius = 3, .hover_background = c.hover } }));
    }
    const popup = try b.column(.{ .width = .{ .px = 260 }, .height = .{ .px = 138 }, .padding = ui.Insets.all(5), .background = c.panel, .radius = 5, .overflow = .hidden }, items.items);
    return b.modal(try b.listen(try b.stack(.{ .align_items = .end, .padding = .{ .top = v.metrics.titlebar + 3, .right = 7 } }, &.{popup}), .{ .on_input = b.onInput(Shell.onMenuInput) }));
}
