//! Explicit project-opening modes. Native browsing and typed paths reach the
//! same validation/opening functions; existing workspace buffers stay open.
const std = @import("std");
const ui = @import("zircon_ui");
const Shell = @import("../shell.zig").Shell;
const Kind = @import("../projects.zig").Kind;
const v = @import("components.zig");
pub fn render(self: *const Shell, b: *ui.Ui) !ui.Element {
    const c = self.colors;
    var rows: std.ArrayList(ui.Element) = .empty;
    try rows.append(b.allocator(), try v.text(b, "Open a project", c.text, 18));
    inline for (.{ .{ Kind.local_folder, "Local folder", v.Icon.folder_open, "Open a folder from this Mac." }, .{ Kind.git_repository, "Git repository", v.Icon.branch, "Open an existing checkout and detect its repository root." }, .{ Kind.clone, "Clone repository", v.Icon.arrow_down, "Clone an HTTPS/SSH repository into a new local directory." } }) |entry| {
        try rows.append(b.allocator(), try b.button(.{ .label = entry[1], .children = &.{ try v.icon(b, entry[2], if (self.open_kind == entry[0]) c.accent else c.muted, 20), try b.column(.{ .gap = 5, .flex_grow = 1, .min_width = .{ .px = 0 }, .overflow = .hidden }, &.{ try v.text(b, entry[1], c.text, 14), try v.text(b, entry[3], c.muted, 12) }) }, .on_click = try b.onClickWith(entry[0], Shell.onOpenKind), .style = .{ .direction = .row, .height = .{ .px = 64 }, .flex_shrink = 0, .align_items = .center, .gap = 12, .padding = ui.Insets.all(10), .radius = 4, .background = if (self.open_kind == entry[0]) c.selected else c.document, .hover_background = c.hover } }));
    }
    if (self.fields) |fields| {
        try rows.append(b.allocator(), try v.text(b, if (self.open_kind == .clone) "Repository URL or absolute local repository path" else "Folder path", c.muted, 12));
        const input = try b.styled(try b.key(.{ .string = "project-path" }, try b.view(fields.path)), .{ .height = .{ .px = 34 }, .flex_grow = 1, .min_width = .{ .px = 0 } });
        try rows.append(b.allocator(), try b.row(.{ .height = .{ .px = 34 }, .flex_shrink = 0, .gap = 8, .align_items = .center }, if (self.open_kind == .clone) &.{try b.autofocus(input)} else &.{ try b.autofocus(input), try v.actionButton(b, c, .browse_project, "Browse…", false) }));
        if (self.open_kind == .clone) {
            try rows.append(b.allocator(), try v.text(b, "Destination directory", c.muted, 12));
            try rows.append(b.allocator(), try b.styled(try b.key(.{ .string = "clone-destination" }, try b.view(fields.destination)), .{ .height = .{ .px = 34 }, .flex_shrink = 0 }));
        }
    }
    try rows.append(b.allocator(), try v.text(b, "Projects open in a new window. Current buffers stay open.", c.muted, 12));
    if (self.status_is_error and self.status.len > 0) try rows.append(b.allocator(), try v.text(b, self.status, c.warning, 12));
    try rows.append(b.allocator(), try b.row(.{ .height = .{ .px = 28 }, .flex_shrink = 0, .gap = 8, .justify_content = .end }, &.{ try v.actionButton(b, c, .dismiss, "Cancel", false), try b.button(.{ .label = if (self.cloning) "Cloning…" else if (self.open_kind == .clone) "Clone and open" else "Open project", .on_click = if (self.cloning) null else try b.onClickWith(@import("../commands.zig").Command.submit_project, Shell.onCommand), .style = v.buttonStyle(c, true) }) }));
    const height: f32 = if (self.open_kind == .clone) 500 else 432;
    const panel = try b.key(.{ .string = "dialog" }, try b.column(.{ .width = .{ .px = @min(600, b.viewport().width - 32) }, .height = .{ .px = @min(height, b.viewport().height - 32) }, .padding = ui.Insets.all(20), .gap = 12, .background = c.panel, .radius = 6, .overflow = .hidden }, rows.items));
    return b.modal(try b.stack(.{ .align_items = .center, .justify_content = .center, .background = .{ .r = 0, .g = 0, .b = 0, .a = 0.35 } }, &.{panel}));
}
