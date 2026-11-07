//! Live language-service status and lifecycle controls.
const std = @import("std");
const ui = @import("zircon_ui");
const Shell = @import("../../shell.zig").Shell;
const v = @import("../components.zig");
const view = @import("../../view.zig");
const panel = @import("panel.zig");

pub fn render(self: *const Shell, b: *ui.Ui) !ui.Element {
    const c = self.colors;
    var rows: std.ArrayList(ui.Element) = .empty;
    var height: f32 = 0;
    height = 12 + 22;
    try rows.append(b.allocator(), try b.row(.{ .height = .{ .px = 20 }, .flex_shrink = 0, .align_items = .center, .padding = .{ .left = 4 } }, &.{try v.text(b, std.fs.path.basename(self.workspace.root_path), c.muted, 12)}));
    if (self.language.activeSessions() == 0) {
        try rows.append(b.allocator(), try b.row(.{ .height = .{ .px = 24 }, .flex_shrink = 0, .align_items = .center, .padding = .{ .left = 8 } }, &.{try v.text(b, if (self.language_stopped) "Language servers stopped" else "No language servers running", c.muted, 12)}));
        height += 24;
    }
    for (self.language.sessions.items) |session| {
        if (session.retired) continue;
        const status: []const u8 = if (session.resolving) "Starting" else if (session.client) |client| (if (client.ready()) "Running" else "Initializing") else "Failed";
        try rows.append(b.allocator(), try b.row(.{ .height = .{ .px = 24 }, .flex_shrink = 0, .align_items = .center, .gap = 8, .padding = .{ .left = 8, .right = 8 }, .overflow = .hidden }, &.{ try b.div(.{ .width = .{ .px = 6 }, .height = .{ .px = 6 }, .radius = 3, .background = if (std.mem.eql(u8, status, "Running")) c.added else c.warning }, &.{}), try v.text(b, session.id, c.text, 13), try b.div(.{ .flex_grow = 1 }, &.{}), try v.text(b, status, c.muted, 11) }));
        height += 24;
    }
    for (self.language.documents.items) |doc| if (doc.diagnostics) |message| {
        for (message.data.diagnostics.items[0..@min(5, message.data.diagnostics.items.len)]) |diagnostic| {
            try rows.append(b.allocator(), try b.row(.{ .height = .{ .px = 20 }, .flex_shrink = 0, .align_items = .center, .padding = .{ .left = 8, .right = 8 }, .overflow = .hidden }, &.{try v.text(b, diagnostic.message, c.warning, 11)}));
            height += 20;
        }
    };
    const rule = try v.rule(b, c);
    try rows.append(b.allocator(), try b.div(.{ .margin = .{ .top = 4, .bottom = 4 } }, &.{rule}));
    const Command = @import("../../commands.zig").Command;
    inline for (.{ .{ Command.restart_language_servers, "Restart all servers" }, .{ Command.stop_language_servers, "Stop all servers" }, .{ Command.install_language_support, "Install language support…" } }) |action| {
        try rows.append(b.allocator(), try b.button(.{ .label = action[1], .children = &.{try v.text(b, action[1], c.text, 12)}, .on_click = b.onClickWith(Shell.onCommand, action[0]), .style = .{ .height = .{ .px = 24 }, .flex_shrink = 0, .justify_content = .center, .padding = .{ .left = 8, .right = 8 }, .radius = v.metrics.control_radius, .hover_background = c.hover } }));
    }
    height += 1 + 3 * 24;
    return panel.render(self, b, .{ .width = 200, .height = height, .border_only = true }, rows.items);
}
