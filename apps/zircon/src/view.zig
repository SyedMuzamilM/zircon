//! Declarative application chrome. Every button invokes a real Shell command;
//! editor drawing and editing remain in zircon_editor's custom canvas.
const std = @import("std");
const ui = @import("zircon_ui");
const workspace = @import("zircon_workspace");
const shell = @import("shell.zig");
const Shell = shell.Shell;
const catalogue = @import("commands.zig");
const Command = catalogue.Command;
const theme = @import("theme.zig");
const toolbar_height: f32 = 42;
const tab_height: f32 = 36;
const status_height: f32 = 26;
const tree_row_height: f32 = 24;
const result_limit = 12;

pub fn render(self: *const Shell, b: *ui.Ui) !ui.Element {
    const viewport = b.viewport();
    const sidebar_visible = self.sidebar_visible and viewport.width >= 600;
    const sidebar_width = if (sidebar_visible) @min(self.sidebar_width, @max(140, viewport.width * 0.4)) else 0;
    const editor_width = @max(100, viewport.width - sidebar_width - if (sidebar_visible) @as(f32, 5) else 0);
    var body_children: std.ArrayList(ui.Element) = .empty;
    if (sidebar_visible) {
        try body_children.append(b.allocator(), try sidebar(self, b, sidebar_width, viewport.height));
        try body_children.append(b.allocator(), try divider(b, 0));
    }
    try body_children.append(b.allocator(), try editorArea(self, b, editor_width));
    const main = try b.key(.{ .string = "main" }, try b.row(.{ .flex_grow = 1, .min_height = .{ .px = 0 }, .overflow = .hidden }, body_children.items));
    const base = try b.key(.{ .string = "workspace" }, try b.column(.{ .background = theme.document, .overflow = .hidden }, &.{ try toolbar(self, b), main, try statusBar(self, b) }));
    var layers: std.ArrayList(ui.Element) = .empty;
    try layers.append(b.allocator(), base);
    if (self.overlay != .none and self.fields != null) try layers.append(b.allocator(), try overlay(self, b));
    return b.listen(try b.key(.{ .string = "zircon" }, try b.stack(.{ .background = theme.document, .overflow = .hidden }, layers.items)), .{ .on_capture = b.onInput(Shell.onGlobal), .on_input = b.onInput(Shell.onRoot) });
}

fn toolbar(self: *const Shell, b: *ui.Ui) !ui.Element {
    const compact = b.viewport().width < 600;
    const title = try label(b, "Zircon", theme.text, 14);
    const location = try b.styled(try b.text(std.fs.path.basename(self.workspace.root_path)), .{ .flex_grow = 1, .min_width = .{ .px = 0 }, .text = .{ .size = 12, .color = theme.muted }, .overflow = .hidden });
    var children: std.ArrayList(ui.Element) = .empty;
    try children.appendSlice(b.allocator(), &.{ title, location, try commandButton(b, .open_path, "Open", false) });
    if (!compact) try children.appendSlice(b.allocator(), &.{ try commandButton(b, .palette, "Commands", false), try commandButton(b, .split, if (self.secondary != null) "Unsplit" else "Split", false) });
    return b.key(.{ .string = "toolbar" }, try b.row(.{ .height = .{ .px = toolbar_height }, .flex_shrink = 0, .align_items = .center, .gap = 18, .padding = .{ .left = 16, .right = 12 }, .background = theme.chrome, .overflow = .hidden }, children.items));
}

fn sidebar(self: *const Shell, b: *ui.Ui, width: f32, window_height: f32) !ui.Element {
    const heading = try b.row(.{ .height = .{ .px = 36 }, .flex_shrink = 0, .align_items = .center, .padding = .{ .left = 14, .right = 10 }, .gap = 8 }, &.{
        try b.styled(try label(b, "Project", theme.muted, 12), .{ .flex_grow = 1, .text = .{ .size = 12, .color = theme.muted } }),
        try commandButton(b, .new_file, "+", false),
    });
    const available = @max(0, window_height - toolbar_height - status_height - 36);
    const visible = try ui.controls.visibleRows(self.tree.items.len, tree_row_height, self.tree_scroll.offset, available, 0);
    var rows: std.ArrayList(ui.Element) = .empty;
    const active_path = if (activeRecord(self)) |record| record.path else null;
    for (self.tree.items[visible.start..visible.end], visible.start..) |entry, i| {
        const selected = if (active_path) |path| std.mem.eql(u8, path, entry.path) else false;
        const name = if (entry.directory) try std.fmt.allocPrint(b.allocator(), "{s} {s}", .{ if (entry.expanded) "▾" else "▸", entry.name }) else try std.fmt.allocPrint(b.allocator(), "  {s}", .{entry.name});
        const row = try b.button(.{
            .label = name,
            .on_click = try b.onClickWith(@as(u32, @intCast(i)), Shell.onTree),
            .style = .{ .height = .{ .px = tree_row_height }, .flex_shrink = 0, .padding = .{ .left = 12 + @as(f32, @floatFromInt(entry.depth)) * 14, .top = 4, .right = 8 }, .background = if (selected) theme.selected else theme.sidebar, .text = .{ .size = 13, .color = if (selected) theme.text else theme.muted }, .overflow = .hidden },
        });
        try rows.append(b.allocator(), try b.key(.{ .number = @intCast(i) }, row));
    }
    if (self.tree.items.len == 0) try rows.append(b.allocator(), try b.column(.{ .padding = .{ .left = 14, .right = 14, .top = 8 }, .gap = 10 }, &.{
        try label(b, "This folder is empty.", theme.muted, 12),
        try commandButton(b, .new_file, "Create a file", false),
    }));
    const list = try b.listen(try b.key(.{ .string = "project-files" }, try b.column(.{ .flex_grow = 1, .min_height = .{ .px = 0 }, .overflow = .hidden }, rows.items)), .{ .on_input = b.onInput(Shell.onTreeInput) });
    return b.key(.{ .string = "sidebar" }, try b.column(.{ .width = .{ .px = width }, .flex_shrink = 0, .background = theme.sidebar, .overflow = .hidden }, &.{ heading, list }));
}

fn editorArea(self: *const Shell, b: *ui.Ui, width: f32) !ui.Element {
    var children: std.ArrayList(ui.Element) = .empty;
    try children.append(b.allocator(), try tabs(self, b, width));
    if (self.tabs.items.len == 0) {
        try children.append(b.allocator(), try emptyEditor(b));
    } else {
        var panes: std.ArrayList(ui.Element) = .empty;
        const available = @max(1, width - if (self.secondary != null) @as(f32, 5) else 0);
        const primary_width = if (self.secondary != null) available * std.math.clamp(self.split_ratio, 0.2, 0.8) else available;
        const tab = &self.tabs.items[@min(self.active, self.tabs.items.len - 1)];
        const primary_record = try self.workspace.getConst(tab.document);
        var primary = try tab.editor.render(&primary_record.doc, b);
        primary = try b.styled(primary, .{ .width = .{ .px = primary_width }, .flex_grow = if (self.secondary == null) 1 else 0, .flex_shrink = 0, .min_width = .{ .px = 0 }, .overflow = .hidden });
        primary = try b.listen(try b.key(.{ .string = "primary-editor" }, primary), .{ .focusable = true, .on_input = try b.onInputWith(@as(u8, 0), Shell.onEditor) });
        try panes.append(b.allocator(), try b.requestFocus(try b.autofocus(primary), if (self.active_pane == .primary) self.editor_focus_request else 0));
        if (self.secondary) |*secondary| {
            try panes.append(b.allocator(), try divider(b, 1));
            const record = try self.workspace.getConst(secondary.document);
            var secondary_canvas = try secondary.editor.render(&record.doc, b);
            secondary_canvas = try b.styled(secondary_canvas, .{ .width = .{ .px = 0 }, .flex_grow = 1, .min_width = .{ .px = 0 }, .overflow = .hidden });
            secondary_canvas = try b.listen(try b.key(.{ .string = "secondary-editor" }, secondary_canvas), .{ .focusable = true, .on_input = try b.onInputWith(@as(u8, 1), Shell.onEditor) });
            secondary_canvas = try b.requestFocus(secondary_canvas, if (self.active_pane == .secondary) self.editor_focus_request else 0);
            try panes.append(b.allocator(), secondary_canvas);
        }
        try children.append(b.allocator(), try b.key(.{ .string = "panes" }, try b.row(.{ .flex_grow = 1, .min_height = .{ .px = 0 }, .overflow = .hidden }, panes.items)));
    }
    return b.key(.{ .string = "editor-area" }, try b.column(.{ .flex_grow = 1, .min_width = .{ .px = 0 }, .background = theme.document, .overflow = .hidden }, children.items));
}

fn tabs(self: *const Shell, b: *ui.Ui, width: f32) !ui.Element {
    var items: std.ArrayList(ui.Element) = .empty;
    const capacity = @max(@as(usize, 1), @as(usize, @intFromFloat(@floor(@max(108, width - 56) / 108))));
    const overflow = self.tabs.items.len > capacity;
    const first = if (overflow and self.active >= capacity) @min(self.active - capacity + 1, self.tabs.items.len - capacity) else 0;
    const end = @min(self.tabs.items.len, first + capacity);
    const tab_space = @max(90, width - if (overflow) @as(f32, 56) else 0);
    const tab_width = @min(@as(f32, 190), @max(@as(f32, 90), tab_space / @as(f32, @floatFromInt(@max(@as(usize, 1), end - first)))));
    if (overflow) try items.append(b.allocator(), try tabNavigation(b, if (first > 0) first - 1 else null, "previous-tab", "‹"));
    for (self.tabs.items[first..end], first..) |tab, i| {
        const record = try self.workspace.getConst(tab.document);
        const selected = i == self.active;
        const background = if (selected) theme.document else theme.chrome;
        const title = try std.fmt.allocPrint(b.allocator(), "{s}{s}", .{ record.title(), if (record.dirty()) " •" else "" });
        const tab_button = try b.button(.{ .label = title, .on_click = try b.onClickWith(@as(u32, @intCast(i)), Shell.onTab), .style = .{ .flex_grow = 1, .min_width = .{ .px = 0 }, .padding = .{ .left = 12, .top = 10, .right = 3 }, .background = background, .text = .{ .size = 12, .color = if (selected) theme.text else theme.muted }, .overflow = .hidden } });
        const close = try b.key(.{ .string = "close" }, try b.button(.{ .label = "×", .on_click = try b.onClickWith(@as(u32, @intCast(i)), Shell.onCloseTab), .style = .{ .width = .{ .px = 26 }, .flex_shrink = 0, .padding = .{ .top = 9, .left = 6 }, .background = background, .text = .{ .size = 13, .color = theme.muted } } }));
        try items.append(b.allocator(), try b.key(.{ .number = @intCast(i) }, try b.column(.{ .width = .{ .px = tab_width }, .min_width = .{ .px = 90 }, .flex_shrink = 1 }, &.{
            try b.row(.{ .flex_grow = 1, .background = background }, &.{ tab_button, close }),
            try b.div(.{ .height = .{ .px = 1 }, .flex_shrink = 0, .background = if (selected) theme.accent else theme.chrome }, &.{}),
        })));
    }
    if (overflow) try items.append(b.allocator(), try tabNavigation(b, if (end < self.tabs.items.len) end else null, "next-tab", "›"));
    if (items.items.len == 0) try items.append(b.allocator(), try label(b, "No open files", theme.muted, 12));
    return b.key(.{ .string = "tabs" }, try b.row(.{ .height = .{ .px = tab_height }, .flex_shrink = 0, .background = theme.chrome, .overflow = .hidden }, items.items));
}

fn tabNavigation(b: *ui.Ui, target: ?usize, key: []const u8, text: []const u8) !ui.Element {
    const style: ui.Style = .{ .width = .{ .px = 28 }, .height = .{ .px = tab_height }, .flex_shrink = 0, .padding = .{ .left = 8, .top = 7 }, .text = .{ .size = 18, .color = theme.muted }, .background = theme.chrome };
    return b.key(.{ .string = key }, if (target) |index| try b.button(.{ .label = text, .on_click = try b.onClickWith(@as(u32, @intCast(index)), Shell.onTab), .style = style }) else try b.div(style, &.{}));
}

fn emptyEditor(b: *ui.Ui) !ui.Element {
    return b.column(.{ .flex_grow = 1, .padding = ui.Insets.all(36), .gap = 16, .justify_content = .center, .align_items = .center }, &.{
        try label(b, "Open a file to begin", theme.text, 20),
        try label(b, "Choose a project file or create a new document.", theme.muted, 13),
        try b.row(.{ .gap = 10, .height = .{ .px = 32 }, .justify_content = .center }, &.{ try commandButton(b, .open_path, "Open file…", true), try commandButton(b, .new_file, "New file", false) }),
    });
}

fn divider(b: *ui.Ui, kind: u8) !ui.Element {
    return b.listen(try b.key(.{ .string = if (kind == 0) "sidebar-divider" else "pane-divider" }, try b.div(.{ .width = .{ .px = 5 }, .flex_shrink = 0, .background = theme.line }, &.{})), .{ .on_input = try b.onInputWith(kind, Shell.onDrag) });
}

fn activeRecord(self: *const Shell) ?*const workspace.Record {
    if (self.active_pane == .secondary) if (self.secondary) |pane| return self.workspace.getConst(pane.document) catch null;
    if (self.tabs.items.len == 0) return null;
    return self.workspace.getConst(self.tabs.items[@min(self.active, self.tabs.items.len - 1)].document) catch null;
}

fn statusBar(self: *const Shell, b: *ui.Ui) !ui.Element {
    var state: []const u8 = "Ready";
    var location: []const u8 = "";
    if (activeRecord(self)) |record| {
        const current_editor = if (self.active_pane == .secondary and self.secondary != null) &self.secondary.?.editor else &self.tabs.items[@min(self.active, self.tabs.items.len - 1)].editor;
        var snapshot = record.doc.snapshot();
        defer snapshot.deinit();
        const caret = current_editor.primary().head;
        const point = try snapshot.pointAt(@min(caret, snapshot.byteLen()));
        const line = try snapshot.lineRange(point.line);
        var column: usize = 0;
        const prefix_range = @import("zircon_text").Range{ .start = line.start, .end = @min(caret, line.end) };
        if (prefix_range.end - prefix_range.start <= 64 * 1024) {
            var chunks = try snapshot.chunks(prefix_range);
            while (chunks.next()) |chunk| for (chunk) |byte| {
                if (byte == '\t') column += current_editor.tab_width - column % current_editor.tab_width else if (byte & 0xc0 != 0x80) column += 1;
            };
        } else column = point.byte_column;
        location = try std.fmt.allocPrint(b.allocator(), "Ln {d}, Col {d}   {s}   UTF-8", .{ point.line + 1, column + 1, languageName(current_editor.language) });
        state = if (record.dirty()) "Modified" else "Saved";
        if (current_editor.selections.items.items.len > 1) state = try std.fmt.allocPrint(b.allocator(), "{d} cursors", .{current_editor.selections.items.items.len});
    }
    if (self.status.len > 0) state = self.status else if (self.indexing) state = "Indexing project…";
    const state_element = try b.styled(try label(b, state, if (self.status.len > 0 and self.status_is_error) theme.warning else theme.muted, 11), .{ .flex_grow = 1, .min_width = .{ .px = 0 }, .text = .{ .size = 11, .color = if (self.status.len > 0 and self.status_is_error) theme.warning else theme.muted }, .overflow = .hidden });
    return b.key(.{ .string = "status" }, try b.row(.{ .height = .{ .px = status_height }, .flex_shrink = 0, .align_items = .center, .padding = .{ .left = 12, .right = 12 }, .gap = 12, .background = theme.chrome, .overflow = .hidden }, &.{ state_element, try label(b, location, theme.muted, 11) }));
}

fn languageName(language: @import("zircon_editor").syntax.Language) []const u8 {
    return switch (language) {
        .plain => "Plain text",
        .zig => "Zig",
        .rust => "Rust",
        .json => "JSON",
        .markdown => "Markdown",
    };
}

fn overlay(self: *const Shell, b: *ui.Ui) !ui.Element {
    const fields = self.fields.?;
    const width = @min(@as(f32, 580), @max(@as(f32, 260), b.viewport().width - 48));
    var children: std.ArrayList(ui.Element) = .empty;
    const title: []const u8 = switch (self.overlay) {
        .palette => "Commands",
        .quick_open => "Go to file",
        .open_path => "Open file",
        .save_as => "Save file as",
        .find => "Find",
        .replace => "Find and replace",
        .dirty => "Save your changes?",
        .none => unreachable,
    };
    const title_row = try b.row(.{ .height = .{ .px = 26 }, .align_items = .center, .gap = 12 }, &.{
        try b.styled(try label(b, title, theme.text, 15), .{ .flex_grow = 1, .text = .{ .size = 15, .color = theme.text } }),
        try commandButton(b, .dismiss, "Esc", false),
    });
    try children.append(b.allocator(), title_row);
    switch (self.overlay) {
        .palette, .quick_open => {
            try children.append(b.allocator(), try inputField(b, fields.query, "query", true));
            const query = try fieldText(b, fields.query);
            if (self.overlay == .palette) {
                const filtered = try filteredCommands(b, query);
                const limit = resultCapacity(self, b);
                const start = resultStart(filtered.len, self.overlay_index, limit);
                for (filtered[start..@min(start + limit, filtered.len)], start..) |index, visible| {
                    const entry = catalogue.commands[index];
                    const text = if (entry.shortcut.len > 0) try std.fmt.allocPrint(b.allocator(), "{s}    {s}", .{ entry.label, entry.shortcut }) else entry.label;
                    try children.append(b.allocator(), try paletteCommand(b, entry.command, text, visible == self.overlay_index));
                }
                if (filtered.len == 0) try children.append(b.allocator(), try label(b, "No matching commands.", theme.muted, 12));
            } else {
                const filtered = try filteredFiles(self, b, query);
                const limit = resultCapacity(self, b);
                const start = resultStart(filtered.len, self.overlay_index, limit);
                for (filtered[start..@min(start + limit, filtered.len)], start..) |index, visible| {
                    const row = try b.button(.{ .label = self.file_index.items[index].label, .on_click = try b.onClickWith(@as(u32, @intCast(index)), Shell.onFile), .style = resultStyle(visible == self.overlay_index) });
                    try children.append(b.allocator(), try b.key(.{ .number = @intCast(index) }, row));
                }
                if (filtered.len == 0) try children.append(b.allocator(), try label(b, if (self.indexing) "Indexing files…" else "No matching files. Open a file by path with ⌘O.", theme.muted, 12));
            }
        },
        .open_path, .save_as => {
            try children.appendSlice(b.allocator(), &.{
                try label(b, "Enter a path relative to this project, or an absolute path.", theme.muted, 12),
                try inputField(b, fields.path, "path", true),
                try footer(b, &.{ try commandButton(b, .dismiss, "Cancel", false), try commandButton(b, .submit_path, if (self.overlay == .save_as) "Save" else "Open", true) }),
            });
        },
        .find, .replace => {
            try children.append(b.allocator(), try inputField(b, fields.query, "query", true));
            if (self.overlay == .replace) try children.append(b.allocator(), try inputField(b, fields.replacement, "replacement", false));
            var buttons: std.ArrayList(ui.Element) = .empty;
            try buttons.appendSlice(b.allocator(), &.{ try commandButton(b, .find_previous, "Previous", false), try commandButton(b, .find_next, "Next", true) });
            if (self.overlay == .replace) try buttons.appendSlice(b.allocator(), &.{ try commandButton(b, .replace_one, "Replace", false), try commandButton(b, .replace_all, "Replace all", false) });
            try children.append(b.allocator(), try footer(b, buttons.items));
            try children.append(b.allocator(), try label(b, "Search matches exact text. Escape returns to the editor.", theme.muted, 11));
        },
        .dirty => {
            try children.append(b.allocator(), try label(b, "Your changes will be lost if you discard them.", theme.muted, 13));
            const dirty_title = try pendingTitle(self, b);
            if (dirty_title.len > 0) try children.append(b.allocator(), try label(b, dirty_title, theme.text, 13));
            try children.append(b.allocator(), try footer(b, &.{ try commandButton(b, .dismiss, "Cancel", false), try commandButton(b, .discard_dirty, "Discard", false), try commandButton(b, .save_dirty, "Save", true) }));
        },
        .none => unreachable,
    }
    if (self.status.len > 0 and self.status_is_error) try children.append(b.allocator(), try label(b, self.status, theme.warning, 12));
    const panel_height = @min(try overlayHeight(self, b), @max(120, b.viewport().height - 100));
    const panel = try b.key(.{ .string = "dialog" }, try b.column(.{ .width = .{ .px = width }, .height = .{ .px = panel_height }, .gap = 12, .padding = ui.Insets.all(18), .background = theme.panel, .radius = 9, .overflow = .hidden }, children.items));
    const shade: ui.Color = .{ .r = 0, .g = 0, .b = 0, .a = 0.45 };
    return b.modal(try b.key(.{ .string = @tagName(self.overlay) }, try b.stack(.{ .padding = .{ .top = @min(@as(f32, 78), b.viewport().height * 0.13), .bottom = 20 }, .align_items = .center, .justify_content = .start, .background = shade, .overflow = .hidden }, &.{panel})));
}

fn overlayHeight(self: *const Shell, b: *ui.Ui) !f32 {
    const error_height: f32 = if (self.status.len > 0 and self.status_is_error) 30 else 0;
    return error_height + switch (self.overlay) {
        .palette, .quick_open => blk: {
            const query = try fieldText(b, self.fields.?.query);
            const count = if (self.overlay == .palette) (try filteredCommands(b, query)).len else (try filteredFiles(self, b, query)).len;
            break :blk 36 + 26 + 12 + 38 + 12 + @as(f32, @floatFromInt(@max(@as(usize, 1), @min(count, resultCapacity(self, b))))) * 42;
        },
        .open_path, .save_as => 204,
        .find => 196,
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
    const reserved: f32 = if (self.status.len > 0 and self.status_is_error) 254 else 224;
    const available = @max(42, b.viewport().height - reserved);
    return @min(result_limit, @as(usize, @intFromFloat(@floor(available / 42))));
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

fn label(b: *ui.Ui, value: []const u8, color: ui.Color, size: f32) !ui.Element {
    return b.styled(try b.text(value), .{ .text = .{ .size = size, .color = color } });
}
fn commandButton(b: *ui.Ui, action: Command, text: []const u8, primary: bool) !ui.Element {
    return b.button(.{ .label = text, .on_click = try b.onClickWith(action, Shell.onCommand), .style = .{ .height = .{ .px = 28 }, .padding = .{ .left = 10, .right = 10, .top = 6 }, .radius = 4, .background = if (primary) theme.primary else theme.chrome, .text = .{ .size = 12, .color = if (primary) theme.text else theme.muted }, .flex_shrink = 0 } });
}
fn paletteCommand(b: *ui.Ui, action: Command, text: []const u8, selected: bool) !ui.Element {
    return b.key(.{ .number = @backingInt(action) }, try b.button(.{ .label = text, .on_click = try b.onClickWith(action, Shell.onCommand), .style = resultStyle(selected) }));
}
fn resultStyle(selected: bool) ui.Style {
    return .{ .height = .{ .px = 30 }, .flex_shrink = 0, .padding = .{ .left = 10, .right = 10, .top = 7 }, .radius = 4, .background = if (selected) theme.selected else theme.panel, .text = .{ .size = 12, .color = theme.text }, .overflow = .hidden };
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
