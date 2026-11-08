//! Explicit project-opening modes. Native browsing and typed paths reach the
//! same validation/opening functions; existing workspace buffers stay open.
const std = @import("std");
const ui = @import("zircon_ui");
const commands = @import("../commands.zig");
const projects = @import("../projects.zig");
const shell = @import("../shell.zig");
const v = @import("components.zig");
const Shell = shell.Shell;
const Kind = projects.Kind;
pub fn render(self: *const Shell, b: *ui.Ui) !ui.Element {
    const c = self.colors;
    var rows: std.ArrayList(ui.Element) = .empty;
    try rows.append(b.allocator(), try v.text(b, "Open a project", c.text, 18));
    inline for (.{ .{ Kind.local_folder, "Local folder", v.Icon.folder_open, "Open a folder from this Mac." }, .{ Kind.git_repository, "Git repository", v.Icon.branch, "Open an existing checkout and detect its repository root." }, .{ Kind.clone, "Clone repository", v.Icon.arrow_down, "Clone an HTTPS/SSH repository into a new local directory." } }) |entry| {
        try rows.append(b.allocator(), try b.fluent().button(.{ .label = entry[1], .children = &.{ try v.icon(b, entry[2], if (self.open_kind == entry[0]) c.accent else c.muted, 20), try b.fluent().div().gap_px(5).grow().min_w(.{ .px = 0 }).overflow_hidden().flex_col().children(.{ v.text(b, entry[1], c.text, 14), v.text(b, entry[3], c.muted, 12) }).build() }, .on_click = b.onClickWith(Shell.onOpenKind, entry[0]), .style = .{ .direction = .row, .height = .{ .px = 64 }, .flex_shrink = 0, .align_items = .center, .gap = 12, .padding = ui.Insets.all(10), .radius = ui.controls.metrics.control_radius, .background = if (self.open_kind == entry[0]) c.selected else c.document, .hover_background = c.hover } }).build());
    }
    if (self.fields) |fields| {
        try rows.append(b.allocator(), try v.text(b, if (self.open_kind == .clone) "Repository URL or absolute local repository path" else "Folder path", c.muted, 12));
        const input = try b.fluent().view(fields.path).id(.{ .string = "project-path" }).style(.{ .height = .{ .px = 34 }, .flex_grow = 1, .min_width = .{ .px = 0 } }).build();
        try rows.append(b.allocator(), try b.fluent().div().h(.{ .px = 34 }).shrink_0().gap_px(8).items_center().flex().children(if (self.open_kind == .clone) &.{try b.fluent().adopt(input).autofocus().build()} else &.{ try b.fluent().adopt(input).autofocus().build(), try v.actionButton(b, c, .browse_project, "Browse…", false) }).build());
        if (self.open_kind == .clone) {
            try rows.append(b.allocator(), try v.text(b, "Destination directory", c.muted, 12));
            try rows.append(b.allocator(), try b.fluent().view(fields.destination).id(.{ .string = "clone-destination" }).style(.{ .height = .{ .px = 34 }, .flex_shrink = 0 }).build());
        }
    }
    try rows.append(b.allocator(), try v.text(b, "Projects open in a new window. Current buffers stay open.", c.muted, 12));
    if (self.status_is_error and self.status.len > 0) try rows.append(b.allocator(), try v.text(b, self.status, c.warning, 12));
    try rows.append(b.allocator(), try b.fluent().div().h(.{ .px = 28 }).shrink_0().gap_px(8).justify(.end).flex().children(.{ v.actionButton(b, c, .dismiss, "Cancel", false), b.fluent().button(.{ .label = if (self.cloning) "Cloning…" else if (self.open_kind == .clone) "Clone and open" else "Open project", .on_click = if (self.cloning) null else try b.onClickWith(Shell.onCommand, commands.Command.submit_project), .style = v.buttonStyle(c, true) }) }).build());
    const height: f32 = if (self.open_kind == .clone) 500 else 432;
    const panel = try b.fluent().div().w(.{ .px = @min(600, b.viewport().width - 32) }).h(.{ .px = @min(height, b.viewport().height - 32) }).padding(ui.Insets.all(20)).gap_px(12).background(c.panel).rounded_px(ui.controls.metrics.popover_radius).overflow_hidden().flex_col().children(rows.items).id(.{ .string = "dialog" }).build();
    return b.fluent().div().items_center().justify_center().background(.{ .r = 0, .g = 0, .b = 0, .a = 0.35 }).stack().children(.{panel}).modal().build();
}
