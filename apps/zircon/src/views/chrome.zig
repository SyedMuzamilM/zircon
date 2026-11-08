//! Workspace chrome follows the reference's hierarchy: project/branch at the
//! top, file tabs and tools around the canvas, panel selectors in the status bar.
const std = @import("std");
const zircon_editor = @import("zircon_editor");
const ui = @import("zircon_ui");
const zircon_workspace = @import("zircon_workspace");
const commands_module = @import("../commands.zig");
const git_editing = @import("../git_editing.zig");
const panes = @import("../panes.zig");
const services_recovery = @import("../services/recovery.zig");
const shell = @import("../shell.zig");
const v = @import("components.zig");
const Shell = shell.Shell;
pub fn titlebar(self: *const Shell, b: *ui.Ui) !ui.Element {
    const c = self.colors;
    var items: std.ArrayList(ui.Element) = .empty;
    try items.append(b.allocator(), try b.fluent().div().w(.{ .px = 70 }).shrink_0().children(.{}).build());
    try items.append(b.allocator(), try b.fluent().button(.{ .label = "Open", .children = &.{ try v.text(b, std.fs.path.basename(self.workspace.root_path), c.text, 13), try v.icon(b, .chevron_down, c.muted, 12) }, .on_click = b.onClickWith(Shell.onCommand, commands_module.Command.recent_projects), .style = .{ .direction = .row, .height = .{ .px = 28 }, .gap = 6, .align_items = .center, .padding = .{ .left = 5, .right = 5 }, .radius = v.metrics.control_radius, .hover_background = c.hover, .flex_shrink = 1, .min_width = .{ .px = 0 }, .max_width = .{ .viewport_width = 40 }, .overflow = .hidden } }).build());
    if (self.git.status) |status| if (status.branch.len > 0) try items.append(b.allocator(), try b.fluent().button(.{ .label = "Branches and stashes", .children = &.{ try v.icon(b, .branch, c.muted, 14), try v.text(b, status.branch, c.muted, 12) }, .on_click = b.onClickWith(Shell.onCommand, commands_module.Command.git_branches), .style = .{ .direction = .row, .height = .{ .px = 28 }, .gap = 5, .align_items = .center, .padding = .{ .left = 5, .right = 5 }, .radius = v.metrics.control_radius, .hover_background = c.hover, .flex_shrink = 1, .overflow = .hidden } }).build());
    try items.append(b.allocator(), try b.fluent().div().grow().children(.{}).build());
    try items.append(b.allocator(), try v.iconButton(b, c, .agent_mode, "Agent workspace", .commands, self.agent_mode));
    try items.appendSlice(b.allocator(), &.{ try v.iconButton(b, c, .quick_open, "Go to file", .search, false), try v.iconButton(b, c, .workspace_menu, "Workspace menu", .more, self.menu_open) });
    const row = try b.fluent().div().h(.{ .px = v.metrics.titlebar - 1 }).shrink_0().items_center().gap_px(6).padding(.{ .left = 8, .right = 8 }).background(c.chrome).flex().children(items.items).id(.{ .string = "toolbar" }).drag_region().build();
    return b.fluent().div().h(.{ .px = v.metrics.titlebar }).shrink_0().flex_col().children(.{ row, v.rule(b, c) }).build();
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
        const title = try b.fluent().button(.{ .label = accessible, .tooltip = record.path orelse record.title(), .tooltip_colors = .{ c.panel, c.text, c.line }, .children = &.{ try v.fileGlyph(self, b, record.path orelse record.title(), false, false, 14), try v.text(b, record.title(), if (selected) c.text else c.muted, 13) }, .on_click = b.onClickWith(Shell.onTab, @as(u32, @intCast(index)) | mask), .style = .{ .direction = .row, .flex_grow = 1, .min_width = .{ .px = 0 }, .gap = 7, .align_items = .center, .padding = .{ .left = 11, .right = 6 }, .hover_background = null, .overflow = .hidden } }).listeners(.{ .on_input = b.onInputWith(Shell.onTabDrag, panes.DragTarget{ .document = tab.document, .pane = pane }) }).build();
        const close = try b.fluent().button(.{ .label = "Close tab", .tooltip = "Close tab", .tooltip_colors = .{ c.panel, c.text, c.line }, .children = &.{if (record.dirty()) try b.fluent().div().w(.{ .px = 5 }).h(.{ .px = 5 }).rounded_px(v.metrics.control_radius).background(c.muted).children(.{}).build() else try v.icon(b, .close, c.muted, 12)}, .on_click = b.onClickWith(Shell.onCloseTab, @as(u32, @intCast(index)) | mask), .style = .{ .width = .{ .px = 24 }, .flex_shrink = 0, .align_items = .center, .justify_content = .center, .hover_background = c.hover } }).id(.{ .string = "close" }).build();
        const measured = @min(@as(f32, 174), @max(@as(f32, 110), @as(f32, @floatFromInt(record.title().len)) * 7.2 + 57));
        try items.append(b.allocator(), try b.fluent().div().w(.{ .px = measured }).min_w(.{ .px = 90 }).shrink_by(1).background(background).flex_col().children(&.{ try b.fluent().div().grow().flex().children(&.{ title, close, try b.fluent().div().w(.{ .px = 1 }).shrink_0().background(c.line).children(.{}).build() }).build(), try b.fluent().div().h(.{ .px = 1 }).background(if (selected) c.document else c.line).shrink_0().children(.{}).build() }).id(.{ .number = panes.key(tab.document) }).build());
    }
    var shown_tools: usize = 0;
    inline for (.{ Shell.Tool.search, Shell.Tool.git_diff, Shell.Tool.extensions }) |tool| {
        const selected = active_tool == tool and (tool != .git_diff or self.git.selected_commit.len == 0);
        const opened = switch (tool) {
            .search => opened_tools.search,
            .git_diff => opened_tools.git_diff,
            .extensions => opened_tools.extensions,
        };
        if ((opened or selected) and (width >= 520 or selected or (active_tool == null and shown_tools == 0))) {
            shown_tools += 1;
            const name: []const u8 = switch (tool) {
                .search => "Project search",
                .git_diff => if (self.git.stash_view) "Stash changes" else "Uncommitted changes",
                .extensions => "Extensions",
            };
            const glyph: v.Icon = switch (tool) {
                .search => .search,
                .git_diff => .branch,
                .extensions => .extension,
            };
            const title = try b.fluent().button(.{ .label = name, .children = &.{ try v.icon(b, glyph, if (selected) c.accent else c.muted, 14), try b.fluent().adopt(try v.text(b, name, if (selected) c.text else c.muted, 13)).style(.{ .flex_shrink = 1, .min_width = .{ .px = 0 }, .text = .{ .size = 13, .color = if (selected) c.text else c.muted }, .overflow = .hidden }).build() }, .on_click = b.onClickWith(Shell.onToolTab, Shell.ToolTab{ .tool = tool, .pane = pane }), .style = .{ .direction = .row, .flex_grow = 1, .min_width = .{ .px = 0 }, .align_items = .center, .gap = 7, .padding = .{ .left = 10 }, .hover_background = null, .overflow = .hidden } }).build();
            var close_style = v.iconButtonStyle(c, false);
            close_style.width = .{ .px = 22 };
            const close = try b.fluent().button(.{ .label = "Close view", .tooltip = "Close view", .tooltip_colors = .{ c.panel, c.text, c.line }, .children = &.{try v.icon(b, .close, c.muted, 12)}, .on_click = b.onClickWith(Shell.onCloseTool, Shell.ToolTab{ .tool = tool, .pane = pane }), .style = close_style }).build();
            try items.append(b.allocator(), try b.fluent().div().h(.{ .px = v.metrics.tabs }).min_w(.{ .px = if (selected) @as(f32, 100) else 60 }).max_w(.{ .px = 210 }).shrink_by(1).grow_by(0).background(if (selected) c.document else c.tab_bar).items_center().flex().children(.{ title, close }).id(.{ .string = @tagName(tool) }).build());
        }
    }
    for (self.git.history_tabs.items, 0..) |history, index| {
        if (history.pane != pane) continue;
        const selected = active_tool == .git_diff and std.mem.eql(u8, history.oid, self.git.selected_commit);
        const name = try std.fmt.allocPrint(b.allocator(), "{s} — {s}", .{ history.oid[0..@min(7, history.oid.len)], history.subject });
        const title = try b.fluent().button(.{ .label = name, .tooltip = history.subject, .children = &.{ try v.icon(b, .commit, if (selected) c.accent else c.muted, 14), try v.text(b, name, if (selected) c.text else c.muted, 12) }, .on_click = b.onClickWith(Shell.onGitHistoryTab, @as(u32, @intCast(index))), .style = .{ .direction = .row, .flex_grow = 1, .min_width = .{ .px = 0 }, .align_items = .center, .gap = 7, .padding = .{ .left = 10 }, .overflow = .hidden } }).build();
        const close = try b.fluent().button(.{ .label = try std.fmt.allocPrint(b.allocator(), "Close commit {s}", .{history.oid}), .children = &.{try v.icon(b, .close, c.muted, 12)}, .on_click = b.onClickWith(Shell.onCloseHistoryTab, @as(u32, @intCast(index))), .style = .{ .width = .{ .px = 22 }, .flex_shrink = 0, .align_items = .center, .justify_content = .center, .hover_background = c.hover } }).build();
        try items.append(b.allocator(), try b.fluent().div().h(.{ .px = v.metrics.tabs }).w(.{ .px = 210 }).min_w(.{ .px = 85 }).shrink_by(1).background(if (selected) c.document else c.tab_bar).overflow_hidden().flex().children(.{ title, close }).id(.{ .string = try std.fmt.allocPrint(b.allocator(), "commit-tab:{s}", .{history.oid}) }).build());
    }
    if (pane == 0) if (self.image) |asset| {
        try items.append(b.allocator(), try b.fluent().div().h(.{ .px = v.metrics.tabs }).max_w(.{ .px = 220 }).min_w(.{ .px = 90 }).shrink_by(1).background(if (self.panel == .image) c.document else c.tab_bar).flex().children(.{ b.fluent().button(.{ .label = std.fs.path.basename(asset.path), .tooltip = asset.path, .children = &.{ try v.icon(b, .image, c.muted, 14), try v.text(b, std.fs.path.basename(asset.path), c.text, 13) }, .on_click = b.onClickWith(Shell.onCommand, commands_module.Command.show_image), .style = .{ .direction = .row, .flex_grow = 1, .min_width = .{ .px = 0 }, .align_items = .center, .gap = 7, .padding = .{ .left = 11, .right = 6 }, .overflow = .hidden } }), v.iconButton(b, c, .close_image, "Close image", .close, false) }).build());
    };
    try items.append(b.allocator(), try b.fluent().div().grow().flex_col().children(&.{ try b.fluent().div().grow().children(.{}).build(), try v.rule(b, c) }).build());
    try items.appendSlice(b.allocator(), &.{ try v.iconButton(b, c, .new_file, "New file", .plus, false), try v.iconButton(b, c, .split_menu, "Split editor", .split, self.split_menu_open) });
    return b.fluent().div().h(.{ .px = v.metrics.tabs }).shrink_0().background(c.tab_bar).overflow_hidden().padding(.{ .right = 4 }).flex().children(items.items).id(.{ .string = if (pane == 0) "tabs" else "secondary-tabs" }).build();
}
fn navigation(self: *const Shell, b: *ui.Ui, index: ?usize, key: []const u8, name: v.Icon) !ui.Element {
    const c = self.colors;
    var color = c.muted;
    if (index == null) color.a = 0.4;
    return b.fluent().button(.{ .label = key, .tooltip = if (name == .chevron_left) "Previous tab" else "Next tab", .tooltip_colors = .{ c.panel, c.text, c.line }, .children = &.{try v.icon(b, name, color, 14)}, .on_click = if (index) |target| try b.onClickWith(Shell.onTab, @as(u32, @intCast(target))) else null, .style = .{ .width = .{ .px = 26 }, .flex_shrink = 0, .align_items = .center, .justify_content = .center, .hover_background = if (index != null) c.hover else null } }).id(.{ .string = key }).build();
}
pub fn fileHeader(self: *const Shell, b: *ui.Ui, record: *const zircon_workspace.Record, document: zircon_workspace.DocumentId, state: *const zircon_editor.Editor) !ui.Element {
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
        try crumbs.append(b.allocator(), try b.fluent().button(.{ .label = label, .children = &.{try v.text(b, segment, c.muted, 12)}, .on_click = b.onClickWith(Shell.onBreadcrumb, Shell.Breadcrumb{ .document = document, .pane = pane, .prefix = if (record.path) |full| @intCast(@intFromPtr(path.ptr) - @intFromPtr(full.ptr) + end) else 0 }), .style = .{ .height = .{ .px = 24 }, .min_width = .{ .px = 0 }, .flex_shrink = 1, .align_items = .center, .padding = .{ .left = 2, .right = 2 }, .hover_background = c.hover, .radius = v.metrics.control_radius, .overflow = .hidden } }).build());
    }
    var children: std.ArrayList(ui.Element) = .empty;
    try children.append(b.allocator(), try b.fluent().div().grow().min_w(.{ .px = 0 }).gap_px(2).items_center().overflow_hidden().flex().children(crumbs.items).build());
    try children.append(b.allocator(), try v.iconButton(b, c, .find, "Find", .search, false));
    if (zircon_editor.syntax.languageForPath(record.path orelse "") == .markdown) try children.append(b.allocator(), try v.iconButton(b, c, .markdown_preview, "Preview", .markdown, self.panel == .markdown));
    try children.append(b.allocator(), try v.iconButton(b, c, .editor_options, "Editor options", .settings, self.popup == .editor));
    return b.fluent().div().h(.{ .px = v.metrics.file_header }).shrink_0().padding(.{ .left = 13, .right = 7 }).items_center().gap_px(4).background(c.document).overflow_hidden().flex().children(children.items).id(.{ .string = "file-toolbar" }).build();
}
pub fn statusbar(self: *const Shell, b: *ui.Ui) !ui.Element {
    const c = self.colors;
    var items: std.ArrayList(ui.Element) = .empty;
    try items.appendSlice(b.allocator(), &.{ try statusIcon(b, c, .project_files, "Project files", .folder, self.sidebar_visible and self.left_panel == .project), try statusIcon(b, c, .git_changes, "Git changes", .branch, self.sidebar_visible and self.left_panel == .git_changes) });
    try items.append(b.allocator(), try b.fluent().div().w(.{ .px = 1 }).h(.{ .px = 14 }).shrink_0().background(c.line).children(.{}).build());
    try items.append(b.allocator(), try statusIcon(b, c, .project_search, "Project search", .search, self.currentTool(if (self.active_pane == .secondary) 1 else 0) == .search));
    var unhealthy = false;
    for (self.language.sessions.items) |session| {
        if (session.retired) continue;
        if (session.resolving or session.client == null or !session.client.?.ready()) unhealthy = true;
    }
    try items.append(b.allocator(), try b.fluent().button(.{ .label = "Language servers", .tooltip = "Language server status", .children = &.{ try v.icon(b, .language_server, c.muted, 14), try b.fluent().div().w(.{ .px = 5 }).h(.{ .px = 5 }).rounded_px(3).background(if (self.language.activeSessions() == 0) c.muted else if (unhealthy) c.warning else c.added).children(.{}).build() }, .on_click = b.onClickWith(Shell.onCommand, commands_module.Command.language_servers), .style = .{ .direction = .row, .width = .{ .px = 26 }, .height = .{ .px = 22 }, .align_items = .center, .justify_content = .center, .gap = 1 } }).build());
    var issues: usize = 0;
    for (self.language.documents.items) |doc| if (doc.diagnostics) |message| {
        issues += message.data.diagnostics.items.len;
    };
    try items.append(b.allocator(), try b.fluent().button(.{ .label = "Diagnostics", .tooltip = "Language server diagnostics", .children = if (issues == 0) &.{try v.icon(b, .check, c.muted, 13)} else &.{ try v.icon(b, .warning, c.warning, 13), try v.text(b, try std.fmt.allocPrint(b.allocator(), "{d}", .{issues}), c.warning, 11) }, .on_click = b.onClickWith(Shell.onCommand, commands_module.Command.language_servers), .style = .{ .direction = .row, .height = .{ .px = 22 }, .align_items = .center, .gap = 3, .padding = .{ .left = 3, .right = 3 } } }).build());
    if (self.recovery) |recovery| {
        const previous = if (recovery.last_checkpoint) |at| try std.fmt.allocPrint(b.allocator(), "Last successful recovery checkpoint {d:.1} seconds ago.", .{@max(0, b.frame.time - at)}) else "No recovery checkpoint has completed in this session.";
        const tip = if (recovery.last_error) |err|
            try std.fmt.allocPrint(b.allocator(), "Recovery failed: {s}. {s} {s}", .{ @errorName(err), previous, if (recovery.store == null and !recovery.busy) "Resolve the storage error and restart the editor." else "Click to retry." })
        else
            try std.fmt.allocPrint(b.allocator(), "{s} {s}", .{ previous, if (recovery.busy) "Checkpoint in progress." else if (recovery.due != null) "New changes are waiting for a checkpoint." else "Click to checkpoint now." });
        try items.append(b.allocator(), try b.fluent().button(.{ .label = if (recovery.last_error != null) "Recovery failed" else "Recovery checkpoint", .tooltip = tip, .children = &.{try v.icon(b, if (recovery.last_error != null) .warning else .check, if (recovery.last_error != null) c.warning else c.muted, 13)}, .on_click = b.onClick(services_recovery.checkpoint), .style = .{ .direction = .row, .width = .{ .px = 22 }, .height = .{ .px = 22 }, .flex_shrink = 0, .align_items = .center, .justify_content = .center } }).build());
    }
    if (self.status.len > 0) try items.append(b.allocator(), try b.fluent().adopt(try v.text(b, self.status, if (self.status_is_error) c.warning else c.muted, 11)).style(.{ .flex_shrink = 1, .min_width = .{ .px = 0 }, .max_width = .{ .percent = 35 }, .text = .{ .size = 11, .color = if (self.status_is_error) c.warning else c.muted }, .overflow = .hidden }).build());
    if (self.tab_drag) |drag| if (drag.moved) try items.append(b.allocator(), try v.text(b, "Drop on a tab strip or any editor edge · Esc cancels", c.muted, 11));
    try items.append(b.allocator(), try b.fluent().div().grow().children(.{}).build());
    if (self.tabs.items.len > 0 and b.viewport().width >= 650) {
        const diff_view = if (git_editing.active(self)) self.git.editing.current() else null;
        const id = if (diff_view) |view| view.document else if (self.active_pane == .secondary and self.secondary != null) self.secondary.?.document else self.tabs.items[self.active].document;
        const state = if (diff_view) |view| &view.editor else if (self.active_pane == .secondary and self.secondary != null) &self.secondary.?.editor else &self.tabs.items[self.active].editor;
        var snapshot = try self.workspace.snapshot(id);
        defer snapshot.deinit();
        const point = try snapshot.pointAt(@min(state.primary().head, snapshot.byteLen()));
        const location = try std.fmt.allocPrint(b.allocator(), "{d}:{d}", .{ point.line + 1, point.byte_column + 1 });
        if (state.vim.enabled) {
            try items.append(b.allocator(), try v.text(b, try std.fmt.allocPrint(b.allocator(), "-- {s} --", .{state.vim.label()}), c.muted, 11));
            const pending = state.vim.pendingKeys();
            if (pending.len > 0) try items.append(b.allocator(), try v.text(b, try std.fmt.allocPrint(b.allocator(), "[{s}]", .{pending}), c.accent, 11));
        }
        try items.append(b.allocator(), try v.text(b, location, c.muted, 11));
        const record = try self.workspace.getConst(id);
        const detected = if (self.extension_snapshot) |generation| generation.languageForPath(record.path orelse "") else null;
        const language = if (self.languageName(id)) |name| name else if (detected) |definition| definition.name else switch (state.language) {
            .plain => "Plain text",
            .zig => "Zig",
            .rust => "Rust",
            .json => "JSON",
            .markdown => "Markdown",
            .custom => "Extension",
        };
        try items.append(b.allocator(), try b.fluent().button(.{ .label = "Select language", .tooltip = "Select language", .children = &.{try v.text(b, language, c.muted, 11)}, .on_click = b.onClickWith(Shell.onCommand, commands_module.Command.language_picker), .style = .{ .align_items = .center, .padding = .{ .left = 2, .right = 2 }, .radius = 3, .hover_background = c.hover } }).build());
    }
    try items.append(b.allocator(), try statusIcon(b, c, .toggle_terminal, "Terminal", .terminal, self.terminal.visible));
    return b.fluent().div().h(.{ .px = v.metrics.status }).shrink_0().background(c.chrome).flex_col().children(.{ v.rule(b, c), b.fluent().div().grow().items_center().gap_px(4).padding(.{ .left = 5, .right = 5 }).overflow_hidden().flex().children(items.items) }).id(.{ .string = "status" }).build();
}
fn statusIcon(b: *ui.Ui, c: v.Palette, action: commands_module.Command, label: []const u8, name: v.Icon, selected: bool) !ui.Element {
    return b.fluent().button(.{ .label = label, .tooltip = label, .tooltip_colors = .{ c.panel, c.text, c.line }, .children = &.{try v.icon(b, name, if (selected) c.accent else c.muted, 13)}, .on_click = b.onClickWith(Shell.onCommand, action), .style = .{ .width = .{ .px = 22 }, .height = .{ .px = 22 }, .flex_shrink = 0, .align_items = .center, .justify_content = .center } }).build();
}
pub fn menu(self: *const Shell, b: *ui.Ui) !ui.Element {
    const c = self.colors;
    var items: std.ArrayList(ui.Element) = .empty;
    inline for (.{ .{ commands_module.Command.open_project, "Open project…", "⇧⌘O" }, .{ commands_module.Command.open_path, "Open file…", "⌘O" }, .{ commands_module.Command.palette, "Command palette", "⇧⌘P" }, .{ commands_module.Command.extensions, "Extensions", "" }, .{ commands_module.Command.settings, "Settings", "⌘," } }) |entry| {
        try items.append(b.allocator(), try v.menuRow(b, c, entry[0], entry[1], try self.key_bindings.shortcut(b.allocator(), entry[0]), false));
    }
    try items.append(b.allocator(), try v.rule(b, c));
    try items.append(b.allocator(), try v.text(b, "Panel layout", c.muted, 11));
    try items.append(b.allocator(), try v.menuRow(b, c, .layout_classic, "Classic", if (!self.agent_mode) "✓" else "", false));
    try items.append(b.allocator(), try v.menuRow(b, c, .layout_agentic, "Agentic", if (self.agent_mode) "✓" else "", false));
    const placement = v.popoverBounds(b.viewport(), self.menu_anchor, .{ .width = 260, .height = 264 });
    const popup = try b.fluent().adopt(try v.floatingPanel(b, c, .{ .width = placement.width, .height = placement.height }, ui.Insets.all(5), 0, items.items)).id(.{ .string = "workspace-menu" }).build();
    return b.fluent().div().items(.start).padding(.{ .top = placement.y, .left = placement.x }).stack().children(.{popup}).listeners(.{ .on_input = b.onInput(Shell.onMenuInput) }).modal().build();
}

pub fn splitMenu(self: *const Shell, b: *ui.Ui) !ui.Element {
    const catalogue = commands_module;
    var rows: std.ArrayList(ui.Element) = .empty;
    inline for (.{ catalogue.Command.split_right, catalogue.Command.split_left, catalogue.Command.split_up, catalogue.Command.split_down, catalogue.Command.close_split }) |action| {
        const item = catalogue.entry(action);
        try rows.append(b.allocator(), try v.menuRow(b, self.colors, action, item.label, try self.key_bindings.shortcut(b.allocator(), action), false));
    }
    const placement = v.popoverBounds(b.viewport(), self.split_anchor, .{ .width = 260, .height = 160 });
    const popup = try b.fluent().adopt(try v.floatingPanel(b, self.colors, .{ .width = placement.width, .height = placement.height }, ui.Insets.all(5), 0, rows.items)).id(.{ .string = "split-menu" }).build();
    return b.fluent().div().items(.start).padding(.{ .top = placement.y, .left = placement.x }).stack().children(.{popup}).listeners(.{ .on_input = b.onInput(Shell.onMenuInput) }).modal().build();
}
