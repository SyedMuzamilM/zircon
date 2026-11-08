//! Live language-service status and lifecycle controls.
const std = @import("std");
const ui = @import("zircon_ui");
const commands = @import("../../commands.zig");
const shell = @import("../../shell.zig");
const v = @import("../components.zig");
const panel = @import("panel.zig");
const Shell = shell.Shell;

pub fn render(self: *const Shell, b: *ui.Ui) !ui.Element {
    const c = self.colors;
    var rows: std.ArrayList(ui.Element) = .empty;
    var height: f32 = 0;
    height = 12 + 22;
    try rows.append(b.allocator(), try b.fluent().div()
        .h(.{ .px = 20 })
        .shrink_0()
        .items_center()
        .padding(.{ .left = 4 })
        .flex()
        .children(.{
            v.text(b, std.fs.path.basename(self.workspace.root_path), c.muted, 12),
        }).build());
    if (self.language.activeSessions() == 0) {
        try rows.append(b.allocator(), try b.fluent().div()
            .h(.{ .px = 24 })
            .shrink_0()
            .items_center()
            .padding(.{ .left = 8 })
            .flex()
            .children(.{
                v.text(b, if (self.language_stopped) "Language servers stopped" else "No language servers running", c.muted, 12),
            }).build());
        height += 24;
    }
    for (self.language.sessions.items) |session| {
        if (session.retired) continue;
        const status: []const u8 = if (session.resolving) "Starting" else if (session.client) |client| (if (client.ready()) "Running" else "Initializing") else "Failed";
        try rows.append(b.allocator(), try b.fluent().div()
            .h(.{ .px = 24 })
            .shrink_0()
            .items_center()
            .gap_px(8)
            .padding(.{ .left = 8, .right = 8 })
            .overflow_hidden()
            .flex()
            .children(&.{
                try b.fluent().div()
                    .w(.{ .px = 6 })
                    .h(.{ .px = 6 })
                    .rounded_px(3)
                    .background(if (std.mem.eql(u8, status, "Running")) c.added else c.warning)
                    .children(.{})
                    .build(),
                try v.text(b, session.id, c.text, 13),
                try b.fluent().div().grow().children(.{}).build(),
                try v.text(b, status, c.muted, 11),
            }).build());
        height += 24;
    }
    for (self.language.documents.items) |doc| if (doc.diagnostics) |message| {
        for (message.data.diagnostics.items) |diagnostic| {
            try rows.append(b.allocator(), try b.fluent().div()
                .h(.{ .px = 20 })
                .shrink_0()
                .items_center()
                .padding(.{ .left = 8, .right = 8 })
                .overflow_hidden()
                .flex()
                .children(.{v.text(b, diagnostic.message, c.warning, 11)})
                .build());
            height += 20;
        }
    };
    const rule = try v.rule(b, c);
    try rows.append(b.allocator(), try b.fluent().div()
        .margin(.{ .top = 4, .bottom = 4 })
        .children(.{rule})
        .build());
    const Command = commands.Command;
    inline for (.{ .{ Command.restart_language_servers, "Restart all servers" }, .{ Command.stop_language_servers, "Stop all servers" }, .{ Command.install_language_support, "Install language support…" } }) |action| {
        try rows.append(b.allocator(), try b.fluent().button(.{
            .label = action[1],
        })
            .h(.{ .px = 24 })
            .shrink_0()
            .justify_center()
            .padding(.{ .left = 8, .right = 8 })
            .rounded_px(v.metrics.control_radius)
            .hover_background(c.hover)
            .on_click(b.onClickWith(Shell.onCommand, action[0]))
            .children(&.{try v.text(b, action[1], c.text, 12)})
            .build());
    }
    height += 1 + 3 * 24;
    return panel.render(self, b, .{ .width = 200, .height = height, .border_only = true }, rows.items);
}
