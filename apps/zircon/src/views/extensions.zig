//! Installed packages and a virtualized view of the official Zed registry.
const std = @import("std");
const ui = @import("zircon_ui");
const Shell = @import("../shell.zig").Shell;
const ext = @import("zircon_extensions");
pub const Action = enum { toggle, remove, theme, icons };
pub const Payload = struct { extension: u32, contribution: u32 = 0, action: Action };
pub fn render(self: *const Shell, b: *ui.Ui) !ui.Element {
    const c = self.colors;
    var current_theme: []const u8 = "";
    if (self.settings) |settings| {
        const model = @import("../settings/model.zig");
        var values: model.Values = undefined;
        try b.watch(settings, model.Settings.copy, .{ b.allocator(), &values });
        current_theme = values.theme;
    }
    var rows: std.ArrayList(ui.Element) = .empty;
    try rows.append(b.allocator(), try b.row(.{ .height = .{ .px = 42 }, .flex_shrink = 0, .align_items = .center, .gap = 12 }, &.{ try b.styled(try b.text("Extensions"), .{ .flex_grow = 1, .text = .{ .size = 23, .color = c.text } }), try command(b, .install_extension, "Install dev extension…", c), try command(b, .back_to_editor, "Back to editor", c) }));
    try rows.append(b.allocator(), try b.row(.{ .height = .{ .px = 32 }, .flex_shrink = 0, .gap = 8 }, &.{ try tab(b, self, false, "Installed"), try tab(b, self, true, "All Zed extensions") }));
    if (self.catalog.show_available) {
        try rows.append(b.allocator(), try available(self, b));
        return b.column(.{ .flex_grow = 1, .padding = ui.Insets.all(24), .gap = 12, .overflow = .hidden, .background = c.document }, rows.items);
    }
    try rows.append(b.allocator(), try label(b, "Installed themes, file icons, grammars and language servers.", c.muted, 13));
    var installed_height: f32 = 120;
    if (self.extension_snapshot) |snapshot| {
        const entries = snapshot.installed();
        if (entries.len == 0) try rows.append(b.allocator(), try label(b, "No extensions installed.", c.muted, 14));
        for (entries, 0..) |entry, i| {
            var content: std.ArrayList(ui.Element) = .empty;
            try content.append(b.allocator(), try b.row(.{ .gap = 10, .align_items = .center }, &.{ try b.styled(try b.text(try std.fmt.allocPrint(b.allocator(), "{s}  {s}", .{ entry.name, entry.version })), .{ .flex_grow = 1, .text = .{ .size = 16, .color = c.text } }), try action(b, .{ .extension = @intCast(i), .action = .toggle }, if (entry.enabled) "Disable" else "Enable", c), try action(b, .{ .extension = @intCast(i), .action = .remove }, "Remove", c) }));
            try content.append(b.allocator(), try label(b, entry.description, c.muted, 13));
            if (entry.unsupported_features.len > 0) try content.append(b.allocator(), try label(b, try std.fmt.allocPrint(b.allocator(), "Not available here: {s}", .{try std.mem.join(b.allocator(), ", ", entry.unsupported_features)}), c.warning, 12));
            var choices: std.ArrayList(ui.Element) = .empty;
            if (entry.themes.len > 0) {
                var index: usize = 0;
                for (entry.themes, 0..) |theme, i_theme| if (std.mem.eql(u8, theme.id, current_theme)) {
                    index = i_theme;
                    break;
                };
                try choices.append(b.allocator(), try action(b, .{ .extension = @intCast(i), .contribution = @intCast(index), .action = .theme }, try std.fmt.allocPrint(b.allocator(), "Use {s}", .{entry.themes[index].name}), c));
            }
            if (entry.icon_themes.len > 0) {
                var index: usize = 0;
                for (entry.icon_themes, 0..) |theme, i_theme| if (std.mem.eql(u8, theme.id, self.active_icon_theme)) {
                    index = i_theme;
                    break;
                };
                try choices.append(b.allocator(), try action(b, .{ .extension = @intCast(i), .contribution = @intCast(index), .action = .icons }, try std.fmt.allocPrint(b.allocator(), "Use {s}", .{entry.icon_themes[index].name}), c));
            }
            if (entry.themes.len > 1 or entry.icon_themes.len > 1) try choices.append(b.allocator(), try command(b, .settings, "Choose in settings…", c));
            if (choices.items.len > 0) try content.append(b.allocator(), try b.row(.{ .gap = 8 }, choices.items));
            for (entry.languages) |language| try content.append(b.allocator(), try label(b, try std.fmt.allocPrint(b.allocator(), "{s} syntax highlighting", .{language.name}), c.muted, 12));
            for (entry.language_servers) |server| {
                var status: []const u8 = "Starts when a matching file opens";
                for (self.language.sessions.items) |session| if (std.mem.eql(u8, session.id, server.id)) {
                    status = if (session.resolving) "Installing / starting…" else if (session.client) |client| switch (client.status()) {
                        .ready => "Running",
                        .starting => "Starting…",
                        .failed, .exited => "Unavailable · check the status message",
                        .closing => "Stopping…",
                    } else "Unavailable · check the status message";
                };
                try content.append(b.allocator(), try label(b, try std.fmt.allocPrint(b.allocator(), "{s} · {s}", .{ server.zed_server orelse server.id, status }), c.muted, 12));
            }
            const height: f32 = 36 + 28 + 20 + (if (entry.unsupported_features.len > 0) @as(f32, 20) else 0) + @as(f32, @floatFromInt(entry.languages.len + entry.language_servers.len)) * 20 + @as(f32, @floatFromInt(content.items.len -| 1)) * 12 + (if (choices.items.len > 0) @as(f32, 30) else 0);
            installed_height += height + 18;
            try rows.append(b.allocator(), try b.key(.{ .string = entry.id }, try b.column(.{ .height = .{ .px = height }, .flex_shrink = 0, .overflow = .hidden, .padding = ui.Insets.all(18), .gap = 12, .background = c.panel, .radius = ui.controls.metrics.popover_radius }, content.items)));
        }
        if (snapshot.extension("org.zircon.oxide") == null) try rows.append(b.allocator(), try b.column(.{ .padding = ui.Insets.all(18), .gap = 12, .background = c.panel, .radius = ui.controls.metrics.popover_radius }, &.{ try label(b, "Available locally: Oxide contributions", c.text, 16), try label(b, "A warm theme, symbol icon theme, Python syntax and ZLS configuration.", c.muted, 13), try command(b, .install_bundled_extension, "Install Oxide", c) }));
    } else try rows.append(b.allocator(), try label(b, "An extension directory has not been configured for this workspace.", c.warning, 13));
    if (self.status.len > 0) try rows.append(b.allocator(), try label(b, self.status, if (self.status_is_error) c.warning else c.muted, 13));
    const list = try b.listen(try b.column(.{ .flex_grow = 1, .min_height = .{ .px = 0 }, .gap = 18, .overflow = .hidden, .scroll_y = self.catalog.installed_scroll.offset }, rows.items[3..]), .{ .on_input = try b.onInputWith(installed_height, scrollInstalled) });
    return b.column(.{ .flex_grow = 1, .padding = ui.Insets.all(24), .gap = 18, .overflow = .hidden, .background = c.document }, &.{ rows.items[0], rows.items[1], rows.items[2], list });
}
fn label(b: *ui.Ui, bytes: []const u8, color: ui.Color, size: f32) !ui.Element {
    return b.styled(try b.text(bytes), .{ .height = .{ .px = size * 1.5 }, .flex_shrink = 0, .overflow = .hidden, .text = .{ .size = size, .color = color } });
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

fn tab(b: *ui.Ui, self: *const Shell, all: bool, name: []const u8) !ui.Element {
    return b.button(.{ .label = name, .on_click = try b.onClickWith(all, chooseTab), .style = @import("components.zig").buttonStyle(self.colors, self.catalog.show_available == all) });
}
fn chooseTab(self: *Shell, _: *ui.Event(ui.Click), cx: *ui.Context(Shell), all: bool) !void {
    self.catalog.show_available = all;
    if (all and self.catalog.parsed == null and !self.catalog.busy) @import("../services/catalog.zig").search(self, cx) catch |err| try self.reportError(err);
    cx.notify();
}
fn queryInput(self: *Shell, e: *ui.Event(ui.Input), cx: *ui.Context(Shell)) !void {
    if (e.data != .key_down or e.data.key_down.key != .enter) return;
    @import("../services/catalog.zig").search(self, cx) catch |err| try self.reportError(err);
    e.preventDefault();
}
fn available(self: *const Shell, b: *ui.Ui) !ui.Element {
    const v = @import("components.zig");
    const c = self.colors;
    var content: std.ArrayList(ui.Element) = .empty;
    if (self.fields) |fields| try content.append(b.allocator(), try b.listen(try b.row(.{ .height = .{ .px = 36 }, .flex_shrink = 0, .gap = 8 }, &.{ try b.autofocus(try b.key(.{ .string = "extension-search" }, try b.styled(try b.view(fields.extension_query), .{ .flex_grow = 1, .min_width = .{ .px = 0 } }))), try command(b, .extension_search, if (self.catalog.busy) "Searching…" else "Search", c) }), .{ .on_input = b.onInput(queryInput) }));
    if (self.catalog.error_text.len > 0) try content.append(b.allocator(), try label(b, self.catalog.error_text, c.warning, 12));
    var entries: []const @import("../services/catalog.zig").Entry = &.{};
    if (self.catalog.parsed) |p| {
        entries = p.value.entries;
        try content.append(b.allocator(), try label(b, try std.fmt.allocPrint(b.allocator(), "{d} results · {d} extensions in the official Zed registry", .{ entries.len, p.value.total }), c.muted, 12));
    }
    const height = @max(1, b.viewport().height - 250);
    const visible = try ui.controls.visibleRows(entries.len, 92, self.catalog.scroll.offset, height, 1);
    var rows: std.ArrayList(ui.Element) = .empty;
    for (entries[visible.start..visible.end], visible.start..) |entry, i| {
        const id = entry.installed_id orelse try std.fmt.allocPrint(b.allocator(), "zed.{s}", .{entry.id});
        const installed_entry = if (self.extension_snapshot) |s| s.extension(id) else null;
        const installed = installed_entry != null;
        const update = if (installed_entry) |local| !std.mem.eql(u8, local.version, entry.version) else false;
        var supported = !entry.metadata_available or entry.source.len == 0 or std.mem.eql(u8, entry.source, "zircon");
        for (entry.provides) |feature| for ([_][]const u8{ "themes", "icon-themes", "languages", "grammars", "language-servers" }) |known| {
            if (std.mem.eql(u8, feature, known)) supported = true;
        };
        const busy = self.catalog.install_id != null and std.mem.eql(u8, self.catalog.install_id.?, entry.id);
        try rows.append(b.allocator(), try b.key(.{ .string = entry.id }, try b.column(.{ .height = .{ .px = 92 }, .flex_shrink = 0, .gap = 8, .padding = ui.Insets.all(12), .background = c.document, .overflow = .hidden }, &.{ try b.row(.{ .height = .{ .px = 28 }, .gap = 8, .align_items = .center }, &.{ try v.icon(b, .extension, c.muted, 16), try b.styled(try label(b, entry.name, c.text, 14), .{ .flex_grow = 1, .min_width = .{ .px = 0 }, .overflow = .hidden }), try label(b, entry.version, c.muted, 11), try b.button(.{ .label = if (!supported) "Not supported yet" else if (busy) "Installing…" else if (update) "Update" else if (installed) "Installed" else "Install", .on_click = if (!supported or (installed and !update) or self.catalog.installing != null) null else try b.onClickWith(Remote{ .generation = self.catalog.generation, .index = @intCast(i) }, installRemote), .style = v.buttonStyle(c, (!installed or update) and !busy) }) }), try label(b, if (entry.description.len > 0) entry.description else entry.id, c.muted, 12), try v.rule(b, c) })));
    }
    try content.append(b.allocator(), try b.listen(try b.column(.{ .flex_grow = 1, .min_height = .{ .px = 0 }, .scroll_y = @max(0, -visible.top), .overflow = .hidden }, rows.items), .{ .on_input = try b.onInputWith(@as(f32, @floatFromInt(entries.len)) * 92, scroll) }));
    return b.column(.{ .flex_grow = 1, .min_height = .{ .px = 0 }, .gap = 12 }, content.items);
}
const Remote = struct { generation: u64, index: u32 };
fn installRemote(self: *Shell, _: *ui.Event(ui.Click), cx: *ui.Context(Shell), target: Remote) !void {
    const p = self.catalog.parsed orelse return;
    if (target.generation != self.catalog.generation or target.index >= p.value.entries.len) return;
    @import("../services/catalog.zig").install(self, cx, p.value.entries[target.index].id) catch |err| try self.reportError(err);
}
fn scroll(self: *Shell, e: *ui.Event(ui.Input), cx: *ui.Context(Shell), total: f32) void {
    if (e.data != .scroll) return;
    self.catalog.scroll.wheel(e.data.scroll.y, total, e.bounds.height);
    e.preventDefault();
    cx.notify();
}

fn scrollInstalled(self: *Shell, e: *ui.Event(ui.Input), cx: *ui.Context(Shell), total: f32) void {
    if (e.data != .scroll) return;
    self.catalog.installed_scroll.wheel(e.data.scroll.y, total, e.bounds.height);
    e.preventDefault();
    cx.notify();
}
