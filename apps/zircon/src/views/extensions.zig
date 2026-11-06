//! The manager lists actual local contribution packages. Available entries are
//! bundled packages, with real install/enable/remove and contribution actions.
const std = @import("std");
const ui = @import("zircon_ui");
const Shell = @import("../shell.zig").Shell;
const ext = @import("zircon_extensions");
pub const Action = enum { toggle, remove, theme, icons };
pub const Payload = struct { extension: u32, contribution: u32 = 0, action: Action };
pub fn render(self: *const Shell, b: *ui.Ui) !ui.Element {
    const c = self.colors;
    var rows: std.ArrayList(ui.Element) = .empty;
    try rows.append(b.allocator(), try b.row(.{ .height = .{ .px = 42 }, .align_items = .center, .gap = 12 }, &.{ try b.styled(try b.text("Extensions"), .{ .flex_grow = 1, .text = .{ .size = 23, .color = c.text } }), try command(b, .install_extension, "Install dev extension…", c), try command(b, .back_to_editor, "Back to editor", c) }));
    try rows.append(b.allocator(), try label(b, "Local themes, icons, language syntax and language-server configurations.", c.muted, 13));
    if (self.extension_snapshot) |snapshot| {
        const entries = snapshot.installed();
        if (entries.len == 0) try rows.append(b.allocator(), try label(b, "No extensions installed.", c.muted, 14));
        for (entries, 0..) |entry, i| {
            var content: std.ArrayList(ui.Element) = .empty;
            try content.append(b.allocator(), try b.row(.{ .gap = 10, .align_items = .center }, &.{ try b.styled(try b.text(try std.fmt.allocPrint(b.allocator(), "{s}  {s}", .{ entry.name, entry.version })), .{ .flex_grow = 1, .text = .{ .size = 16, .color = c.text } }), try action(b, .{ .extension = @intCast(i), .action = .toggle }, if (entry.enabled) "Disable" else "Enable", c), try action(b, .{ .extension = @intCast(i), .action = .remove }, "Remove", c) }));
            try content.append(b.allocator(), try label(b, entry.description, c.muted, 13));
            var choices: std.ArrayList(ui.Element) = .empty;
            for (entry.themes, 0..) |theme, index| try choices.append(b.allocator(), try action(b, .{ .extension = @intCast(i), .contribution = @intCast(index), .action = .theme }, try std.fmt.allocPrint(b.allocator(), "Use {s}", .{theme.name}), c));
            for (entry.icon_themes, 0..) |icons, index| try choices.append(b.allocator(), try action(b, .{ .extension = @intCast(i), .contribution = @intCast(index), .action = .icons }, try std.fmt.allocPrint(b.allocator(), "Use {s}", .{icons.name}), c));
            if (choices.items.len > 0) try content.append(b.allocator(), try b.row(.{ .gap = 8 }, choices.items));
            for (entry.languages) |language| try content.append(b.allocator(), try label(b, try std.fmt.allocPrint(b.allocator(), "Language: {s} · {d} keywords", .{ language.name, language.keywords.len }), c.muted, 12));
            for (entry.language_servers) |server| try content.append(b.allocator(), try label(b, try std.fmt.allocPrint(b.allocator(), "Language server: {s} ({s})", .{ server.id, server.command }), c.muted, 12));
            try rows.append(b.allocator(), try b.key(.{ .string = entry.id }, try b.column(.{ .padding = ui.Insets.all(18), .gap = 12, .background = c.panel, .radius = ui.controls.metrics.popover_radius }, content.items)));
        }
        if (snapshot.extension("org.zircon.oxide") == null) try rows.append(b.allocator(), try b.column(.{ .padding = ui.Insets.all(18), .gap = 12, .background = c.panel, .radius = ui.controls.metrics.popover_radius }, &.{ try label(b, "Available locally: Oxide contributions", c.text, 16), try label(b, "A warm theme, symbol icon theme, Python syntax and ZLS configuration.", c.muted, 13), try command(b, .install_bundled_extension, "Install Oxide", c) }));
    } else try rows.append(b.allocator(), try label(b, "An extension directory has not been configured for this workspace.", c.warning, 13));
    if (self.status.len > 0) try rows.append(b.allocator(), try label(b, self.status, if (self.status_is_error) c.warning else c.muted, 13));
    return b.column(.{ .flex_grow = 1, .padding = ui.Insets.all(24), .gap = 18, .overflow = .hidden, .background = c.document }, rows.items);
}
fn label(b: *ui.Ui, bytes: []const u8, color: ui.Color, size: f32) !ui.Element {
    return b.styled(try b.text(bytes), .{ .text = .{ .size = size, .color = color } });
}
fn command(b: *ui.Ui, value: @import("../commands.zig").Command, text: []const u8, c: @import("../theme.zig").Palette) !ui.Element {
    return @import("components.zig").actionButton(b, c, value, text, false);
}
fn action(b: *ui.Ui, value: Payload, text: []const u8, c: @import("../theme.zig").Palette) !ui.Element {
    return b.button(.{ .label = text, .on_click = try b.onClickWith(value, perform), .style = buttonStyle(c) });
}
fn buttonStyle(c: @import("../theme.zig").Palette) ui.Style {
    return @import("components.zig").buttonStyle(c, false);
}
fn perform(self: *Shell, _: *ui.Event(ui.Click), cx: *ui.Context(Shell), value: Payload) !void {
    if (self.extension_snapshot == null or self.extensions == null) return;
    const snapshot = self.extension_snapshot.?;
    const entries = snapshot.installed();
    if (value.extension >= entries.len) return;
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const entry = entries[value.extension];
    const id = try arena.allocator().dupe(u8, entry.id);
    const registry = &self.extensions.?;
    switch (value.action) {
        .toggle => registry.setEnabled(id, !entry.enabled) catch |err| {
            try self.reportError(err);
            cx.notify();
            return;
        },
        .remove => registry.remove(id) catch |err| {
            try self.reportError(err);
            cx.notify();
            return;
        },
        .theme => {
            if (value.contribution >= entry.themes.len) return;
            try cx.update(self.settings.?, @import("../settings/model.zig").Settings.apply, .{@import("../settings/model.zig").Patch{ .theme = entry.themes[value.contribution].id }});
            return;
        },
        .icons => {
            if (value.contribution >= entry.icon_themes.len) return;
            try cx.update(self.settings.?, @import("../settings/model.zig").Settings.apply, .{@import("../settings/model.zig").Patch{ .icon_theme = entry.icon_themes[value.contribution].id }});
            return;
        },
    }
    @import("../services/extensions.zig").refresh(self, cx) catch |err| try self.reportError(err);
    cx.notify();
}
