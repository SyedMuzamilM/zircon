//! Declarative application chrome. Every button invokes a real Shell command;
//! editor drawing and editing remain in zircon_editor's custom canvas.
const std = @import("std");
const zircon_editor = @import("zircon_editor");
const ui = @import("zircon_ui");
const workspace = @import("zircon_workspace");
const catalogue = @import("commands.zig");
const services_language = @import("services/language.zig");
const recovery = @import("services/recovery.zig");
const shell = @import("shell.zig");
const terminal_module = @import("terminal.zig");
const theme = @import("theme.zig");
const buffer_find = @import("views/buffer_find.zig");
const chrome = @import("views/chrome.zig");
const components = @import("views/components.zig");
const views_extensions = @import("views/extensions.zig");
const git_controls = @import("views/git_controls.zig");
const views_git_diff = @import("views/git_diff.zig");
const views_image = @import("views/image.zig");
const views_open_project = @import("views/open_project.zig");
const project = @import("views/project.zig");
const views_search = @import("views/search.zig");
const workspace_controls = @import("views/workspace_controls.zig");
const Shell = shell.Shell;
const Command = catalogue.Command;
const Palette = theme.Palette;
const toolbar_height = components.metrics.titlebar;
const tab_height = components.metrics.tabs;
const status_height = components.metrics.status;
const result_limit = 12;

pub fn render(self: *const Shell, b: *ui.Ui) !ui.Element {
    try recovery.schedule(self, b);
    try b.requestFrameAfter(@max(0.001, self.project_watch.next_check - b.frame.time));
    b.frame.tooltips_enabled = self.tooltips;
    b.frame.tooltip_delay = self.tooltip_delay / 1000;
    const colors = self.colors;
    const viewport = b.viewport();
    const sidebar_visible = self.sidebar_visible and viewport.width >= 600;
    const sidebar_width = if (sidebar_visible) @min(self.panelWidth(), @max(140, viewport.width * 0.4)) else 0;
    const editor_width = @max(100, viewport.width - sidebar_width - if (sidebar_visible) @as(f32, 5) else 0);
    var body_children: std.ArrayList(ui.Element) = .empty;
    if (sidebar_visible) {
        try body_children.append(b.allocator(), try sidebar(self, b, sidebar_width, viewport.height));
        try body_children.append(b.allocator(), try divider(b, colors, 0, false));
    }
    try body_children.append(b.allocator(), try editorArea(self, b, editor_width));
    const main = try b.fluent().div().grow().min_h(.{ .px = 0 }).overflow_hidden().flex().children(body_children.items).id(.{ .string = "main" }).build();
    const base = try b.fluent().div().background(colors.document).overflow_hidden().flex_col().children(.{ toolbar(self, b), main, statusBar(self, b) }).id(.{ .string = "workspace" }).build();
    var layers: std.ArrayList(ui.Element) = .empty;
    try layers.append(b.allocator(), base);
    if (self.terminal.sessions.items.len > 0) try layers.append(b.allocator(), try terminal_module.wakeElement(b));
    if (self.find.waiting and !self.find.busy) try layers.append(b.allocator(), try services_language.syntaxWake(b));
    if (self.language.syntax_waiting) try layers.append(b.allocator(), try services_language.syntaxWake(b));
    if (self.git.menu != .none) try layers.append(b.allocator(), try git_controls.render(self, b));
    if (self.split_menu_open) try layers.append(b.allocator(), try chrome.splitMenu(self, b));
    if (self.popup != .none) try layers.append(b.allocator(), try workspace_controls.render(self, b));
    if (self.menu_open) try layers.append(b.allocator(), try chrome.menu(self, b));
    if (self.overlay != .none and self.fields != null) try layers.append(b.allocator(), try overlay(self, b));
    if (self.overlay == .none) if (self.language.completions) |message| {
        var choices: std.ArrayList(ui.Element) = .empty;
        const start = self.language.completion_index -| 7;
        for (message.data.completion.items[start..@min(start + 8, message.data.completion.items.len)], start..) |item, index| {
            try choices.append(b.allocator(), try b.fluent().button(.{ .label = item.label, .on_click = b.onClickWith(Shell.onCompletion, @as(u32, @intCast(index))), .style = .{ .height = .{ .px = 30 }, .flex_shrink = 0, .padding = .{ .left = 12, .top = 7 }, .background = if (index == self.language.completion_index) colors.selected else colors.panel, .text = .{ .size = 13, .mono = true, .color = colors.text }, .overflow = .hidden } }).id(.{ .number = @intCast(index) }).build());
        }
        if (choices.items.len == 0) try choices.append(b.allocator(), try label(b, colors, "No completions", colors.muted, 12));
        const requested: ui.Size = .{ .width = @min(420, viewport.width - 24), .height = @as(f32, @floatFromInt(@max(1, choices.items.len))) * 30 + 12 };
        var anchor: ui.Rect = .{ .x = if (self.sidebar_visible) self.panelWidth() + 60 else 60, .y = 100, .height = 22 };
        if (self.window) |handle| if (b.frame.app) |app| {
            if ((try app.window(handle)).frames.committed.text_input) |input| anchor = input.caret;
        };
        anchor.width = requested.width;
        const placement = components.popoverBounds(viewport, anchor, requested);
        const popup = try b.fluent().adopt(try components.floatingPanel(b, colors, .{ .width = placement.width, .height = placement.height }, ui.Insets.all(6), 0, choices.items)).id(.{ .string = "completion-list" }).build();
        try layers.append(b.allocator(), try b.fluent().div().padding(.{ .top = placement.y, .left = placement.x }).stack().children(.{popup}).build());
    };
    return b.fluent().div().background(colors.document).overflow_hidden().stack().children(layers.items).id(.{ .string = "zircon" }).listeners(.{ .on_capture = b.onInput(Shell.onGlobal), .on_input = b.onInput(Shell.onRoot) }).build();
}

fn toolbar(self: *const Shell, b: *ui.Ui) !ui.Element {
    return chrome.titlebar(self, b);
}
fn sidebar(self: *const Shell, b: *ui.Ui, width: f32, height: f32) !ui.Element {
    return project.render(self, b, width, height);
}

pub fn editorArea(self: *const Shell, b: *ui.Ui, width: f32) !ui.Element {
    if (!self.terminal.visible or self.terminal.sessions.items.len == 0) return editorContent(self, b, width);
    const available_height = @max(80, b.viewport().height - toolbar_height - status_height);
    const right = self.terminal.dock == .right;
    const terminal_width = if (right) @max(100, width * self.terminal.ratio) else width;
    const terminal_height = if (right) available_height else @max(60, available_height * self.terminal.ratio);
    const source = try editorContent(self, b, if (right) @max(100, width - terminal_width - 5) else width);
    const terminal = try terminal_module.render(self, b, terminal_width, terminal_height);
    return b.fluent().div().direction(if (right) .row else .column).grow().min_w(.{ .px = 0 }).min_h(.{ .px = 0 }).overflow_hidden().children(&.{ source, try b.fluent().div().w(if (right) .{ .px = 5 } else .auto).h(if (right) .auto else .{ .px = 5 }).shrink_0().background(self.colors.line).hover_background(self.colors.hover).children(.{}).id(.{ .string = "terminal-divider" }).listeners(.{ .on_input = b.onInput(terminal_module.onDivider) }).build(), terminal }).build();
}
fn editorContent(self: *const Shell, b: *ui.Ui, width: f32) !ui.Element {
    const colors = self.colors;
    if (self.panel != .editor and self.panel != .markdown and self.secondary == null) {
        const panel = switch (self.panel) {
            .image => try views_image.render(self, b),
            .extensions => try views_extensions.render(self, b),
            .search => try views_search.render(self, b),
            .git_diff => try views_git_diff.render(self, b),
            else => unreachable,
        };
        return b.fluent().div().grow().min_w(.{ .px = 0 }).background(colors.document).overflow_hidden().flex_col().children(.{ tabs(self, b, width), panel }).id(.{ .string = "editor-area" }).build();
    }
    var children: std.ArrayList(ui.Element) = .empty;
    if (self.tabs.items.len == 0) {
        try children.append(b.allocator(), try tabs(self, b, width));
        try children.append(b.allocator(), try emptyEditor(b, colors));
    } else {
        var panes: std.ArrayList(ui.Element) = .empty;
        const preview_visible = self.panel == .markdown and self.preview != null and std.meta.eql(self.preview.?.document, self.tabs.items[self.active].document);
        const split_visible = self.secondary != null or preview_visible;
        const available = @max(1, width - if (split_visible) @as(f32, 5) else 0);
        const vertical = self.secondary != null and self.split_vertical and !preview_visible;
        const primary_width = if (split_visible and !vertical) available * std.math.clamp(self.split_ratio, 0.2, 0.8) else width;
        const primary_height: ui.Length = if (vertical) .{ .px = @max(1, b.viewport().height - toolbar_height - status_height - 5 - (if (self.terminal.visible and self.terminal.dock == .bottom) (b.viewport().height - toolbar_height - status_height) * self.terminal.ratio else 0)) * self.split_ratio } else .auto;
        const tab = &self.tabs.items[@min(self.active, self.tabs.items.len - 1)];
        const primary_record = try self.workspace.getConst(tab.document);
        const primary_source = self.panel == .editor or self.panel == .markdown;
        var primary = if (primary_source) try tab.editor.render(&primary_record.doc, b) else try panelBody(self, b, self.currentTool(0));
        primary = try b.fluent().adopt(primary).style(.{ .width = .{ .px = primary_width }, .flex_grow = 1, .min_height = .{ .px = 0 }, .min_width = .{ .px = 0 }, .overflow = .hidden }).build();
        if (primary_source) primary = try b.fluent().adopt(primary).id(.{ .string = "primary-editor" }).listeners(.{ .focusable = true, .on_input = b.onInputWith(Shell.onEditor, @as(u8, 0)) }).build();
        if (self.currentTool(0) == .git_diff) primary = try b.fluent().adopt(primary).id(.{ .string = "primary-tool" }).listeners(.{ .focusable = true }).request_focus(if (self.active_pane == .primary) self.editor_focus_request else 0).build();
        if (primary_source) primary = try b.fluent().adopt(try b.fluent().adopt(primary).autofocus().build()).request_focus(if (self.active_pane == .primary) self.editor_focus_request else 0).build();
        try panes.append(b.allocator(), try b.fluent().div().w(.{ .px = primary_width }).h(primary_height).grow_by(if (!split_visible) 1 else 0).shrink_0().min_w(.{ .px = 0 }).overflow_hidden().flex_col().children(try paneChildren(self, b, primary_record, tab.document, &tab.editor, primary, 0, primary_width)).id(.{ .string = "primary-pane" }).listeners(.{ .on_capture = b.onInputWith(Shell.onPaneInput, @as(u8, 0)) }).build());
        if (preview_visible) {
            try panes.append(b.allocator(), try divider(b, colors, 1, false));
            const preview = try b.fluent().adopt(try self.preview.?.view.render(b)).id(.{ .string = "markdown-preview" }).listeners(.{ .focusable = true, .on_input = b.onInput(Shell.onPreview) }).build();
            try panes.append(b.allocator(), try b.fluent().div().grow().min_w(.{ .px = 0 }).overflow_hidden().flex_col().children(&.{ try b.fluent().div().h(.{ .px = 30 }).shrink_0().padding(.{ .left = 12, .right = 8 }).items_center().gap_px(8).background(colors.document).flex().children(.{ b.fluent().adopt(try label(b, colors, "Markdown preview", colors.muted, 12)).style(.{ .flex_grow = 1, .text = .{ .size = 12, .color = colors.muted } }), commandButton(b, colors, .back_to_editor, "Close", false) }).build(), preview }).build());
        } else if (self.secondary) |*secondary| {
            try panes.append(b.allocator(), try divider(b, colors, 1, vertical));
            const record = try self.workspace.getConst(secondary.document);
            const secondary_source = self.secondary_tool == null;
            var secondary_canvas = if (secondary_source) try secondary.editor.render(&record.doc, b) else try panelBody(self, b, self.secondary_tool);
            secondary_canvas = try b.fluent().adopt(secondary_canvas).style(.{ .flex_grow = 1, .min_width = .{ .px = 0 }, .overflow = .hidden }).build();
            if (secondary_source) secondary_canvas = try b.fluent().adopt(secondary_canvas).id(.{ .string = "secondary-editor" }).listeners(.{ .focusable = true, .on_input = b.onInputWith(Shell.onEditor, @as(u8, 1)) }).build();
            if (self.secondary_tool == .git_diff) secondary_canvas = try b.fluent().adopt(secondary_canvas).id(.{ .string = "secondary-tool" }).listeners(.{ .focusable = true }).request_focus(if (self.active_pane == .secondary) self.editor_focus_request else 0).build();
            if (secondary_source) secondary_canvas = try b.fluent().adopt(secondary_canvas).request_focus(if (self.active_pane == .secondary) self.editor_focus_request else 0).build();
            try panes.append(b.allocator(), try b.fluent().div().grow().min_w(.{ .px = 0 }).overflow_hidden().flex_col().children(try paneChildren(self, b, record, secondary.document, &secondary.editor, secondary_canvas, 1, if (vertical) width else available - primary_width)).id(.{ .string = "secondary-pane" }).listeners(.{ .on_capture = b.onInputWith(Shell.onPaneInput, @as(u8, 1)) }).build());
        }
        if (self.secondary != null and self.split_reverse and !preview_visible) std.mem.swap(ui.Element, &panes.items[0], &panes.items[2]);
        try children.append(b.allocator(), try b.fluent().div().direction(if (vertical) .column else .row).grow().min_h(.{ .px = 0 }).overflow_hidden().children(panes.items).id(.{ .string = "panes" }).build());
        const active_id = if (self.active_pane == .secondary and self.secondary != null) self.secondary.?.document else tab.document;
        for (self.language.documents.items) |document| if (std.meta.eql(document.id, active_id)) {
            const message = document.diagnostics orelse break;
            const record = try self.workspace.getConst(active_id);
            if (message.data.diagnostics.version != record.doc.revision()) break;
            for (message.data.diagnostics.items[0..@min(4, message.data.diagnostics.items.len)], 0..) |diagnostic, index| try children.append(b.allocator(), try b.fluent().button(.{ .label = try std.fmt.allocPrint(b.allocator(), "{s}  {d}:{d}  {s}", .{ switch (diagnostic.severity) {
                .error_value => "Error",
                .warning => "Warning",
                .information => "Information",
                .hint => "Hint",
            }, diagnostic.range.start.line + 1, diagnostic.range.start.character + 1, diagnostic.message }), .on_click = b.onClickWith(Shell.onDiagnostic, @as(u32, @intCast(index))), .style = .{ .height = .{ .px = 28 }, .flex_shrink = 0, .padding = .{ .left = 14, .top = 6 }, .background = colors.panel, .text = .{ .size = 12, .color = colors.warning }, .overflow = .hidden } }).id(.{ .number = @intCast(index) }).build());
            break;
        };
    }
    return b.fluent().div().grow().min_w(.{ .px = 0 }).background(colors.document).overflow_hidden().flex_col().children(children.items).id(.{ .string = "editor-area" }).build();
}
fn panelBody(self: *const Shell, b: *ui.Ui, tool: ?Shell.Tool) !ui.Element {
    if (tool) |which| return switch (which) {
        .git_diff => views_git_diff.render(self, b),
        .search => views_search.render(self, b),
        .extensions => views_extensions.render(self, b),
    };
    return views_image.render(self, b);
}
fn paneChildren(self: *const Shell, b: *ui.Ui, record: *const workspace.Record, document: workspace.DocumentId, state: *const zircon_editor.Editor, canvas: ui.Element, pane: u8, pane_width: f32) ![]const ui.Element {
    var children: std.ArrayList(ui.Element) = .empty;

    try children.append(b.allocator(), try chrome.tabsForPane(self, b, pane_width, pane));
    const source = self.currentTool(pane) == null and (pane == 1 or self.panel == .editor or self.panel == .markdown);
    if (source) try children.append(b.allocator(), try fileHeading(self, b, record, document, state));
    if (source and self.find.visible and self.find.pane == pane and self.find.document != null and std.meta.eql(self.find.document.?, document)) try children.append(b.allocator(), try buffer_find.render(self, b));
    try children.append(b.allocator(), canvas);
    return children.toOwnedSlice(b.allocator());
}
fn fileHeading(self: *const Shell, b: *ui.Ui, record: *const workspace.Record, document: workspace.DocumentId, state: *const zircon_editor.Editor) !ui.Element {
    return chrome.fileHeader(self, b, record, document, state);
}
fn tabs(self: *const Shell, b: *ui.Ui, width: f32) !ui.Element {
    return chrome.tabs(self, b, width);
}

fn emptyEditor(b: *ui.Ui, colors: Palette) !ui.Element {
    return b.fluent().div().grow().padding(ui.Insets.all(36)).gap_px(16).justify_center().items_center().flex_col().children(&.{
        try label(b, colors, "Open a file to begin", colors.text, 20),
        try label(b, colors, "Choose a project file or create a new document.", colors.muted, 13),
        try b.fluent().div().gap_px(10).h(.{ .px = 32 }).justify_center().flex().children(.{ commandButton(b, colors, .open_path, "Open file…", true), commandButton(b, colors, .new_file, "New file", false) }).build(),
    }).build();
}

fn divider(b: *ui.Ui, colors: Palette, kind: u8, horizontal: bool) !ui.Element {
    return b.fluent().div().style(.{ .cursor = if (horizontal) .resize_vertical else .resize_horizontal, .direction = if (horizontal) .column else .row, .width = if (horizontal) .auto else .{ .px = 5 }, .height = if (horizontal) .{ .px = 5 } else .auto, .flex_shrink = 0, .background = colors.document, .hover_background = colors.hover, .padding = if (horizontal) .{ .top = 2, .bottom = 2 } else .{ .left = 2, .right = 2 } }).children(&.{try b.fluent().div().w(if (horizontal) .auto else .{ .px = 1 }).h(if (horizontal) .{ .px = 1 } else .auto).grow().background(colors.line).children(.{}).build()}).id(.{ .string = if (kind == 0) "sidebar-divider" else "pane-divider" }).listeners(.{ .on_input = b.onInputWith(Shell.onDrag, kind) }).build();
}

fn statusBar(self: *const Shell, b: *ui.Ui) !ui.Element {
    return chrome.statusbar(self, b);
}

fn overlay(self: *const Shell, b: *ui.Ui) !ui.Element {
    if (self.overlay == .open_project) return views_open_project.render(self, b);
    const colors = self.colors;
    const fields = self.fields.?;
    const width = @min(if (self.overlay == .palette or self.overlay == .quick_open) @as(f32, 560) else 580, @max(0, b.viewport().width - 48));
    var children: std.ArrayList(ui.Element) = .empty;
    const title: []const u8 = switch (self.overlay) {
        .open_project => unreachable,
        .palette => "Commands",
        .quick_open => "Go to file",
        .open_path => "Open file",
        .extension_path => "Install development extension",
        .project_search => "Search project",
        .save_as => "Save file as",
        .find => "Find",
        .replace => "Find and replace",
        .dirty => "Save your changes?",
        .none => unreachable,
    };
    const picker = self.overlay == .palette or self.overlay == .quick_open;
    const title_row = try b.fluent().div().h(.{ .px = 26 }).items_center().gap_px(12).flex().children(.{ b.fluent().adopt(try label(b, colors, title, colors.text, 15)).style(.{ .flex_grow = 1, .text = .{ .size = 15, .color = colors.text } }), commandButton(b, colors, .dismiss, "Esc", false) }).build();
    if (!picker) try children.append(b.allocator(), title_row);
    switch (self.overlay) {
        .open_project => unreachable,
        .palette, .quick_open => {
            try children.append(b.allocator(), try b.fluent().adopt(try inputField(b, fields.query, "query", true)).style(.{ .height = .{ .px = 38 }, .flex_shrink = 0 }).build());
            try children.append(b.allocator(), try components.rule(b, colors));
            const query = try fieldText(b, fields.query);
            if (self.overlay == .palette) {
                const filtered = try filteredCommands(b, query);
                const limit = resultCapacity(self, b);
                const start = resultStart(filtered.len, self.overlay_index, limit);
                for (filtered[start..@min(start + limit, filtered.len)], start..) |index, visible| {
                    const entry = catalogue.commands[index];
                    try children.append(b.allocator(), try components.menuRow(b, colors, entry.command, entry.label, try self.key_bindings.shortcut(b.allocator(), entry.command), visible == self.overlay_index));
                }
                if (filtered.len == 0) try children.append(b.allocator(), try label(b, colors, "No matching commands.", colors.muted, 12));
            } else {
                const filtered = try filteredFiles(self, b, query);
                const limit = resultCapacity(self, b);
                const start = resultStart(filtered.len, self.overlay_index, limit);
                for (filtered[start..@min(start + limit, filtered.len)], start..) |index, visible| {
                    const row = try b.fluent().button(.{ .label = self.file_index.items[index].label, .on_click = b.onClickWith(Shell.onFile, @as(u32, @intCast(index))), .style = resultStyle(colors, visible == self.overlay_index) }).build();
                    try children.append(b.allocator(), try b.fluent().adopt(row).id(.{ .number = @intCast(index) }).build());
                }
                if (filtered.len == 0) try children.append(b.allocator(), try label(b, colors, if (self.indexing) "Indexing files…" else "No matching files. Open a file by path with ⌘O.", colors.muted, 12));
            }
            try children.append(b.allocator(), try components.rule(b, colors));
            try children.append(b.allocator(), try b.fluent().div().h(.{ .px = 24 }).shrink_0().items_center().gap_px(10).padding(.{ .left = 10, .right = 8 }).flex().children(&.{ try label(b, colors, "↑ ↓ to navigate", colors.muted, 11), try b.fluent().div().grow().children(.{}).build(), try label(b, colors, "↵ Confirm", colors.muted, 11), try label(b, colors, "esc Close", colors.muted, 11) }).build());
        },
        .open_path, .save_as, .extension_path => {
            try children.appendSlice(b.allocator(), &.{
                try label(b, colors, "Enter a path relative to this project, or an absolute path.", colors.muted, 12),
                try inputField(b, fields.path, "path", true),
                try footer(b, &.{ try commandButton(b, colors, .dismiss, "Cancel", false), try commandButton(b, colors, .submit_path, if (self.overlay == .extension_path) "Install" else if (self.overlay == .save_as) "Save" else "Open", true) }),
            });
        },
        .project_search => {
            const input = try inputField(b, fields.project_query, "query", true);
            try children.appendSlice(b.allocator(), &.{ try b.fluent().adopt(input).listeners(.{ .on_input = b.onInput(Shell.onSearchQuery) }).build(), try commandButton(b, colors, .run_project_search, "Search", true) });
        },
        .find, .replace => {
            try children.append(b.allocator(), try inputField(b, fields.query, "query", true));
            if (self.overlay == .replace) try children.append(b.allocator(), try inputField(b, fields.replacement, "replacement", false));
            var buttons: std.ArrayList(ui.Element) = .empty;
            try buttons.appendSlice(b.allocator(), &.{ try commandButton(b, colors, .find_previous, "Previous", false), try commandButton(b, colors, .find_next, "Next", true) });
            if (self.overlay == .replace) try buttons.appendSlice(b.allocator(), &.{ try commandButton(b, colors, .replace_one, "Replace", false), try commandButton(b, colors, .replace_all, "Replace all", false) });
            try children.append(b.allocator(), try footer(b, buttons.items));
            try children.append(b.allocator(), try label(b, colors, "Search matches exact text. Escape returns to the editor.", colors.muted, 11));
        },
        .dirty => {
            try children.append(b.allocator(), try label(b, colors, "Your changes will be lost if you discard them.", colors.muted, 13));
            const dirty_title = try pendingTitle(self, b);
            if (dirty_title.len > 0) try children.append(b.allocator(), try label(b, colors, dirty_title, colors.text, 13));
            try children.append(b.allocator(), try footer(b, &.{ try commandButton(b, colors, .dismiss, "Cancel", false), try commandButton(b, colors, .discard_dirty, "Discard", false), try commandButton(b, colors, .save_dirty, "Save", true) }));
        },
        .none => unreachable,
    }
    if (self.status.len > 0 and self.status_is_error) try children.append(b.allocator(), try label(b, colors, self.status, colors.warning, 12));
    const panel_height = @min(try overlayHeight(self, b), @max(120, b.viewport().height - 100));
    const panel = try b.fluent().adopt(try components.floatingPanel(b, colors, .{ .width = width, .height = panel_height }, ui.Insets.all(if (picker) 6 else 12), if (picker) 0 else 8, children.items)).id(.{ .string = "dialog" }).build();
    const shade: ui.Color = .{ .r = 0, .g = 0, .b = 0, .a = if (picker) 0 else 0.2 };
    return b.fluent().div().padding(.{ .top = @min(@as(f32, 78), b.viewport().height * 0.13), .bottom = 20 }).items_center().justify(.start).background(shade).overflow_hidden().stack().children(.{panel}).id(.{ .string = @tagName(self.overlay) }).listeners(.{ .on_input = b.onInput(Shell.onOverlayInput) }).modal().build();
}

fn overlayHeight(self: *const Shell, b: *ui.Ui) !f32 {
    const error_height: f32 = if (self.status.len > 0 and self.status_is_error) 30 else 0;
    return error_height + switch (self.overlay) {
        .open_project => 432,
        .palette, .quick_open => blk: {
            const query = try fieldText(b, self.fields.?.query);
            const count = if (self.overlay == .palette) (try filteredCommands(b, query)).len else (try filteredFiles(self, b, query)).len;
            break :blk 84 + @as(f32, @floatFromInt(@max(@as(usize, 1), @min(count, resultCapacity(self, b))))) * 30;
        },
        .open_path, .save_as, .extension_path => 204,
        .find => 196,
        .project_search => 174,
        .replace => 246,
        .dirty => 188,
        .none => 0,
    };
}
fn resultStart(count: usize, selected: usize, limit: usize) usize {
    if (count <= limit or selected < limit) return 0;
    return @min(selected - limit + 1, count - limit);
}
fn resultCapacity(self: *const Shell, b: *const ui.Ui) usize {
    const reserved: f32 = if (self.status.len > 0 and self.status_is_error) 222 else 192;
    const available = @max(42, b.viewport().height - reserved);
    return @min(result_limit, @as(usize, @intFromFloat(@floor(available / 30))));
}

fn pendingTitle(self: *const Shell, b: *ui.Ui) ![]const u8 {
    if (self.pending) |pending| switch (pending) {
        .tab => |index| if (index < self.tabs.items.len) return (try self.workspace.getConst(self.tabs.items[index].document)).title(),
        .window => {
            var dirty: usize = 0;
            for (self.tabs.items) |tab| if (try self.workspace.dirty(tab.document)) {
                dirty += 1;
            };
            return std.fmt.allocPrint(b.allocator(), "{d} unsaved {s}", .{ dirty, if (dirty == 1) "document" else "documents" });
        },
    };
    return "";
}

fn label(b: *ui.Ui, _: Palette, value: []const u8, color: ui.Color, size: f32) !ui.Element {
    return b.fluent().text(value).style(.{ .text = .{ .size = size, .color = color } }).build();
}
pub fn commandButton(b: *ui.Ui, colors: Palette, action: Command, text: []const u8, primary: bool) !ui.Element {
    return components.actionButton(b, colors, action, text, primary);
}
fn resultStyle(colors: Palette, selected: bool) ui.Style {
    return .{ .height = .{ .px = 30 }, .flex_shrink = 0, .padding = .{ .left = 10, .right = 10, .top = 7 }, .radius = components.metrics.control_radius, .background = if (selected) colors.selected else colors.panel, .hover_background = colors.hover, .text = .{ .size = 12, .color = colors.text }, .overflow = .hidden };
}
fn footer(b: *ui.Ui, children: []const ui.Element) !ui.Element {
    return b.fluent().div().h(.{ .px = 30 }).gap_px(8).justify(.end).flex().children(children).build();
}
fn inputField(b: *ui.Ui, handle: ui.Entity(ui.controls.TextInput), key: []const u8, focus: bool) !ui.Element {
    const element = try b.fluent().view(handle).id(.{ .string = key }).build();
    return if (focus) b.fluent().adopt(element).autofocus().build() else element;
}
pub fn fieldText(b: *ui.Ui, handle: ui.Entity(ui.controls.TextInput)) ![]u8 {
    var bytes: []u8 = undefined;
    try b.watch(handle, ui.controls.TextInput.copy, .{ b.allocator(), &bytes });
    return bytes;
}
/// Deliberately ASCII case-insensitive substring filtering. UTF-8 bytes remain
/// untouched; this helper does not claim Unicode case folding.
pub fn matches(query_raw: []const u8, label_text: []const u8) bool {
    const query = std.mem.trim(u8, query_raw, " \t");
    if (query.len == 0) return true;
    if (query.len > label_text.len) return false;
    for (0..label_text.len - query.len + 1) |start| if (std.ascii.eqlIgnoreCase(label_text[start..][0..query.len], query)) return true;
    return false;
}
pub fn filteredCommands(b: *ui.Ui, query: []const u8) ![]usize {
    var indices: std.ArrayList(usize) = .empty;
    for (catalogue.commands, 0..) |entry, i| if (matches(query, entry.label)) try indices.append(b.allocator(), i);
    return indices.toOwnedSlice(b.allocator());
}
pub fn filteredFiles(self: *const Shell, b: *ui.Ui, query: []const u8) ![]usize {
    var indices: std.ArrayList(usize) = .empty;
    for (self.file_index.items, 0..) |entry, i| if (matches(query, entry.label)) try indices.append(b.allocator(), i);
    return indices.toOwnedSlice(b.allocator());
}
