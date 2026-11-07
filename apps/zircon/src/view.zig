//! Declarative application chrome. Every button invokes a real Shell command;
//! editor drawing and editing remain in zircon_editor's custom canvas.
const std = @import("std");
const ui = @import("zircon_ui");
const workspace = @import("zircon_workspace");
const shell = @import("shell.zig");
const Shell = shell.Shell;
const catalogue = @import("commands.zig");
const Command = catalogue.Command;
const Palette = @import("theme.zig").Palette;
const toolbar_height = @import("views/components.zig").metrics.titlebar;
const tab_height = @import("views/components.zig").metrics.tabs;
const status_height = @import("views/components.zig").metrics.status;
const result_limit = 12;

pub fn render(self: *const Shell, b: *ui.Ui) !ui.Element {
    try @import("services/recovery.zig").schedule(self, b);
    b.frame.tooltips_enabled = self.tooltips;
    b.frame.tooltip_delay = self.tooltip_delay / 1000;
    const colors = self.colors;
    const viewport = b.viewport();
    const sidebar_visible = self.sidebar_visible and viewport.width >= 600;
    const sidebar_width = if (sidebar_visible) @min(self.panelWidth(), @max(140, viewport.width * 0.4)) else 0;
    const editor_width = @max(100, viewport.width - sidebar_width - if (sidebar_visible) @as(f32, 5) else 0);
    var body_children: std.ArrayList(ui.Element) = .empty;
    if (!self.agent_mode and sidebar_visible) {
        try body_children.append(b.allocator(), try sidebar(self, b, sidebar_width, viewport.height));
        try body_children.append(b.allocator(), try divider(b, colors, 0, false));
    }
    if (!self.agent_mode) try body_children.append(b.allocator(), try editorArea(self, b, editor_width));
    const main = if (self.agent_mode) try @import("views/agents.zig").render(self, b) else try b.key(.{ .string = "main" }, try b.row(.{ .flex_grow = 1, .min_height = .{ .px = 0 }, .overflow = .hidden }, body_children.items));
    const base = try b.key(.{ .string = "workspace" }, try b.column(.{ .background = colors.document, .overflow = .hidden }, &.{ try toolbar(self, b), main, try statusBar(self, b) }));
    var layers: std.ArrayList(ui.Element) = .empty;
    try layers.append(b.allocator(), base);
    if (self.terminal.sessions.items.len > 0) try layers.append(b.allocator(), try @import("terminal.zig").wakeElement(b));
    if (self.find.waiting and !self.find.busy) try layers.append(b.allocator(), try @import("services/language.zig").syntaxWake(b));
    if (self.language.syntax_waiting) try layers.append(b.allocator(), try @import("services/language.zig").syntaxWake(b));
    if (self.git.menu != .none) try layers.append(b.allocator(), try @import("views/git_controls.zig").render(self, b));
    if (self.split_menu_open) try layers.append(b.allocator(), try @import("views/chrome.zig").splitMenu(self, b));
    if (self.popup != .none) try layers.append(b.allocator(), try @import("views/workspace_controls.zig").render(self, b));
    if (self.menu_open) try layers.append(b.allocator(), try @import("views/chrome.zig").menu(self, b));
    if (self.overlay != .none and self.fields != null) try layers.append(b.allocator(), try overlay(self, b));
    if (self.overlay == .none) if (self.language.completions) |message| {
        var choices: std.ArrayList(ui.Element) = .empty;
        const start = self.language.completion_index -| 7;
        for (message.data.completion.items[start..@min(start + 8, message.data.completion.items.len)], start..) |item, index| {
            try choices.append(b.allocator(), try b.key(.{ .number = @intCast(index) }, try b.button(.{ .label = item.label, .on_click = try b.onClickWith(@as(u32, @intCast(index)), Shell.onCompletion), .style = .{ .height = .{ .px = 30 }, .flex_shrink = 0, .padding = .{ .left = 12, .top = 7 }, .background = if (index == self.language.completion_index) colors.selected else colors.panel, .text = .{ .size = 13, .mono = true, .color = colors.text }, .overflow = .hidden } })));
        }
        if (choices.items.len == 0) try choices.append(b.allocator(), try label(b, colors, "No completions", colors.muted, 12));
        const requested: ui.Size = .{ .width = @min(420, viewport.width - 24), .height = @as(f32, @floatFromInt(@max(1, choices.items.len))) * 30 + 12 };
        var anchor: ui.Rect = .{ .x = if (self.sidebar_visible) self.panelWidth() + 60 else 60, .y = 100, .height = 22 };
        if (self.window) |handle| if (b.frame.app) |app| {
            if ((try app.window(handle)).frames.committed.text_input) |input| anchor = input.caret;
        };
        anchor.width = requested.width;
        const placement = @import("views/components.zig").popoverBounds(viewport, anchor, requested);
        const popup = try b.key(.{ .string = "completion-list" }, try @import("views/components.zig").floatingPanel(b, colors, .{ .width = placement.width, .height = placement.height }, ui.Insets.all(6), 0, choices.items));
        try layers.append(b.allocator(), try b.stack(.{ .padding = .{ .top = placement.y, .left = placement.x } }, &.{popup}));
    };
    return b.listen(try b.key(.{ .string = "zircon" }, try b.stack(.{ .background = colors.document, .overflow = .hidden }, layers.items)), .{ .on_capture = b.onInput(Shell.onGlobal), .on_input = b.onInput(Shell.onRoot) });
}

fn toolbar(self: *const Shell, b: *ui.Ui) !ui.Element {
    return @import("views/chrome.zig").titlebar(self, b);
}
fn sidebar(self: *const Shell, b: *ui.Ui, width: f32, height: f32) !ui.Element {
    return @import("views/project.zig").render(self, b, width, height);
}

pub fn editorArea(self: *const Shell, b: *ui.Ui, width: f32) !ui.Element {
    if (!self.terminal.visible or self.terminal.sessions.items.len == 0) return editorContent(self, b, width);
    const available_height = @max(80, b.viewport().height - toolbar_height - status_height);
    const right = self.terminal.dock == .right;
    const terminal_width = if (right) @max(100, width * self.terminal.ratio) else width;
    const terminal_height = if (right) available_height else @max(60, available_height * self.terminal.ratio);
    const source = try editorContent(self, b, if (right) @max(100, width - terminal_width - 5) else width);
    const terminal = try @import("terminal.zig").render(self, b, terminal_width, terminal_height);
    return b.div(.{ .direction = if (right) .row else .column, .flex_grow = 1, .min_width = .{ .px = 0 }, .min_height = .{ .px = 0 }, .overflow = .hidden }, &.{ source, try b.listen(try b.key(.{ .string = "terminal-divider" }, try b.div(.{ .width = if (right) .{ .px = 5 } else .auto, .height = if (right) .auto else .{ .px = 5 }, .flex_shrink = 0, .background = self.colors.line, .hover_background = self.colors.hover }, &.{})), .{ .on_input = b.onInput(@import("terminal.zig").onDivider) }), terminal });
}
fn editorContent(self: *const Shell, b: *ui.Ui, width: f32) !ui.Element {
    const colors = self.colors;
    if (self.panel != .editor and self.panel != .markdown and self.secondary == null) {
        const panel = switch (self.panel) {
            .image => try @import("views/image.zig").render(self, b),
            .extensions => try @import("views/extensions.zig").render(self, b),
            .search => try @import("views/search.zig").render(self, b),
            .git_diff => try @import("views/git_diff.zig").render(self, b),
            else => unreachable,
        };
        return b.key(.{ .string = "editor-area" }, try b.column(.{ .flex_grow = 1, .min_width = .{ .px = 0 }, .background = colors.document, .overflow = .hidden }, &.{ try tabs(self, b, width), panel }));
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
        primary = try b.styled(primary, .{ .width = .{ .px = primary_width }, .flex_grow = 1, .min_height = .{ .px = 0 }, .min_width = .{ .px = 0 }, .overflow = .hidden });
        if (primary_source) primary = try b.listen(try b.key(.{ .string = "primary-editor" }, primary), .{ .focusable = true, .on_input = try b.onInputWith(@as(u8, 0), Shell.onEditor) });
        if (self.currentTool(0) == .git_diff) primary = try b.requestFocus(try b.listen(try b.key(.{ .string = "primary-tool" }, primary), .{ .focusable = true }), if (self.active_pane == .primary) self.editor_focus_request else 0);
        if (primary_source) primary = try b.requestFocus(if (self.agent_mode) primary else try b.autofocus(primary), if (!self.agent_mode and self.active_pane == .primary) self.editor_focus_request else 0);
        try panes.append(b.allocator(), try b.listen(try b.key(.{ .string = "primary-pane" }, try b.column(.{ .width = .{ .px = primary_width }, .height = primary_height, .flex_grow = if (!split_visible) 1 else 0, .flex_shrink = 0, .min_width = .{ .px = 0 }, .overflow = .hidden }, try paneChildren(self, b, primary_record, tab.document, &tab.editor, primary, 0, primary_width))), .{ .on_capture = try b.onInputWith(@as(u8, 0), Shell.onPaneInput) }));
        if (preview_visible) {
            try panes.append(b.allocator(), try divider(b, colors, 1, false));
            const preview = try b.listen(try b.key(.{ .string = "markdown-preview" }, try self.preview.?.view.render(b)), .{ .focusable = true, .on_input = b.onInput(Shell.onPreview) });
            try panes.append(b.allocator(), try b.column(.{ .flex_grow = 1, .min_width = .{ .px = 0 }, .overflow = .hidden }, &.{ try b.row(.{ .height = .{ .px = 30 }, .flex_shrink = 0, .padding = .{ .left = 12, .right = 8 }, .align_items = .center, .gap = 8, .background = colors.document }, &.{ try b.styled(try label(b, colors, "Markdown preview", colors.muted, 12), .{ .flex_grow = 1, .text = .{ .size = 12, .color = colors.muted } }), try commandButton(b, colors, .back_to_editor, "Close", false) }), preview }));
        } else if (self.secondary) |*secondary| {
            try panes.append(b.allocator(), try divider(b, colors, 1, vertical));
            const record = try self.workspace.getConst(secondary.document);
            const secondary_source = self.secondary_tool == null;
            var secondary_canvas = if (secondary_source) try secondary.editor.render(&record.doc, b) else try panelBody(self, b, self.secondary_tool);
            secondary_canvas = try b.styled(secondary_canvas, .{ .flex_grow = 1, .min_width = .{ .px = 0 }, .overflow = .hidden });
            if (secondary_source) secondary_canvas = try b.listen(try b.key(.{ .string = "secondary-editor" }, secondary_canvas), .{ .focusable = true, .on_input = try b.onInputWith(@as(u8, 1), Shell.onEditor) });
            if (self.secondary_tool == .git_diff) secondary_canvas = try b.requestFocus(try b.listen(try b.key(.{ .string = "secondary-tool" }, secondary_canvas), .{ .focusable = true }), if (self.active_pane == .secondary) self.editor_focus_request else 0);
            if (secondary_source) secondary_canvas = try b.requestFocus(secondary_canvas, if (!self.agent_mode and self.active_pane == .secondary) self.editor_focus_request else 0);
            try panes.append(b.allocator(), try b.listen(try b.key(.{ .string = "secondary-pane" }, try b.column(.{ .flex_grow = 1, .min_width = .{ .px = 0 }, .overflow = .hidden }, try paneChildren(self, b, record, secondary.document, &secondary.editor, secondary_canvas, 1, if (vertical) width else available - primary_width))), .{ .on_capture = try b.onInputWith(@as(u8, 1), Shell.onPaneInput) }));
        }
        if (self.secondary != null and self.split_reverse and !preview_visible) std.mem.swap(ui.Element, &panes.items[0], &panes.items[2]);
        try children.append(b.allocator(), try b.key(.{ .string = "panes" }, try b.div(.{ .direction = if (vertical) .column else .row, .flex_grow = 1, .min_height = .{ .px = 0 }, .overflow = .hidden }, panes.items)));
        const active_id = if (self.active_pane == .secondary and self.secondary != null) self.secondary.?.document else tab.document;
        for (self.language.documents.items) |document| if (std.meta.eql(document.id, active_id)) {
            const message = document.diagnostics orelse break;
            const record = try self.workspace.getConst(active_id);
            if (message.data.diagnostics.version != record.doc.revision()) break;
            for (message.data.diagnostics.items[0..@min(4, message.data.diagnostics.items.len)], 0..) |diagnostic, index| try children.append(b.allocator(), try b.key(.{ .number = @intCast(index) }, try b.button(.{ .label = try std.fmt.allocPrint(b.allocator(), "{s}  {d}:{d}  {s}", .{ switch (diagnostic.severity) {
                .error_value => "Error",
                .warning => "Warning",
                .information => "Information",
                .hint => "Hint",
            }, diagnostic.range.start.line + 1, diagnostic.range.start.character + 1, diagnostic.message }), .on_click = try b.onClickWith(@as(u32, @intCast(index)), Shell.onDiagnostic), .style = .{ .height = .{ .px = 28 }, .flex_shrink = 0, .padding = .{ .left = 14, .top = 6 }, .background = colors.panel, .text = .{ .size = 12, .color = colors.warning }, .overflow = .hidden } })));
            break;
        };
    }
    return b.key(.{ .string = "editor-area" }, try b.column(.{ .flex_grow = 1, .min_width = .{ .px = 0 }, .background = colors.document, .overflow = .hidden }, children.items));
}
fn panelBody(self: *const Shell, b: *ui.Ui, tool: ?Shell.Tool) !ui.Element {
    if (tool) |which| return switch (which) {
        .git_diff => @import("views/git_diff.zig").render(self, b),
        .search => @import("views/search.zig").render(self, b),
        .extensions => @import("views/extensions.zig").render(self, b),
    };
    return @import("views/image.zig").render(self, b);
}
fn paneChildren(self: *const Shell, b: *ui.Ui, record: *const workspace.Record, document: workspace.DocumentId, state: *const @import("zircon_editor").Editor, canvas: ui.Element, pane: u8, pane_width: f32) ![]const ui.Element {
    var children: std.ArrayList(ui.Element) = .empty;

    try children.append(b.allocator(), try @import("views/chrome.zig").tabsForPane(self, b, pane_width, pane));
    const source = self.currentTool(pane) == null and (pane == 1 or self.panel == .editor or self.panel == .markdown);
    if (source) try children.append(b.allocator(), try fileHeading(self, b, record, document, state));
    if (source and self.find.visible and self.find.pane == pane and self.find.document != null and std.meta.eql(self.find.document.?, document)) try children.append(b.allocator(), try @import("views/buffer_find.zig").render(self, b));
    try children.append(b.allocator(), canvas);
    return children.toOwnedSlice(b.allocator());
}
fn fileHeading(self: *const Shell, b: *ui.Ui, record: *const workspace.Record, document: workspace.DocumentId, state: *const @import("zircon_editor").Editor) !ui.Element {
    return @import("views/chrome.zig").fileHeader(self, b, record, document, state);
}
fn tabs(self: *const Shell, b: *ui.Ui, width: f32) !ui.Element {
    return @import("views/chrome.zig").tabs(self, b, width);
}

fn emptyEditor(b: *ui.Ui, colors: Palette) !ui.Element {
    return b.column(.{ .flex_grow = 1, .padding = ui.Insets.all(36), .gap = 16, .justify_content = .center, .align_items = .center }, &.{
        try label(b, colors, "Open a file to begin", colors.text, 20),
        try label(b, colors, "Choose a project file or create a new document.", colors.muted, 13),
        try b.row(.{ .gap = 10, .height = .{ .px = 32 }, .justify_content = .center }, &.{ try commandButton(b, colors, .open_path, "Open file…", true), try commandButton(b, colors, .new_file, "New file", false) }),
    });
}

fn divider(b: *ui.Ui, colors: Palette, kind: u8, horizontal: bool) !ui.Element {
    return b.listen(try b.key(.{ .string = if (kind == 0) "sidebar-divider" else "pane-divider" }, try b.div(.{ .cursor = if (horizontal) .resize_vertical else .resize_horizontal, .direction = if (horizontal) .column else .row, .width = if (horizontal) .auto else .{ .px = 5 }, .height = if (horizontal) .{ .px = 5 } else .auto, .flex_shrink = 0, .background = colors.document, .hover_background = colors.hover, .padding = if (horizontal) .{ .top = 2, .bottom = 2 } else .{ .left = 2, .right = 2 } }, &.{try b.div(.{ .width = if (horizontal) .auto else .{ .px = 1 }, .height = if (horizontal) .{ .px = 1 } else .auto, .flex_grow = 1, .background = colors.line }, &.{})})), .{ .on_input = try b.onInputWith(kind, Shell.onDrag) });
}

fn statusBar(self: *const Shell, b: *ui.Ui) !ui.Element {
    return @import("views/chrome.zig").statusbar(self, b);
}

fn overlay(self: *const Shell, b: *ui.Ui) !ui.Element {
    if (self.overlay == .open_project) return @import("views/open_project.zig").render(self, b);
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
    const title_row = try b.row(.{ .height = .{ .px = 26 }, .align_items = .center, .gap = 12 }, &.{
        try b.styled(try label(b, colors, title, colors.text, 15), .{ .flex_grow = 1, .text = .{ .size = 15, .color = colors.text } }),
        try commandButton(b, colors, .dismiss, "Esc", false),
    });
    if (!picker) try children.append(b.allocator(), title_row);
    switch (self.overlay) {
        .open_project => unreachable,
        .palette, .quick_open => {
            try children.append(b.allocator(), try b.styled(try inputField(b, fields.query, "query", true), .{ .height = .{ .px = 38 }, .flex_shrink = 0 }));
            try children.append(b.allocator(), try @import("views/components.zig").rule(b, colors));
            const query = try fieldText(b, fields.query);
            if (self.overlay == .palette) {
                const filtered = try filteredCommands(b, query);
                const limit = resultCapacity(self, b);
                const start = resultStart(filtered.len, self.overlay_index, limit);
                for (filtered[start..@min(start + limit, filtered.len)], start..) |index, visible| {
                    const entry = catalogue.commands[index];
                    try children.append(b.allocator(), try @import("views/components.zig").menuRow(b, colors, entry.command, entry.label, try self.key_bindings.shortcut(b.allocator(), entry.command), visible == self.overlay_index));
                }
                if (filtered.len == 0) try children.append(b.allocator(), try label(b, colors, "No matching commands.", colors.muted, 12));
            } else {
                const filtered = try filteredFiles(self, b, query);
                const limit = resultCapacity(self, b);
                const start = resultStart(filtered.len, self.overlay_index, limit);
                for (filtered[start..@min(start + limit, filtered.len)], start..) |index, visible| {
                    const row = try b.button(.{ .label = self.file_index.items[index].label, .on_click = try b.onClickWith(@as(u32, @intCast(index)), Shell.onFile), .style = resultStyle(colors, visible == self.overlay_index) });
                    try children.append(b.allocator(), try b.key(.{ .number = @intCast(index) }, row));
                }
                if (filtered.len == 0) try children.append(b.allocator(), try label(b, colors, if (self.indexing) "Indexing files…" else "No matching files. Open a file by path with ⌘O.", colors.muted, 12));
            }
            try children.append(b.allocator(), try @import("views/components.zig").rule(b, colors));
            try children.append(b.allocator(), try b.row(.{ .height = .{ .px = 24 }, .flex_shrink = 0, .align_items = .center, .gap = 10, .padding = .{ .left = 10, .right = 8 } }, &.{ try label(b, colors, "↑ ↓ to navigate", colors.muted, 11), try b.div(.{ .flex_grow = 1 }, &.{}), try label(b, colors, "↵ Confirm", colors.muted, 11), try label(b, colors, "esc Close", colors.muted, 11) }));
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
            try children.appendSlice(b.allocator(), &.{ try b.listen(input, .{ .on_input = b.onInput(Shell.onSearchQuery) }), try commandButton(b, colors, .run_project_search, "Search", true) });
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
    const panel = try b.key(.{ .string = "dialog" }, try @import("views/components.zig").floatingPanel(b, colors, .{ .width = width, .height = panel_height }, ui.Insets.all(if (picker) 6 else 12), if (picker) 0 else 8, children.items));
    const shade: ui.Color = .{ .r = 0, .g = 0, .b = 0, .a = if (picker) 0 else 0.2 };
    return b.modal(try b.listen(try b.key(.{ .string = @tagName(self.overlay) }, try b.stack(.{ .padding = .{ .top = @min(@as(f32, 78), b.viewport().height * 0.13), .bottom = 20 }, .align_items = .center, .justify_content = .start, .background = shade, .overflow = .hidden }, &.{panel})), .{ .on_input = b.onInput(Shell.onOverlayInput) }));
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
    return b.styled(try b.text(value), .{ .text = .{ .size = size, .color = color } });
}
pub fn commandButton(b: *ui.Ui, colors: Palette, action: Command, text: []const u8, primary: bool) !ui.Element {
    return @import("views/components.zig").actionButton(b, colors, action, text, primary);
}
fn resultStyle(colors: Palette, selected: bool) ui.Style {
    return .{ .height = .{ .px = 30 }, .flex_shrink = 0, .padding = .{ .left = 10, .right = 10, .top = 7 }, .radius = @import("views/components.zig").metrics.control_radius, .background = if (selected) colors.selected else colors.panel, .hover_background = colors.hover, .text = .{ .size = 12, .color = colors.text }, .overflow = .hidden };
}
fn footer(b: *ui.Ui, children: []const ui.Element) !ui.Element {
    return b.row(.{ .height = .{ .px = 30 }, .gap = 8, .justify_content = .end }, children);
}
fn inputField(b: *ui.Ui, handle: ui.Entity(ui.controls.TextInput), key: []const u8, focus: bool) !ui.Element {
    const element = try b.key(.{ .string = key }, try b.view(handle));
    return if (focus) b.autofocus(element) else element;
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
