//! Project tree with independent disclosure/icon/label layout and real source
//! identities. Scroll transforms preserve hit geometry and clipping.
const std = @import("std");
const ui = @import("zircon_ui");
const Shell = @import("../shell.zig").Shell;
const v = @import("components.zig");
pub fn render(self: *const Shell, b: *ui.Ui, width: f32, window_height: f32) !ui.Element {
    const c = self.colors;
    if (self.left_panel != .project) return @import("git_sidebar.zig").render(self, b, width, window_height - v.metrics.titlebar - v.metrics.status);
    const header = try b.row(.{ .height = .{ .px = 32 }, .flex_shrink = 0, .align_items = .center, .gap = 7, .padding = .{ .left = 10, .right = 5 } }, &.{ try v.icon(b, .folder_open, c.muted, 16), try b.styled(try v.text(b, std.fs.path.basename(self.workspace.root_path), c.folder, 13), .{ .flex_grow = 1, .text = .{ .size = 13, .color = c.folder }, .overflow = .hidden }), try v.iconButton(b, c, .new_file, "New file", .plus, false) });
    const available = @max(0, window_height - v.metrics.titlebar - v.metrics.status - 32);
    const visible = try ui.controls.visibleRows(self.tree.items.len, v.metrics.tree_row, self.tree_scroll.offset, available, 0);
    const active_path = if (self.panel == .image and self.image != null) self.image.?.path else if (self.tabs.items.len > 0) (try self.workspace.getConst(if (self.active_pane == .secondary and self.secondary != null) self.secondary.?.document else self.tabs.items[self.active].document)).path else null;
    var rows: std.ArrayList(ui.Element) = .empty;
    for (self.tree.items[visible.start..visible.end], visible.start..) |entry, index| {
        const selected = if (active_path) |path| std.mem.eql(u8, path, entry.path) else false;
        const tint = if (entry.directory) c.folder else v.fileColor(c, entry.path);
        var children: std.ArrayList(ui.Element) = .empty;
        // Each ancestor contributes a quiet indent guide rather than spaces in
        // a label. The entire composed row remains one click/keyboard target.
        for (0..entry.depth) |_| try children.append(b.allocator(), try b.row(.{ .width = .{ .px = 14 }, .height = .{ .px = v.metrics.tree_row }, .flex_shrink = 0, .padding = .{ .left = 6 } }, &.{try b.div(.{ .width = .{ .px = 1 }, .flex_grow = 1, .background = c.line }, &.{})}));
        try children.append(b.allocator(), if (entry.directory) try v.icon(b, if (entry.expanded) .chevron_down else .chevron_right, c.muted, 12) else try b.div(.{ .width = .{ .px = 12 }, .flex_shrink = 0 }, &.{}));
        const contribution = if (self.extension_snapshot) |snapshot| if (snapshot.resolveIconTheme(self.active_icon_theme)) |icons| icons.resolve(entry.path, entry.directory) else null else null;
        var painted_icon = false;
        if (contribution) |value| switch (value) {
            .symbol => |symbol| {
                try children.append(b.allocator(), try v.text(b, symbol, tint, 12));
                painted_icon = true;
            },
            .png => |asset| if (self.icons.find(asset.path)) |image| {
                try children.append(b.allocator(), try @import("image.zig").element(b, image, .{ .width = .{ .px = 16 }, .height = .{ .px = 16 }, .flex_shrink = 0 }));
                painted_icon = true;
            },
        };
        if (!painted_icon) try children.append(b.allocator(), try v.icon(b, if (entry.directory) (if (entry.expanded) .folder_open else .folder) else v.fileIcon(entry.path), if (entry.directory) c.muted else tint, 16));
        try children.append(b.allocator(), try v.text(b, entry.name, if (entry.directory) c.folder else c.text, 13));
        const accessible = if (contribution != null and contribution.? == .symbol) try std.fmt.allocPrint(b.allocator(), "{s} {s}", .{ contribution.?.symbol, entry.name }) else entry.name;
        const row = try b.button(.{ .label = accessible, .children = children.items, .on_click = try b.onClickWith(@as(u32, @intCast(index)), Shell.onTree), .style = .{ .direction = .row, .height = .{ .px = v.metrics.tree_row }, .flex_shrink = 0, .align_items = .center, .gap = 5, .padding = .{ .left = 5, .right = 8 }, .background = if (selected) c.selected else null, .hover_background = if (selected) c.selected else c.hover, .overflow = .hidden } });
        try rows.append(b.allocator(), try b.listen(try b.key(.{ .string = entry.path }, row), .{ .on_input = try b.onInputWith(@as(u32, @intCast(index)), Shell.onTreeDrag) }));
    }
    if (rows.items.len == 0) try rows.append(b.allocator(), try b.styled(try v.text(b, "This folder is empty.", c.muted, 12), .{ .padding = ui.Insets.all(12), .text = .{ .size = 12, .color = c.muted } }));
    const list = try b.listen(try b.key(.{ .string = "project-files" }, try b.column(.{ .flex_grow = 1, .min_height = .{ .px = 0 }, .scroll_y = @max(0, -visible.top), .overflow = .hidden }, rows.items)), .{ .on_input = b.onInput(Shell.onTreeInput) });
    return b.key(.{ .string = "sidebar" }, try b.column(.{ .width = .{ .px = width }, .flex_shrink = 0, .background = c.sidebar, .overflow = .hidden }, &.{ header, list }));
}
