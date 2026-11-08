//! Project tree with independent disclosure/icon/label layout and real source
//! identities. Scroll transforms preserve hit geometry and clipping.
const std = @import("std");
const ui = @import("zircon_ui");
const shell = @import("../shell.zig");
const v = @import("components.zig");
const git_sidebar = @import("git_sidebar.zig");
const Shell = shell.Shell;
pub fn render(self: *const Shell, b: *ui.Ui, width: f32, window_height: f32) !ui.Element {
    const c = self.colors;
    const f = b.fluent();
    const tree_row = self.project_entry_spacing;
    if (self.left_panel != .project) return git_sidebar.render(self, b, width, window_height - v.metrics.titlebar - v.metrics.status);
    const header = try b.fluent().div().h(.{ .px = 32 }).shrink_0().items_center().gap_px(7).padding(.{ .left = 10, .right = 5 }).flex().children(.{ v.icon(b, .folder_open, c.muted, 16), b.fluent().adopt(try v.text(b, std.fs.path.basename(self.workspace.root_path), c.folder, 13)).style(.{ .flex_grow = 1, .text = .{ .size = 13, .color = c.folder }, .overflow = .hidden }), v.iconButton(b, c, .new_file, "New file", .plus, false) }).build();
    const available = @max(0, window_height - v.metrics.titlebar - v.metrics.status - 32);
    const visible = try ui.controls.visibleRows(self.tree.items.len, tree_row, self.tree_scroll.offset, available, 0);
    const active_path = if (self.panel == .image and self.image != null) self.image.?.path else if (self.tabs.items.len > 0) (try self.workspace.getConst(if (self.active_pane == .secondary and self.secondary != null) self.secondary.?.document else self.tabs.items[self.active].document)).path else null;
    var rows: std.ArrayList(ui.Element) = .empty;
    for (self.tree.items[visible.start..visible.end], visible.start..) |entry, index| {
        const selected = if (active_path) |path| std.mem.eql(u8, path, entry.path) else false;
        var children: std.ArrayList(ui.Element) = .empty;
        // Each ancestor contributes a quiet indent guide rather than spaces in
        // a label. The entire composed row remains one click/keyboard target.
        for (0..entry.depth) |_| try children.append(b.allocator(), try b.fluent().div().w(.{ .px = 14 }).h(.{ .px = tree_row }).shrink_0().padding(.{ .left = 6 }).flex().children(&.{try b.fluent().div().w(.{ .px = 1 }).grow().background(c.line).children(.{}).build()}).build());
        try children.append(b.allocator(), if (entry.directory) try v.icon(b, if (entry.expanded) .chevron_down else .chevron_right, c.muted, 12) else try b.fluent().div().w(.{ .px = 12 }).shrink_0().children(.{}).build());
        const contribution = if (self.extension_snapshot) |snapshot| if (snapshot.resolveIconTheme(self.active_icon_theme)) |icons| icons.resolve(entry.path, entry.directory) else null else null;
        if (if (entry.directory) self.project_folder_icons else self.project_file_icons) try children.append(b.allocator(), try v.fileGlyph(self, b, entry.path, entry.directory, entry.expanded, 16));
        try children.append(b.allocator(), try v.text(b, entry.name, if (entry.directory) c.folder else c.text, 13));
        const accessible = if (contribution != null and contribution.? == .symbol) try std.fmt.allocPrint(b.allocator(), "{s} {s}", .{ contribution.?.symbol, entry.name }) else entry.name;
        const row = try f.button(.{ .label = accessible }).id(.named(entry.path))
            .flex().h_px(tree_row).shrink_0().items_center().gap_px(5)
            .padding(.{ .left = 5, .right = 8 }).overflow_hidden()
            .when(selected, .{ .background = c.selected })
            .hover_bg(if (selected) c.selected else c.hover)
            .on_click(b.onClickWith(Shell.onTree, @as(u32, @intCast(index))))
            .on_input(b.onInputWith(Shell.onTreeDrag, @intCast(index)))
            .children(children.items).build();
        try rows.append(b.allocator(), row);
    }
    if (rows.items.len == 0) try rows.append(b.allocator(), try b.fluent().adopt(try v.text(b, "This folder is empty.", c.muted, 12)).style(.{ .padding = ui.Insets.all(12), .text = .{ .size = 12, .color = c.muted } }).build());
    const list = f.div().id(.named("project-files")).grow().min_h_px(0)
        .scroll_y_px(@max(0, -visible.top)).overflow_hidden()
        .on_input(b.onInput(Shell.onTreeInput)).children(rows.items);
    return f.div().id(.named("sidebar")).w_px(width).shrink_0().bg(c.sidebar)
        .overflow_hidden().children(.{ header, list }).build();
}
