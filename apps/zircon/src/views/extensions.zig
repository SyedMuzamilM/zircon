//! Installed packages and a virtualized view of the official Zed registry.
const std = @import("std");
const ext = @import("zircon_extensions");
const ui = @import("zircon_ui");
const commands = @import("../commands.zig");
const services_catalog = @import("../services/catalog.zig");
const services_extensions = @import("../services/extensions.zig");
const settings_model = @import("../settings/model.zig");
const shell = @import("../shell.zig");
const theme_module = @import("../theme.zig");
const components = @import("components.zig");
const Shell = shell.Shell;
pub const Action = enum { toggle, remove, theme, icons };
pub const Payload = struct { extension: u32, contribution: u32 = 0, action: Action };
pub fn render(self: *const Shell, b: *ui.Ui) !ui.Element {
    const c = self.colors;
    var current_theme: []const u8 = "";
    if (self.settings) |settings| {
        const model = settings_model;
        var values: model.Values = undefined;
        try b.watch(settings, model.Settings.copy, .{ b.allocator(), &values });
        current_theme = values.theme;
    }
    var rows: std.ArrayList(ui.Element) = .empty;
    try rows.append(b.allocator(), try b.fluent().div().h(.{ .px = 42 }).shrink_0().items_center().gap_px(12).flex().children(.{ b.fluent().text("Extensions").style(.{ .flex_grow = 1, .text = .{ .size = 23, .color = c.text } }), command(b, .install_extension, "Install dev extension…", c), command(b, .back_to_editor, "Back to editor", c) }).build());
    try rows.append(b.allocator(), try b.fluent().div().h(.{ .px = 32 }).shrink_0().gap_px(8).flex().children(.{ tab(b, self, false, "Installed"), tab(b, self, true, "All Zed extensions") }).build());
    if (self.catalog.show_available) {
        try rows.append(b.allocator(), try available(self, b));
        return b.fluent().div().grow().padding(ui.Insets.all(24)).gap_px(12).overflow_hidden().background(c.document).flex_col().children(rows.items).build();
    }
    try rows.append(b.allocator(), try label(b, "Installed themes, file icons, grammars and language servers.", c.muted, 13));
    var installed_height: f32 = 120;
    if (self.extension_snapshot) |snapshot| {
        const entries = snapshot.installed();
        if (entries.len == 0) try rows.append(b.allocator(), try label(b, "No extensions installed.", c.muted, 14));
        for (entries, 0..) |entry, i| {
            var content: std.ArrayList(ui.Element) = .empty;
            try content.append(b.allocator(), try b.fluent().div().gap_px(10).items_center().flex().children(.{ b.fluent().text(try std.fmt.allocPrint(b.allocator(), "{s}  {s}", .{ entry.name, entry.version })).style(.{ .flex_grow = 1, .text = .{ .size = 16, .color = c.text } }), action(b, .{ .extension = @intCast(i), .action = .toggle }, if (entry.enabled) "Disable" else "Enable", c), action(b, .{ .extension = @intCast(i), .action = .remove }, "Remove", c) }).build());
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
            if (choices.items.len > 0) try content.append(b.allocator(), try b.fluent().div().gap_px(8).flex().children(choices.items).build());
            for (entry.languages) |language| try content.append(b.allocator(), try label(b, try std.fmt.allocPrint(b.allocator(), "{s} syntax highlighting", .{language.name}), c.muted, 12));
            for (entry.language_servers) |server| {
                var status: []const u8 = "Starts when a matching file opens";
                for (self.language.sessions.items) |session| if (!session.retired and std.mem.eql(u8, session.id, server.id)) {
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
            try rows.append(b.allocator(), try b.fluent().div().h(.{ .px = height }).shrink_0().overflow_hidden().padding(ui.Insets.all(18)).gap_px(12).background(c.panel).rounded_px(ui.controls.metrics.popover_radius).flex_col().children(content.items).id(.{ .string = entry.id }).build());
        }
        if (snapshot.extension("org.zircon.oxide") == null) try rows.append(b.allocator(), try b.fluent().div().padding(ui.Insets.all(18)).gap_px(12).background(c.panel).rounded_px(ui.controls.metrics.popover_radius).flex_col().children(.{ label(b, "Available locally: Oxide contributions", c.text, 16), label(b, "A warm theme, symbol icon theme, Python syntax and ZLS configuration.", c.muted, 13), command(b, .install_bundled_extension, "Install Oxide", c) }).build());
    } else try rows.append(b.allocator(), try label(b, "An extension directory has not been configured for this workspace.", c.warning, 13));
    if (self.status.len > 0) try rows.append(b.allocator(), try label(b, self.status, if (self.status_is_error) c.warning else c.muted, 13));
    const list = try b.fluent().div().grow().min_h(.{ .px = 0 }).gap_px(18).overflow_hidden().scroll_y_px(self.catalog.installed_scroll.offset).flex_col().children(rows.items[3..]).listeners(.{ .on_input = b.onInputWith(scrollInstalled, installed_height) }).build();
    return b.fluent().div().grow().padding(ui.Insets.all(24)).gap_px(18).overflow_hidden().background(c.document).flex_col().children(.{ rows.items[0], rows.items[1], rows.items[2], list }).build();
}
fn label(b: *ui.Ui, bytes: []const u8, color: ui.Color, size: f32) !ui.Element {
    return b.fluent().text(bytes).style(.{ .height = .{ .px = size * 1.5 }, .flex_shrink = 0, .overflow = .hidden, .text = .{ .size = size, .color = color } }).build();
}
fn command(b: *ui.Ui, value: commands.Command, text: []const u8, c: theme_module.Palette) !ui.Element {
    return components.actionButton(b, c, value, text, false);
}
fn action(b: *ui.Ui, value: Payload, text: []const u8, c: theme_module.Palette) !ui.Element {
    return b.fluent().button(.{ .label = text, .on_click = b.onClickWith(perform, value), .style = buttonStyle(c) }).build();
}
fn buttonStyle(c: theme_module.Palette) ui.Style {
    return components.buttonStyle(c, false);
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
            try cx.update(self.settings.?, settings_model.Settings.apply, .{settings_model.Patch{ .theme = entry.themes[value.contribution].id }});
            return;
        },
        .icons => {
            if (value.contribution >= entry.icon_themes.len) return;
            try cx.update(self.settings.?, settings_model.Settings.apply, .{settings_model.Patch{ .icon_theme = entry.icon_themes[value.contribution].id }});
            return;
        },
    }
    services_extensions.refresh(self, cx) catch |err| try self.reportError(err);
    cx.notify();
}

fn tab(b: *ui.Ui, self: *const Shell, all: bool, name: []const u8) !ui.Element {
    return b.fluent().button(.{ .label = name, .on_click = b.onClickWith(chooseTab, all), .style = components.buttonStyle(self.colors, self.catalog.show_available == all) }).build();
}
fn chooseTab(self: *Shell, _: *ui.Event(ui.Click), cx: *ui.Context(Shell), all: bool) !void {
    self.catalog.show_available = all;
    if (all and self.catalog.parsed == null and !self.catalog.busy) services_catalog.search(self, cx) catch |err| try self.reportError(err);
    cx.notify();
}
fn queryInput(self: *Shell, e: *ui.Event(ui.Input), cx: *ui.Context(Shell)) !void {
    if (e.data != .key_down or e.data.key_down.key != .enter) return;
    services_catalog.search(self, cx) catch |err| try self.reportError(err);
    e.preventDefault();
}
fn available(self: *const Shell, b: *ui.Ui) !ui.Element {
    const v = components;
    const c = self.colors;
    var content: std.ArrayList(ui.Element) = .empty;
    if (self.fields) |fields| try content.append(b.allocator(), try b.fluent().div().h(.{ .px = 36 }).shrink_0().gap_px(8).flex().children(.{ b.fluent().view(fields.extension_query).style(.{ .flex_grow = 1, .min_width = .{ .px = 0 } }).id(.{ .string = "extension-search" }).autofocus().request_focus(self.editor_focus_request), command(b, .extension_search, if (self.catalog.busy) "Searching…" else "Search", c) }).listeners(.{ .on_input = b.onInput(queryInput) }).build());
    if (self.catalog.error_text.len > 0) try content.append(b.allocator(), try label(b, self.catalog.error_text, c.warning, 12));
    var entries: []const services_catalog.Entry = &.{};
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
        try rows.append(b.allocator(), try b.fluent().div().h(.{ .px = 92 }).shrink_0().gap_px(8).padding(ui.Insets.all(12)).background(c.document).overflow_hidden().flex_col().children(&.{ try b.fluent().div().h(.{ .px = 28 }).gap_px(8).items_center().flex().children(.{ v.icon(b, .extension, c.muted, 16), b.fluent().adopt(try label(b, entry.name, c.text, 14)).style(.{ .flex_grow = 1, .min_width = .{ .px = 0 }, .overflow = .hidden }), label(b, entry.version, c.muted, 11), b.fluent().button(.{ .label = if (!supported) "Not supported yet" else if (busy) "Installing…" else if (update) "Update" else if (installed) "Installed" else "Install", .on_click = if (!supported or (installed and !update) or self.catalog.installing != null) null else try b.onClickWith(installRemote, Remote{ .generation = self.catalog.generation, .index = @intCast(i) }), .style = v.buttonStyle(c, (!installed or update) and !busy) }) }).build(), try label(b, if (entry.description.len > 0) entry.description else entry.id, c.muted, 12), try v.rule(b, c) }).id(.{ .string = entry.id }).build());
    }
    try content.append(b.allocator(), try b.fluent().div().grow().min_h(.{ .px = 0 }).scroll_y_px(@max(0, -visible.top)).overflow_hidden().flex_col().children(rows.items).listeners(.{ .on_input = b.onInputWith(scroll, @as(f32, @floatFromInt(entries.len)) * 92) }).build());
    return b.fluent().div().grow().min_h(.{ .px = 0 }).gap_px(12).flex_col().children(content.items).build();
}
const Remote = struct { generation: u64, index: u32 };
fn installRemote(self: *Shell, _: *ui.Event(ui.Click), cx: *ui.Context(Shell), target: Remote) !void {
    const p = self.catalog.parsed orelse return;
    if (target.generation != self.catalog.generation or target.index >= p.value.entries.len) return;
    services_catalog.install(self, cx, p.value.entries[target.index].id) catch |err| try self.reportError(err);
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
