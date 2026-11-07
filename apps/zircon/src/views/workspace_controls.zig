const std = @import("std");
const ui = @import("zircon_ui");
const Shell = @import("../shell.zig").Shell;
const v = @import("components.zig");
const view = @import("../view.zig");
pub const Choice = struct { name: []const u8, path: []const u8 };
const defaults = [_]Choice{
    .{ .name = "Plain Text", .path = "plain.txt" }, .{ .name = "Zig", .path = "file.zig" },
    .{ .name = "Rust", .path = "file.rs" },         .{ .name = "JSON", .path = "file.json" },
    .{ .name = "Markdown", .path = "file.md" },
};
pub fn choices(self: *const Shell, a: std.mem.Allocator, query: []const u8) ![]Choice {
    var items: std.ArrayList(Choice) = .empty;
    for (defaults) |choice| if (view.matches(query, choice.name)) try items.append(a, choice);
    if (self.extension_snapshot) |snapshot| for (snapshot.installed()) |extension| if (extension.enabled) {
        for (extension.languages) |language| {
            var duplicate = false;
            for (defaults) |choice| if (std.ascii.eqlIgnoreCase(choice.name, language.name)) {
                duplicate = true;
                break;
            };
            if (duplicate or !view.matches(query, language.name)) continue;
            const path = if (language.extensions.len > 0) try std.fmt.allocPrint(a, "file.{s}", .{std.mem.trimStart(u8, language.extensions[0], ".")}) else if (language.filenames.len > 0) language.filenames[0] else continue;
            try items.append(a, .{ .name = language.name, .path = path });
        }
    };
    return items.toOwnedSlice(a);
}
fn onChoice(self: *Shell, event: *ui.Event(ui.Click), cx: *ui.Context(Shell), index: u32) !void {
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const query = try @import("../actions.zig").field(cx, self.fields.?.query, arena.allocator());
    const items = try choices(self, arena.allocator(), query);
    if (index < items.len) try choose(self, event, cx, items[index]);
}
pub fn choose(self: *Shell, _: *ui.Event(ui.Click), cx: *ui.Context(Shell), choice: Choice) !void {
    const current = try @import("../actions.zig").active(self);
    const path = try self.allocator.dupe(u8, choice.path);
    errdefer self.allocator.free(path);
    const name = try self.allocator.dupe(u8, choice.name);
    errdefer self.allocator.free(name);
    try @import("../services/language.zig").invalidateDocument(self, current.id);
    for (self.tabs.items) |*tab| if (std.meta.eql(tab.document, current.id)) {
        if (tab.language_path) |old| self.allocator.free(old);
        if (tab.language_name) |old| self.allocator.free(old);
        tab.language_path = path;
        tab.language_name = name;
        @import("../services/extensions.zig").applyLanguage(self, &tab.editor, path);
        tab.editor.syntax_cache.clear();
        tab.editor.grammar_revision = null;
        if (tab.secondary_state) |*state| {
            @import("../services/extensions.zig").applyLanguage(self, state, path);
            state.syntax_cache.clear();
            state.grammar_revision = null;
        }
        if (self.secondary) |*pane| if (std.meta.eql(pane.document, current.id)) {
            @import("../services/extensions.zig").applyLanguage(self, &pane.editor, path);
            pane.editor.syntax_cache.clear();
            pane.editor.grammar_revision = null;
        };
        break;
    };
    self.popup = .none;
    self.editor_focus_request +%= 1;
    cx.notify();
}
fn openRecent(self: *Shell, _: *ui.Event(ui.Click), cx: *ui.Context(Shell), index: u32) !void {
    if (index >= self.recent.entries.items.len) return;
    _ = @import("../projects.zig").open(self, cx, self.recent.entries.items[index], .local_folder) catch |err| {
        try self.reportError(err);
        cx.notify();
        return;
    };
    self.popup = .none;
    cx.notify();
}
pub fn input(self: *Shell, e: *ui.Event(ui.Input), cx: *ui.Context(Shell)) !bool {
    if (self.popup == .none or e.data != .key_down) return false;
    const key = e.data.key_down.key;
    if (key == .escape) self.popup = .none else if (self.popup == .language or self.popup == .recent) {
        if (key != .up and key != .down and key != .enter) return false;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const query = try @import("../actions.zig").field(cx, self.fields.?.query, arena.allocator());
        const languages = try choices(self, arena.allocator(), query);
        var recent: std.ArrayList(u32) = .empty;
        for (self.recent.entries.items, 0..) |entry, i| if (view.matches(query, entry)) try recent.append(arena.allocator(), @intCast(i));
        const count = if (self.popup == .language) languages.len else recent.items.len;
        if (count > 0) {
            self.overlay_index = @min(self.overlay_index, count - 1);
            if (key == .down) self.overlay_index = (self.overlay_index + 1) % count;
            if (key == .up) self.overlay_index = (self.overlay_index + count - 1) % count;
            if (key == .enter) {
                var event: ui.Event(ui.Click) = .{ .data = .{} };
                if (self.popup == .language) try choose(self, &event, cx, languages[self.overlay_index]) else try openRecent(self, &event, cx, recent.items[self.overlay_index]);
            }
        }
    } else return false;
    e.preventDefault();
    e.stopPropagation();
    cx.notify();
    return true;
}
pub fn render(self: *const Shell, b: *ui.Ui) !ui.Element {
    const c = self.colors;
    var rows: std.ArrayList(ui.Element) = .empty;
    var height: f32 = 0;
    const searchable = self.popup == .language or self.popup == .recent;
    if (searchable) {
        try rows.append(b.allocator(), try b.styled(try b.autofocus(try b.key(.{ .string = "workspace-query" }, try b.view(self.fields.?.query))), .{ .height = .{ .px = 38 }, .flex_shrink = 0 }));
        try rows.append(b.allocator(), try v.rule(b, c));
        const query = try view.fieldText(b, self.fields.?.query);
        var options: std.ArrayList(ui.Element) = .empty;
        if (self.popup == .language) {
            const items = try choices(self, b.allocator(), query);
            for (items, 0..) |choice, i| {
                const id = if (self.active_pane == .secondary and self.secondary != null) self.secondary.?.document else self.tabs.items[self.active].document;
                const selected_name = self.languageName(id);
                const selected = if (selected_name) |name| std.mem.eql(u8, name, choice.name) else std.mem.eql(u8, std.fs.path.extension((try self.workspace.getConst(id)).path orelse ""), std.fs.path.extension(choice.path));
                try options.append(b.allocator(), try b.button(.{ .label = choice.name, .children = &.{ try v.fileGlyph(self, b, choice.path, false, false, 14), try v.text(b, choice.name, c.text, 13), try b.div(.{ .flex_grow = 1 }, &.{}), try v.text(b, if (selected) "Current" else "", c.muted, 11) }, .on_click = try b.onClickWith(@as(u32, @intCast(i)), onChoice), .style = .{ .direction = .row, .height = .{ .px = 30 }, .flex_shrink = 0, .align_items = .center, .gap = 8, .padding = .{ .left = 10, .right = 10 }, .background = if (i == @min(self.overlay_index, items.len -| 1)) c.selected else null, .hover_background = c.hover } }));
            }
        } else {
            for (self.recent.entries.items, 0..) |entry, i| if (view.matches(query, entry)) {
                try options.append(b.allocator(), try b.button(.{ .label = entry, .children = &.{ try v.icon(b, .folder, c.muted, 14), try b.column(.{ .gap = 3, .min_width = .{ .px = 0 }, .overflow = .hidden }, &.{ try v.text(b, std.fs.path.basename(entry), c.text, 13), try v.text(b, entry, c.muted, 11) }) }, .on_click = try b.onClickWith(@as(u32, @intCast(i)), openRecent), .style = .{ .direction = .row, .height = .{ .px = 46 }, .flex_shrink = 0, .align_items = .center, .gap = 8, .padding = .{ .left = 10 }, .background = if (options.items.len == self.overlay_index) c.selected else null, .hover_background = c.hover } }));
            };
        }
        if (options.items.len == 0) try options.append(b.allocator(), try v.text(b, "No matches", c.muted, 13));
        const row_height: f32 = if (self.popup == .language) 30 else 46;
        const visible = @min(@as(f32, @floatFromInt(options.items.len)) * row_height, @max(30, b.viewport().height - 240));
        const scroll = @max(0, @as(f32, @floatFromInt(self.overlay_index + 1)) * row_height - visible);
        try rows.append(b.allocator(), try b.column(.{ .height = .{ .px = visible }, .scroll_y = scroll, .flex_shrink = 0, .overflow = .hidden }, options.items));
        height = 52 + visible;
        if (self.popup == .recent) {
            try rows.append(b.allocator(), try v.rule(b, c));
            try rows.append(b.allocator(), try v.menuRow(b, c, .open_project, "Open local folder or Git repository…", "", false));
            height += 32;
        }
    } else if (self.popup == .servers) {
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
        const Command = @import("../commands.zig").Command;
        inline for (.{ .{ Command.restart_language_servers, "Restart all servers" }, .{ Command.stop_language_servers, "Stop all servers" }, .{ Command.install_language_support, "Install language support…" } }) |action| {
            try rows.append(b.allocator(), try b.button(.{ .label = action[1], .children = &.{try v.text(b, action[1], c.text, 12)}, .on_click = try b.onClickWith(action[0], Shell.onCommand), .style = .{ .height = .{ .px = 24 }, .flex_shrink = 0, .justify_content = .center, .padding = .{ .left = 8, .right = 8 }, .radius = v.metrics.control_radius, .hover_background = c.hover } }));
        }
        height += 1 + 3 * 24;
    } else {
        const state = if (self.active_pane == .secondary and self.secondary != null) &self.secondary.?.editor else &self.tabs.items[self.active].editor;
        try rows.append(b.allocator(), try v.menuRow(b, c, .toggle_soft_wrap, "Soft wrap", if (state.soft_wrap != .none) "✓" else "", false));
        try rows.append(b.allocator(), try v.menuRow(b, c, .toggle_inline_blame, "Inline Git blame", if (self.inline_blame_enabled) "✓" else "", false));
        try rows.append(b.allocator(), try v.menuRow(b, c, .settings, "Editor settings…", "⌘,", false));
        try rows.append(b.allocator(), try v.menuRow(b, c, .toggle_line_numbers, "Line numbers", if (state.show_line_numbers) "✓" else "", false));
        try rows.append(b.allocator(), try v.menuRow(b, c, .toggle_indent_guides, "Indent guides", if (state.show_indent_guides) "✓" else "", false));
        try rows.append(b.allocator(), try v.rule(b, c));
        try rows.append(b.allocator(), try v.menuRow(b, c, .toggle_vim, "Vim mode", if (state.vim.enabled) "✓" else "", false));
        height = 194;
    }
    height = @min(height, b.viewport().height - 40);
    const width: f32 = @min(if (self.popup == .language) @as(f32, 520) else if (self.popup == .servers) @as(f32, 200) else @as(f32, 380), b.viewport().width - 24);
    const placement = if (self.popup == .language) ui.Rect{ .x = (b.viewport().width - width) / 2, .y = @min(78, b.viewport().height * 0.13), .width = width, .height = height } else v.popoverBounds(b.viewport(), self.popup_anchor, .{ .width = width, .height = height });
    const panel = try b.key(.{ .string = "workspace-popup" }, if (self.popup == .servers)
        try b.column(.{ .width = .{ .px = placement.width }, .height = .{ .px = placement.height }, .flex_shrink = 0, .padding = ui.Insets.all(1), .radius = v.metrics.popover_radius, .background = c.line }, &.{try b.column(.{ .flex_grow = 1, .padding = ui.Insets.all(5), .radius = v.metrics.popover_radius - 1, .background = c.panel, .overflow = .hidden }, rows.items)})
    else
        try v.floatingPanel(b, c, .{ .width = placement.width, .height = placement.height }, ui.Insets.all(6), 0, rows.items));
    return b.modal(try b.listen(try b.stack(.{ .padding = .{ .top = placement.y, .left = placement.x }, .align_items = .start }, &.{panel}), .{ .on_input = b.onInput(Shell.onMenuInput) }));
}
