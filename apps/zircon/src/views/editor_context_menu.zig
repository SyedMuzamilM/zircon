//! Editor right-click actions retain their source pane and selection.
const std = @import("std");
const builtin = @import("builtin");
const editor = @import("zircon_editor");
const lsp = @import("zircon_language");
const text = @import("zircon_text");
const ui = @import("zircon_ui");
const ws = @import("zircon_workspace");
const actions = @import("../actions.zig");
const commands = @import("../commands.zig");
const hover = @import("../services/symbol_hover.zig");
const shell = @import("../shell.zig");
const terminal = @import("../terminal.zig");
const v = @import("components.zig");
const Shell = shell.Shell;
const Action = union(enum) { command: commands.Command, copy_trim, reveal, terminal };
const Entry = struct { label: []const u8, action: Action, group: u8, enabled: bool = true };
pub const Model = struct { document: ws.DocumentId, revision: u64, selection: u64, has_selection: bool, pane: u8, anchor: ui.Point, selected: usize = 0, keyboard: bool = false };
const row_height: f32 = 30;

fn fingerprint(state: *const editor.Editor) u64 {
    return std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(state.selections.items.items));
}

fn validSelection(state: *editor.Editor, menu: Model) !*editor.Editor {
    if (fingerprint(state) != menu.selection) return error.StaleContextMenu;
    return state;
}

fn sourceEditor(self: *Shell, menu: Model) !*editor.Editor {
    const record = try self.workspace.getConst(menu.document);
    if (record.doc.revision() != menu.revision) return error.StaleContextMenu;
    if (self.currentTool(menu.pane) == .search) {
        for (self.search.editing.panes[menu.pane].views.items) |*view| if (std.meta.eql(view.document, menu.document)) return validSelection(&view.editor, menu);
    }
    if (menu.pane == 1) {
        if (self.secondary) |*pane| if (std.meta.eql(pane.document, menu.document) and self.secondary_tool == null) return validSelection(&pane.editor, menu);
    } else if (self.tabs.items.len > 0 and (self.panel == .editor or self.panel == .markdown)) {
        const tab = &self.tabs.items[self.active];
        if (std.meta.eql(tab.document, menu.document)) return validSelection(&tab.editor, menu);
    }
    return error.StaleContextMenu;
}

fn entries(self: *const Shell, menu: Model) [12]Entry {
    var client: ?*lsp.Client = null;
    for (self.language.documents.items) |doc| if (std.meta.eql(doc.id, menu.document) and doc.session < self.language.sessions.items.len) {
        client = self.language.sessions.items[doc.session].client;
        break;
    };
    if (client != null and !client.?.ready()) client = null;
    const selected = menu.has_selection;
    const saved = if (self.workspace.getConst(menu.document)) |record| record.path != null else |_| false;
    return .{
        .{ .label = "Go to Definition", .action = .{ .command = .go_to_definition }, .group = 0, .enabled = client != null and client.?.supportsDefinition() },
        .{ .label = "Find All References", .action = .{ .command = .find_references }, .group = 0, .enabled = client != null and client.?.supportsReferences() },
        .{ .label = "Show Symbol Information", .action = .{ .command = .show_symbol_info }, .group = 0, .enabled = client != null and client.?.supportsHover() },
        .{ .label = "Rename Symbol", .action = .{ .command = .rename_symbol }, .group = 1, .enabled = client != null and client.?.supportsRename() },
        .{ .label = "Format Buffer", .action = .{ .command = .format_document }, .group = 1, .enabled = client != null and client.?.supportsFormatting() },
        .{ .label = "Show Code Actions", .action = .{ .command = .code_actions }, .group = 1, .enabled = client != null and client.?.supportsCodeActions() },
        .{ .label = "Cut", .action = .{ .command = .cut }, .group = 2, .enabled = selected },
        .{ .label = "Copy", .action = .{ .command = .copy }, .group = 2, .enabled = selected },
        .{ .label = "Copy and Trim", .action = .copy_trim, .group = 2, .enabled = selected },
        .{ .label = "Paste", .action = .{ .command = .paste }, .group = 2 },
        .{ .label = if (builtin.os.tag == .macos) "Reveal in Finder" else "Reveal in File Manager", .action = .reveal, .group = 3, .enabled = saved and builtin.os.tag == .macos },
        .{ .label = "Open in Terminal", .action = .terminal, .group = 3, .enabled = saved },
    };
}

fn placement(menu: Model, viewport: ui.Size) ui.Rect {
    const width = @min(340, @max(1, viewport.width - 16));
    const height = @min(12 * row_height + 3 * 9 + 12, @max(1, viewport.height - 16));
    return .{ .x = std.math.clamp(menu.anchor.x, 8, @max(8, viewport.width - width - 8)), .y = std.math.clamp(menu.anchor.y, 8, @max(8, viewport.height - height - 8)), .width = width, .height = height };
}

pub fn pointer(self: *Shell, cx: *ui.Context(Shell), state: *editor.Editor, document: *const text.Document, id: ws.DocumentId, pane: u8, e: *ui.Event(ui.Input)) !bool {
    if (e.data != .pointer_down or e.data.pointer_down.button != .secondary) return false;
    var snapshot = document.snapshot();
    defer snapshot.deinit();
    const at = try state.offsetAtPoint(snapshot, e, e.data.pointer_down.position);
    var inside = false;
    for (state.selections.items.items) |selection| {
        const range = selection.range();
        if (!selection.empty() and at >= range.start and at < range.end) inside = true;
    }
    if (!inside) state.selections.single(.{ .anchor = at, .head = at });
    state.typing_group = 0;
    state.dragging = false;
    self.active_pane = if (pane == 1) .secondary else .primary;
    self.terminal.focused = false;
    self.language.clearCompletion();
    hover.clear(self, cx);
    self.popup = .none;
    self.git.menu = .none;
    self.menu_open = false;
    self.editor_context_menu = .{ .document = id, .revision = snapshot.revision(), .selection = fingerprint(state), .has_selection = !state.primary().empty(), .pane = pane, .anchor = e.data.pointer_down.position };
    const choices = entries(self, self.editor_context_menu.?);
    for (choices, 0..) |choice, index| if (choice.enabled) {
        self.editor_context_menu.?.selected = index;
        break;
    };
    e.releasePointer();
    e.focus();
    e.preventDefault();
    e.stopPropagation();
    cx.notify();
    return true;
}

pub fn input(self: *Shell, e: *ui.Event(ui.Input), cx: *ui.Context(Shell)) !bool {
    const menu = self.editor_context_menu orelse return false;
    _ = sourceEditor(self, menu) catch {
        self.editor_context_menu = null;
        cx.notify();
        return false;
    };
    switch (e.data) {
        .pointer_down => |pointer_value| {
            const rect = placement(menu, try e.windowSize());
            const point = pointer_value.position;
            if (point.x < rect.x or point.y < rect.y or point.x >= rect.x + rect.width or point.y >= rect.y + rect.height) {
                self.editor_context_menu = null;
                cx.notify();
            }
        },
        .key_down => |key| {
            if (key.key == .escape) self.editor_context_menu = null else if (key.key == .up or key.key == .down) {
                const choices = entries(self, menu);
                var selected = menu.selected;
                for (0..choices.len) |_| {
                    selected = if (key.key == .down) (selected + 1) % choices.len else (selected + choices.len - 1) % choices.len;
                    if (choices[selected].enabled) break;
                }
                self.editor_context_menu.?.selected = selected;
                self.editor_context_menu.?.keyboard = true;
            } else if (key.key == .enter) {
                activate(self, cx, menu.selected) catch |err| try self.reportError(err);
            } else {
                self.editor_context_menu = null;
                cx.notify();
                return false;
            }
            e.preventDefault();
            e.stopPropagation();
            cx.notify();
            return true;
        },
        .pointer_move => {
            if (menu.keyboard) {
                self.editor_context_menu.?.keyboard = false;
                cx.notify();
            }
        },
        .scroll, .resize, .text, .edit => {
            self.editor_context_menu = null;
            cx.notify();
        },
        .focus => |focused| if (!focused) {
            self.editor_context_menu = null;
            cx.notify();
        },
        else => {},
    }
    return false;
}

pub fn render(self: *const Shell, b: *ui.Ui) !ui.Element {
    const menu = self.editor_context_menu.?;
    const c = self.colors;
    const choices = entries(self, menu);
    var rows: std.ArrayList(ui.Element) = .empty;
    for (choices, 0..) |choice, index| {
        if (index > 0 and choices[index - 1].group != choice.group) try rows.append(b.allocator(), try b.fluent().div()
            .h(.{ .px = 9 })
            .shrink_0()
            .padding(.{ .top = 4, .bottom = 4 })
            .children(.{v.rule(b, c)})
            .build());
        var shortcut = if (choice.action == .command) try self.key_bindings.shortcut(b.allocator(), choice.action.command) else "";
        if (shortcut.len == 0 and choice.action == .command) switch (choice.action.command) {
            .cut, .copy, .paste => shortcut = commands.entry(choice.action.command).shortcut,
            else => {},
        };
        try rows.append(b.allocator(), try b.fluent().button(.{ .label = choice.label })
            .flex()
            .h(.{ .px = row_height })
            .shrink_0()
            .items_center()
            .gap_px(20)
            .padding(.{ .left = 10, .right = 10 })
            .rounded_px(v.metrics.control_radius)
            .background(if (choice.enabled and menu.keyboard and menu.selected == index) c.hover else null)
            .hover_background(if (choice.enabled) c.hover else null)
            .opacity(if (choice.enabled) 1 else 0.4)
            .overflow_hidden()
            .on_click(if (choice.enabled) try b.onClickWith(onAction, @as(u32, @intCast(index))) else null)
            .children(.{
                b.fluent().adopt(try v.text(b, choice.label, c.text, 13))
                    .grow()
                    .min_w(.{ .px = 0 })
                    .overflow_hidden(),
                v.text(b, shortcut, c.muted, 12),
            })
            .id(.{ .number = @intCast(index) })
            .build());
    }
    const rect = placement(menu, b.viewport());
    const popup = try b.fluent().adopt(try v.floatingPanel(b, c, .{ .width = rect.width, .height = rect.height }, ui.Insets.all(6), 0, rows.items))
        .id(.{ .string = "editor-context-menu" })
        .build();
    return b.fluent().div()
        .padding(.{ .top = rect.y, .left = rect.x })
        .items(.start)
        .stack()
        .children(.{popup})
        .build();
}

fn onAction(self: *Shell, _: *ui.Event(ui.Click), cx: *ui.Context(Shell), index: u32) !void {
    activate(self, cx, index) catch |err| try self.reportError(err);
    cx.notify();
}

fn activate(self: *Shell, cx: *ui.Context(Shell), index: usize) !void {
    const menu = self.editor_context_menu orelse return;
    const state = try sourceEditor(self, menu);
    const choices = entries(self, menu);
    if (index >= choices.len or !choices[index].enabled) return;
    self.active_pane = if (menu.pane == 1) .secondary else .primary;
    self.editor_context_menu = null;
    const choice = choices[index];
    switch (choice.action) {
        .command => |command| try actions.execute(self, cx, command, null),
        .copy_trim => {
            var snapshot = try self.workspace.snapshot(menu.document);
            defer snapshot.deinit();
            var bytes: std.ArrayList(u8) = .empty;
            defer bytes.deinit(self.allocator);
            for (state.selections.items.items, 0..) |selection, item| {
                if (item > 0) try bytes.append(self.allocator, '\n');
                const selected = try snapshot.copy(self.allocator, selection.range());
                defer self.allocator.free(selected);
                try bytes.appendSlice(self.allocator, std.mem.trim(u8, selected, " \t\r\n"));
            }
            var event: ui.Event(ui.Input) = .{ .data = .{ .text = "" }, ._surface = (try cx.app.window(self.window.?)).surface };
            try event.writeClipboard(bytes.items);
        },
        .reveal => {
            const path = (try self.workspace.getConst(menu.document)).path orelse return error.NoDocument;
            const result = try std.process.run(self.allocator, self.workspace.io, .{ .argv = &.{ "/usr/bin/open", "-R", path } });
            defer self.allocator.free(result.stdout);
            defer self.allocator.free(result.stderr);
            if (result.term != .exited or result.term.exited != 0) return error.RevealFileFailed;
        },
        .terminal => {
            const path = (try self.workspace.getConst(menu.document)).path orelse return error.NoDocument;
            try terminal.createAt(self, std.fs.path.dirname(path) orelse self.workspace.root_path);
        },
    }
    cx.notify();
}
