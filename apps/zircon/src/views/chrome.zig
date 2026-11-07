//! Workspace chrome follows the reference's hierarchy: project/branch at the
//! top, file tabs and tools around the canvas, panel selectors in the status bar.
const std = @import("std");
const ui = @import("zircon_ui");
const Shell = @import("../shell.zig").Shell;
const v = @import("components.zig");
pub fn titlebar(self: *const Shell, b: *ui.Ui) !ui.Element {
    const c = self.colors;
    var items: std.ArrayList(ui.Element) = .empty;
    try items.append(b.allocator(), try b.div(.{ .width = .{ .px = 70 }, .flex_shrink = 0 }, &.{}));
    try items.append(b.allocator(), try b.button(.{ .label = "Open", .children = &.{ try v.text(b, std.fs.path.basename(self.workspace.root_path), c.text, 13), try v.icon(b, .chevron_down, c.muted, 12) }, .on_click = b.onClickWith(Shell.onCommand, @import("../commands.zig").Command.recent_projects), .style = .{ .direction = .row, .height = .{ .px = 28 }, .gap = 6, .align_items = .center, .padding = .{ .left = 5, .right = 5 }, .radius = v.metrics.control_radius, .hover_background = c.hover, .flex_shrink = 1, .min_width = .{ .px = 0 }, .max_width = .{ .viewport_width = 40 }, .overflow = .hidden } }));
    if (self.git.status) |status| if (status.branch.len > 0) try items.append(b.allocator(), try b.button(.{ .label = "Branches and stashes", .children = &.{ try v.icon(b, .branch, c.muted, 14), try v.text(b, status.branch, c.muted, 12) }, .on_click = b.onClickWith(Shell.onCommand, @import("../commands.zig").Command.git_branches), .style = .{ .direction = .row, .height = .{ .px = 28 }, .gap = 5, .align_items = .center, .padding = .{ .left = 5, .right = 5 }, .radius = v.metrics.control_radius, .hover_background = c.hover, .flex_shrink = 1, .overflow = .hidden } }));
    try items.append(b.allocator(), try b.div(.{ .flex_grow = 1 }, &.{}));
    try items.append(b.allocator(), try v.iconButton(b, c, .agent_mode, "Agent workspace", .commands, self.agent_mode));
    try items.appendSlice(b.allocator(), &.{ try v.iconButton(b, c, .quick_open, "Go to file", .search, false), try v.iconButton(b, c, .workspace_menu, "Workspace menu", .more, self.menu_open) });
    const row = try b.dragRegion(try b.key(.{ .string = "toolbar" }, try b.row(.{ .height = .{ .px = v.metrics.titlebar - 1 }, .flex_shrink = 0, .align_items = .center, .gap = 6, .padding = .{ .left = 8, .right = 8 }, .background = c.chrome }, items.items)));
    return b.column(.{ .height = .{ .px = v.metrics.titlebar }, .flex_shrink = 0 }, &.{ row, try v.rule(b, c) });
}
pub fn tabs(self: *const Shell, b: *ui.Ui, width: f32) !ui.Element {
    return tabsForPane(self, b, width, 0);
}
pub fn tabsForPane(self: *const Shell, b: *ui.Ui, width: f32, pane: u8) !ui.Element {
    const c = self.colors;
    var indices: std.ArrayList(usize) = .empty;
    for (self.tabs.items, 0..) |tab, i| if (if (pane == 0) tab.primary else tab.secondary) try indices.append(b.allocator(), i);
    var position: usize = 0;
    for (indices.items, 0..) |index, i| if ((pane == 0 and index == self.active) or (pane == 1 and self.secondary != null and std.meta.eql(self.secondary.?.document, self.tabs.items[index].document))) {
        position = i;
        break;
    };
    const mask: u32 = if (pane == 1) 0x80000000 else 0;
    var items: std.ArrayList(ui.Element) = .empty;
    try items.append(b.allocator(), try navigation(self, b, if (position > 0) indices.items[position - 1] | mask else null, "previous-tab", .chevron_left));
    try items.append(b.allocator(), try navigation(self, b, if (position + 1 < indices.items.len) indices.items[position + 1] | mask else null, "next-tab", .chevron_right));
    const opened_tools = if (pane == 1) self.secondary_tools else self.tool_tabs;
    const active_tool = self.currentTool(pane);
    const tool_count: f32 = @as(f32, @floatFromInt(@as(u32, @intFromBool(opened_tools.search or active_tool == .search)) + @as(u32, @intFromBool(opened_tools.git_diff or active_tool == .git_diff)) + @as(u32, @intFromBool(opened_tools.extensions or active_tool == .extensions))));
    const source_view = active_tool == null and (pane == 1 or self.panel == .editor or self.panel == .markdown);
    const utility = tool_count > 0 or self.panel == .image;
    const source_room = @max(0, width - 104 - tool_count * 160);
    const capacity = if (utility and !source_view and width < 420 + tool_count * 100) @as(usize, 0) else @max(@as(usize, 1), @as(usize, @intFromFloat(@floor(source_room / 174))));
    const first = if (capacity == 0) @min(position, indices.items.len) else if (position >= capacity) position - capacity + 1 else 0;
    const end = @min(indices.items.len, first + capacity);
    for (indices.items[first..end]) |index| {
        const tab = self.tabs.items[index];
        const record = try self.workspace.getConst(tab.document);
        const selected = (if (pane == 0) index == self.active else self.secondary != null and std.meta.eql(self.secondary.?.document, tab.document)) and active_tool == null and (pane == 1 or self.panel == .editor or self.panel == .markdown);
        const background = if (selected) c.document else c.tab_bar;
        const accessible = try std.fmt.allocPrint(b.allocator(), "{s}{s}", .{ record.title(), if (record.dirty()) " •" else "" });
        const title = try b.listen(try b.button(.{ .label = accessible, .tooltip = record.path orelse record.title(), .tooltip_colors = .{ c.panel, c.text, c.line }, .children = &.{ try v.fileGlyph(self, b, record.path orelse record.title(), false, false, 14), try v.text(b, record.title(), if (selected) c.text else c.muted, 13) }, .on_click = b.onClickWith(Shell.onTab, @as(u32, @intCast(index)) | mask), .style = .{ .direction = .row, .flex_grow = 1, .min_width = .{ .px = 0 }, .gap = 7, .align_items = .center, .padding = .{ .left = 11, .right = 6 }, .hover_background = null, .overflow = .hidden } }), .{ .on_input = b.onInputWith(Shell.onTabDrag, @import("../panes.zig").DragTarget{ .document = tab.document, .pane = pane }) });
        const close = try b.key(.{ .string = "close" }, try b.button(.{ .label = "Close tab", .tooltip = "Close tab", .tooltip_colors = .{ c.panel, c.text, c.line }, .children = &.{if (record.dirty()) try b.div(.{ .width = .{ .px = 5 }, .height = .{ .px = 5 }, .radius = v.metrics.control_radius, .background = c.muted }, &.{}) else try v.icon(b, .close, c.muted, 12)}, .on_click = b.onClickWith(Shell.onCloseTab, @as(u32, @intCast(index)) | mask), .style = .{ .width = .{ .px = 24 }, .flex_shrink = 0, .align_items = .center, .justify_content = .center, .hover_background = c.hover } }));
        const measured = @min(@as(f32, 174), @max(@as(f32, 110), @as(f32, @floatFromInt(record.title().len)) * 7.2 + 57));
        try items.append(b.allocator(), try b.key(.{ .number = @import("../panes.zig").key(tab.document) }, try b.column(.{ .width = .{ .px = measured }, .min_width = .{ .px = 90 }, .flex_shrink = 1, .background = background }, &.{ try b.row(.{ .flex_grow = 1 }, &.{ title, close, try b.div(.{ .width = .{ .px = 1 }, .flex_shrink = 0, .background = c.line }, &.{}) }), try b.div(.{ .height = .{ .px = 1 }, .background = if (selected) c.document else c.line, .flex_shrink = 0 }, &.{}) })));
    }
    var shown_tools: usize = 0;
    inline for (.{ Shell.Tool.search, Shell.Tool.git_diff, Shell.Tool.extensions }) |tool| {
        const selected = active_tool == tool;
        const opened = switch (tool) {
            .search => opened_tools.search,
            .git_diff => opened_tools.git_diff,
            .extensions => opened_tools.extensions,
        };
        if ((opened or selected) and (width >= 520 or selected or (active_tool == null and shown_tools == 0))) {
            shown_tools += 1;
            const name: []const u8 = switch (tool) {
                .search => "Project search",
                .git_diff => if (self.git.stash_view) "Stash changes" else if (self.git.selected_commit.len > 0) "Commit changes" else "Uncommitted changes",
                .extensions => "Extensions",
            };
            const glyph: v.Icon = switch (tool) {
                .search => .search,
                .git_diff => .branch,
                .extensions => .extension,
            };
            const title = try b.button(.{ .label = name, .children = &.{ try v.icon(b, glyph, if (selected) c.accent else c.muted, 14), try b.styled(try v.text(b, name, if (selected) c.text else c.muted, 13), .{ .flex_shrink = 1, .min_width = .{ .px = 0 }, .text = .{ .size = 13, .color = if (selected) c.text else c.muted }, .overflow = .hidden }) }, .on_click = b.onClickWith(Shell.onToolTab, Shell.ToolTab{ .tool = tool, .pane = pane }), .style = .{ .direction = .row, .flex_grow = 1, .min_width = .{ .px = 0 }, .align_items = .center, .gap = 7, .padding = .{ .left = 10 }, .hover_background = null, .overflow = .hidden } });
            var close_style = v.iconButtonStyle(c, false);
            close_style.width = .{ .px = 22 };
            const close = try b.button(.{ .label = "Close view", .tooltip = "Close view", .tooltip_colors = .{ c.panel, c.text, c.line }, .children = &.{try v.icon(b, .close, c.muted, 12)}, .on_click = b.onClickWith(Shell.onCloseTool, Shell.ToolTab{ .tool = tool, .pane = pane }), .style = close_style });
            try items.append(b.allocator(), try b.key(.{ .string = @tagName(tool) }, try b.row(.{ .height = .{ .px = v.metrics.tabs }, .min_width = .{ .px = if (selected) @as(f32, 100) else 60 }, .max_width = .{ .px = 210 }, .flex_shrink = 1, .flex_grow = 0, .background = if (selected) c.document else c.tab_bar, .align_items = .center }, &.{ title, close })));
        }
    }
    if (pane == 0) if (self.image) |asset| {
        try items.append(b.allocator(), try b.row(.{ .height = .{ .px = v.metrics.tabs }, .max_width = .{ .px = 220 }, .min_width = .{ .px = 90 }, .flex_shrink = 1, .background = if (self.panel == .image) c.document else c.tab_bar }, &.{
            try b.button(.{ .label = std.fs.path.basename(asset.path), .tooltip = asset.path, .children = &.{ try v.icon(b, .image, c.muted, 14), try v.text(b, std.fs.path.basename(asset.path), c.text, 13) }, .on_click = b.onClickWith(Shell.onCommand, @import("../commands.zig").Command.show_image), .style = .{ .direction = .row, .flex_grow = 1, .min_width = .{ .px = 0 }, .align_items = .center, .gap = 7, .padding = .{ .left = 11, .right = 6 }, .overflow = .hidden } }),
            try v.iconButton(b, c, .close_image, "Close image", .close, false),
        }));
    };
    try items.append(b.allocator(), try b.column(.{ .flex_grow = 1 }, &.{ try b.div(.{ .flex_grow = 1 }, &.{}), try v.rule(b, c) }));
    try items.appendSlice(b.allocator(), &.{ try v.iconButton(b, c, .new_file, "New file", .plus, false), try v.iconButton(b, c, .split_menu, "Split editor", .split, self.split_menu_open) });
    return b.key(.{ .string = if (pane == 0) "tabs" else "secondary-tabs" }, try b.row(.{ .height = .{ .px = v.metrics.tabs }, .flex_shrink = 0, .background = c.tab_bar, .overflow = .hidden, .padding = .{ .right = 4 } }, items.items));
}
fn navigation(self: *const Shell, b: *ui.Ui, index: ?usize, key: []const u8, name: v.Icon) !ui.Element {
    const c = self.colors;
    var color = c.muted;
    if (index == null) color.a = 0.4;
    return b.key(.{ .string = key }, try b.button(.{ .label = key, .tooltip = if (name == .chevron_left) "Previous tab" else "Next tab", .tooltip_colors = .{ c.panel, c.text, c.line }, .children = &.{try v.icon(b, name, color, 14)}, .on_click = if (index) |target| try b.onClickWith(Shell.onTab, @as(u32, @intCast(target))) else null, .style = .{ .width = .{ .px = 26 }, .flex_shrink = 0, .align_items = .center, .justify_content = .center, .hover_background = if (index != null) c.hover else null } }));
}
pub fn fileHeader(self: *const Shell, b: *ui.Ui, record: *const @import("zircon_workspace").Record, document: @import("zircon_workspace").DocumentId, state: *const @import("zircon_editor").Editor) !ui.Element {
    const c = self.colors;
    var path = record.path orelse record.title();
    if (std.mem.startsWith(u8, path, self.workspace.root_path) and path.len > self.workspace.root_path.len) path = std.mem.trimStart(u8, path[self.workspace.root_path.len..], "/");
    const pane: u8 = if (self.secondary != null and state == &self.secondary.?.editor) 1 else 0;
    var crumbs: std.ArrayList(ui.Element) = .empty;
    var segments = std.mem.splitScalar(u8, path, '/');
    while (segments.next()) |segment| {
        if (segment.len == 0) continue;
        if (crumbs.items.len > 0) try crumbs.append(b.allocator(), try v.icon(b, .chevron_right, c.muted, 10));
        const end = @intFromPtr(segment.ptr) - @intFromPtr(path.ptr) + segment.len;
        const label = try std.fmt.allocPrint(b.allocator(), "Reveal {s}", .{segment});
        try crumbs.append(b.allocator(), try b.button(.{ .label = label, .children = &.{try v.text(b, segment, c.muted, 12)}, .on_click = b.onClickWith(Shell.onBreadcrumb, Shell.Breadcrumb{ .document = document, .pane = pane, .prefix = if (record.path) |full| @intCast(@intFromPtr(path.ptr) - @intFromPtr(full.ptr) + end) else 0 }), .style = .{ .height = .{ .px = 24 }, .min_width = .{ .px = 0 }, .flex_shrink = 1, .align_items = .center, .padding = .{ .left = 2, .right = 2 }, .hover_background = c.hover, .radius = v.metrics.control_radius, .overflow = .hidden } }));
    }
    var children: std.ArrayList(ui.Element) = .empty;
    try children.append(b.allocator(), try b.row(.{ .flex_grow = 1, .min_width = .{ .px = 0 }, .gap = 2, .align_items = .center, .overflow = .hidden }, crumbs.items));
    try children.append(b.allocator(), try v.iconButton(b, c, .find, "Find", .search, false));
    if (@import("zircon_editor").syntax.languageForPath(record.path orelse "") == .markdown) try children.append(b.allocator(), try v.iconButton(b, c, .markdown_preview, "Preview", .markdown, self.panel == .markdown));
    try children.append(b.allocator(), try v.iconButton(b, c, .editor_options, "Editor options", .settings, self.popup == .editor));
    return b.key(.{ .string = "file-toolbar" }, try b.row(.{ .height = .{ .px = v.metrics.file_header }, .flex_shrink = 0, .padding = .{ .left = 13, .right = 7 }, .align_items = .center, .gap = 4, .background = c.document, .overflow = .hidden }, children.items));
}
pub fn statusbar(self: *const Shell, b: *ui.Ui) !ui.Element {
    const c = self.colors;
    var items: std.ArrayList(ui.Element) = .empty;
    try items.appendSlice(b.allocator(), &.{ try statusIcon(b, c, .project_files, "Project files", .folder, self.sidebar_visible and self.left_panel == .project), try statusIcon(b, c, .git_changes, "Git changes", .branch, self.sidebar_visible and self.left_panel == .git_changes) });
    try items.append(b.allocator(), try b.div(.{ .width = .{ .px = 1 }, .height = .{ .px = 14 }, .flex_shrink = 0, .background = c.line }, &.{}));
    try items.append(b.allocator(), try statusIcon(b, c, .project_search, "Project search", .search, self.currentTool(if (self.active_pane == .secondary) 1 else 0) == .search));
    var unhealthy = false;
    for (self.language.sessions.items) |session| {
        if (session.retired) continue;
        if (session.resolving or session.client == null or !session.client.?.ready()) unhealthy = true;
    }
    try items.append(b.allocator(), try b.button(.{ .label = "Language servers", .tooltip = "Language server status", .children = &.{ try v.icon(b, .language_server, c.muted, 14), try b.div(.{ .width = .{ .px = 5 }, .height = .{ .px = 5 }, .radius = 3, .background = if (self.language.activeSessions() == 0) c.muted else if (unhealthy) c.warning else c.added }, &.{}) }, .on_click = b.onClickWith(Shell.onCommand, @import("../commands.zig").Command.language_servers), .style = .{ .direction = .row, .width = .{ .px = 26 }, .height = .{ .px = 22 }, .align_items = .center, .justify_content = .center, .gap = 1 } }));
    var issues: usize = 0;
    for (self.language.documents.items) |doc| if (doc.diagnostics) |message| {
        issues += message.data.diagnostics.items.len;
    };
    try items.append(b.allocator(), try b.button(.{ .label = "Diagnostics", .tooltip = "Language server diagnostics", .children = if (issues == 0) &.{try v.icon(b, .check, c.muted, 13)} else &.{ try v.icon(b, .warning, c.warning, 13), try v.text(b, try std.fmt.allocPrint(b.allocator(), "{d}", .{issues}), c.warning, 11) }, .on_click = b.onClickWith(Shell.onCommand, @import("../commands.zig").Command.language_servers), .style = .{ .direction = .row, .height = .{ .px = 22 }, .align_items = .center, .gap = 3, .padding = .{ .left = 3, .right = 3 } } }));
    if (self.recovery) |recovery| {
        const previous = if (recovery.last_checkpoint) |at| try std.fmt.allocPrint(b.allocator(), "Last successful recovery checkpoint {d:.1} seconds ago.", .{@max(0, b.frame.time - at)}) else "No recovery checkpoint has completed in this session.";
        const tip = if (recovery.last_error) |err|
            try std.fmt.allocPrint(b.allocator(), "Recovery failed: {s}. {s} {s}", .{ @errorName(err), previous, if (recovery.store == null and !recovery.busy) "Resolve the storage error and restart the editor." else "Click to retry." })
        else
            try std.fmt.allocPrint(b.allocator(), "{s} {s}", .{ previous, if (recovery.busy) "Checkpoint in progress." else if (recovery.due != null) "New changes are waiting for a checkpoint." else "Click to checkpoint now." });
        try items.append(b.allocator(), try b.button(.{ .label = if (recovery.last_error != null) "Recovery failed" else "Recovery checkpoint", .tooltip = tip, .children = &.{try v.icon(b, if (recovery.last_error != null) .warning else .check, if (recovery.last_error != null) c.warning else c.muted, 13)}, .on_click = b.onClick(@import("../services/recovery.zig").checkpoint), .style = .{ .direction = .row, .width = .{ .px = 22 }, .height = .{ .px = 22 }, .flex_shrink = 0, .align_items = .center, .justify_content = .center } }));
    }
    if (self.status.len > 0) try items.append(b.allocator(), try b.styled(try v.text(b, self.status, if (self.status_is_error) c.warning else c.muted, 11), .{ .flex_shrink = 1, .min_width = .{ .px = 0 }, .max_width = .{ .percent = 35 }, .text = .{ .size = 11, .color = if (self.status_is_error) c.warning else c.muted }, .overflow = .hidden }));
    if (self.tab_drag) |drag| if (drag.moved) try items.append(b.allocator(), try v.text(b, "Drop on a tab strip or any editor edge · Esc cancels", c.muted, 11));
    try items.append(b.allocator(), try b.div(.{ .flex_grow = 1 }, &.{}));
    if (self.tabs.items.len > 0 and b.viewport().width >= 650) {
        const id = if (self.active_pane == .secondary and self.secondary != null) self.secondary.?.document else self.tabs.items[self.active].document;
        const state = if (self.active_pane == .secondary and self.secondary != null) &self.secondary.?.editor else &self.tabs.items[self.active].editor;
        var snapshot = try self.workspace.snapshot(id);
        defer snapshot.deinit();
        const point = try snapshot.pointAt(@min(state.primary().head, snapshot.byteLen()));
        const location = try std.fmt.allocPrint(b.allocator(), "{d}:{d}", .{ point.line + 1, point.byte_column + 1 });
        if (state.vim.enabled) try items.append(b.allocator(), try v.text(b, state.vim.label(), c.muted, 11));
        try items.append(b.allocator(), try v.text(b, location, c.muted, 11));
        const record = try self.workspace.getConst(if (self.active_pane == .secondary and self.secondary != null) self.secondary.?.document else self.tabs.items[self.active].document);
        const detected = if (self.extension_snapshot) |generation| generation.languageForPath(record.path orelse "") else null;
        const language = if (self.languageName(id)) |name| name else if (detected) |definition| definition.name else switch (state.language) {
            .plain => "Plain text",
            .zig => "Zig",
            .rust => "Rust",
            .json => "JSON",
            .markdown => "Markdown",
            .custom => "Extension",
        };
        try items.append(b.allocator(), try b.button(.{ .label = "Select language", .tooltip = "Select language", .children = &.{try v.text(b, language, c.muted, 11)}, .on_click = b.onClickWith(Shell.onCommand, @import("../commands.zig").Command.language_picker), .style = .{ .align_items = .center, .padding = .{ .left = 2, .right = 2 }, .radius = 3, .hover_background = c.hover } }));
    }
    try items.append(b.allocator(), try statusIcon(b, c, .toggle_terminal, "Terminal", .terminal, self.terminal.visible));
    return b.key(.{ .string = "status" }, try b.column(.{ .height = .{ .px = v.metrics.status }, .flex_shrink = 0, .background = c.chrome }, &.{ try v.rule(b, c), try b.row(.{ .flex_grow = 1, .align_items = .center, .gap = 4, .padding = .{ .left = 5, .right = 5 }, .overflow = .hidden }, items.items) }));
}
fn statusIcon(b: *ui.Ui, c: v.Palette, action: @import("../commands.zig").Command, label: []const u8, name: v.Icon, selected: bool) !ui.Element {
    return b.button(.{ .label = label, .tooltip = label, .tooltip_colors = .{ c.panel, c.text, c.line }, .children = &.{try v.icon(b, name, if (selected) c.accent else c.muted, 13)}, .on_click = b.onClickWith(Shell.onCommand, action), .style = .{ .width = .{ .px = 22 }, .height = .{ .px = 22 }, .flex_shrink = 0, .align_items = .center, .justify_content = .center } });
}
pub fn menu(self: *const Shell, b: *ui.Ui) !ui.Element {
    const c = self.colors;
    var items: std.ArrayList(ui.Element) = .empty;
    inline for (.{ .{ @import("../commands.zig").Command.open_project, "Open project…", "⇧⌘O" }, .{ @import("../commands.zig").Command.open_path, "Open file…", "⌘O" }, .{ @import("../commands.zig").Command.palette, "Command palette", "⇧⌘P" }, .{ @import("../commands.zig").Command.extensions, "Extensions", "" }, .{ @import("../commands.zig").Command.settings, "Settings", "⌘," } }) |entry| {
        try items.append(b.allocator(), try v.menuRow(b, c, entry[0], entry[1], try self.key_bindings.shortcut(b.allocator(), entry[0]), false));
    }
    try items.append(b.allocator(), try v.rule(b, c));
    try items.append(b.allocator(), try v.text(b, "Panel layout", c.muted, 11));
    try items.append(b.allocator(), try v.menuRow(b, c, .layout_classic, "Classic", if (!self.agent_mode) "✓" else "", false));
    try items.append(b.allocator(), try v.menuRow(b, c, .layout_agentic, "Agentic", if (self.agent_mode) "✓" else "", false));
    const placement = v.popoverBounds(b.viewport(), self.menu_anchor, .{ .width = 260, .height = 264 });
    const popup = try b.key(.{ .string = "workspace-menu" }, try v.floatingPanel(b, c, .{ .width = placement.width, .height = placement.height }, ui.Insets.all(5), 0, items.items));
    return b.modal(try b.listen(try b.stack(.{ .align_items = .start, .padding = .{ .top = placement.y, .left = placement.x } }, &.{popup}), .{ .on_input = b.onInput(Shell.onMenuInput) }));
}

pub fn splitMenu(self: *const Shell, b: *ui.Ui) !ui.Element {
    const catalogue = @import("../commands.zig");
    var rows: std.ArrayList(ui.Element) = .empty;
    inline for (.{ catalogue.Command.split_right, catalogue.Command.split_left, catalogue.Command.split_up, catalogue.Command.split_down, catalogue.Command.close_split }) |action| {
        const item = catalogue.entry(action);
        try rows.append(b.allocator(), try v.menuRow(b, self.colors, action, item.label, try self.key_bindings.shortcut(b.allocator(), action), false));
    }
    const placement = v.popoverBounds(b.viewport(), self.split_anchor, .{ .width = 260, .height = 160 });
    const popup = try b.key(.{ .string = "split-menu" }, try v.floatingPanel(b, self.colors, .{ .width = placement.width, .height = placement.height }, ui.Insets.all(5), 0, rows.items));
    return b.modal(try b.listen(try b.stack(.{ .align_items = .start, .padding = .{ .top = placement.y, .left = placement.x } }, &.{popup}), .{ .on_input = b.onInput(Shell.onMenuInput) }));
}
