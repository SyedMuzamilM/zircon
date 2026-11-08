//! Application commands and file policy. Editing is delegated to zircon_editor;
//! persistence is delegated to zircon_workspace. Errors leave the view usable.
const std = @import("std");
const editing = @import("zircon_editor");
const text = @import("zircon_text");
const ui = @import("zircon_ui");
const ws = @import("zircon_workspace");
const commands_module = @import("commands.zig");
const editor_git = @import("editor_git.zig");
const git_editing = @import("git_editing.zig");
const panes = @import("panes.zig");
const project_index = @import("project_index.zig");
const buffer_find = @import("services/buffer_find.zig");
const catalog = @import("services/catalog.zig");
const services_extensions = @import("services/extensions.zig");
const services_git = @import("services/git.zig");
const services_language = @import("services/language.zig");
const services_recovery = @import("services/recovery.zig");
const services_search = @import("services/search.zig");
const symbol_hover = @import("services/symbol_hover.zig");
const settings_model = @import("settings/model.zig");
const settings_view = @import("settings/view.zig");
const model = @import("shell.zig");
const terminal_module = @import("terminal.zig");
const git_commands = @import("views/git/commands.zig");
const git_diff_controls = @import("views/git/diff_controls.zig");
const git_controls = @import("views/git/menus.zig");
const views_image = @import("views/image.zig");
const field_input = @import("views/input.zig");
const views_markdown = @import("views/markdown.zig");
const open_project = @import("views/open_project.zig");
const overlays = @import("views/overlays.zig");
const workspace_controls = @import("views/workspace_controls.zig");
const Shell = model.Shell;
const Command = commands_module.Command;
pub fn bootstrap(self: *Shell, cx: *ui.Context(Shell), window: ui.WindowHandle) !void {
    if (self.settings) |settings| {
        var path: ?[]u8 = null;
        try cx.read(settings, settings_model.Settings.copyPath, .{ self.allocator, &path });
        defer if (path) |value| self.allocator.free(value);
        if (path) |value| self.recent.load(self.allocator, self.workspace.io, value, self.workspace.root_path) catch |err| try self.reportError(err);
    }
    if (self.recent.entries.items.len == 0) {
        const root = try self.allocator.dupe(u8, self.workspace.root_path);
        errdefer self.allocator.free(root);
        try self.recent.entries.append(self.allocator, root);
    }
    self.window = window;
    if ((try cx.app.window(window)).surface) |surface| self.system_dark = surface.systemDark();
    if (self.settings == null) try self.loadSettings(cx, null);
    _ = try cx.observe(self.settings.?, Shell.onSettings);
    try self.onSettings(cx, self.settings.?);
    if (self.fields == null) self.fields = try model.Fields.init(cx, self.allocator);
    try self.styleInputs(cx);
    try project_index.start(self, cx);
    try services_git.start(self, cx, .refresh);
    try cx.app.watchExternal(cx.owner, Shell.pollLanguage);
    cx.notify();
}

pub fn loadTree(self: *Shell) !void {
    const entries = try self.workspace.children(self.workspace.root_path, self.allocator);
    defer ws.deinitEntries(entries, self.allocator);
    for (entries) |entry| {
        const row = try copyRow(self.allocator, entry, 0);
        errdefer freeRow(self.allocator, row);
        try self.tree.append(self.allocator, row);
    }
}

pub fn refreshTree(self: *Shell) !void {
    var previous = self.tree;
    self.tree = .empty;
    errdefer {
        for (self.tree.items) |row| freeRow(self.allocator, row);
        self.tree.deinit(self.allocator);
        self.tree = previous;
    }
    try loadTree(self);
    var index: usize = 0;
    while (index < self.tree.items.len) : (index += 1) {
        const row = self.tree.items[index];
        if (!row.directory) continue;
        for (previous.items) |old| if (old.directory and old.expanded and std.mem.eql(u8, old.path, row.path)) {
            expandDirectory(self, index) catch |err| switch (err) {
                error.FileNotFound, error.NotDir, error.AccessDenied => {},
                else => return err,
            };
            break;
        };
    }
    for (previous.items) |row| freeRow(self.allocator, row);
    previous.deinit(self.allocator);
}

/// Reload clean file documents whose disk stamp changed outside the editor.
/// Dirty documents stay untouched so a later save can surface the conflict.
pub fn refreshExternalDocuments(self: *Shell) !bool {
    var changed = false;
    for (self.tabs.items) |*tab| {
        if (!try self.workspace.reloadClean(tab.document)) continue;
        var snapshot = try self.workspace.snapshot(tab.document);
        defer snapshot.deinit();
        tab.editor.synchronize(snapshot);
        if (tab.secondary_state) |*state| state.synchronize(snapshot);
        if (self.secondary) |*pane| if (std.meta.eql(pane.document, tab.document)) pane.editor.synchronize(snapshot);
        for (self.git.editing.views.items) |*view| if (std.meta.eql(view.document, tab.document)) view.editor.synchronize(snapshot);
        services_language.invalidateDocument(self, tab.document) catch |err| try self.reportError(err);
        changed = true;
    }
    return changed;
}

fn copyRow(a: std.mem.Allocator, entry: ws.Entry, depth: u16) !model.TreeRow {
    const name = try a.dupe(u8, entry.name);
    errdefer a.free(name);
    return .{ .name = name, .path = try a.dupe(u8, entry.path), .directory = entry.kind == .directory, .depth = depth };
}

fn freeRow(a: std.mem.Allocator, row: model.TreeRow) void {
    a.free(row.name);
    a.free(row.path);
}

pub fn activateTree(self: *Shell, index: usize) !void {
    if (index >= self.tree.items.len) return;
    const row = self.tree.items[index];
    if (!row.directory) return self.openPath(row.path);
    if (row.expanded) {
        var end = index + 1;
        while (end < self.tree.items.len and self.tree.items[end].depth > row.depth) : (end += 1) freeRow(self.allocator, self.tree.items[end]);
        self.tree.replaceRangeAssumeCapacity(index + 1, end - index - 1, &.{});
        self.tree.items[index].expanded = false;
    } else try expandDirectory(self, index);
}

fn expandDirectory(self: *Shell, index: usize) !void {
    const row = self.tree.items[index];
    const entries = try self.workspace.children(row.path, self.allocator);
    defer ws.deinitEntries(entries, self.allocator);
    var rows: std.ArrayList(model.TreeRow) = .empty;
    defer rows.deinit(self.allocator);
    errdefer for (rows.items) |child| freeRow(self.allocator, child);
    for (entries) |entry| {
        const child = try copyRow(self.allocator, entry, row.depth + 1);
        errdefer freeRow(self.allocator, child);
        try rows.append(self.allocator, child);
    }
    try self.tree.insertSlice(self.allocator, index + 1, rows.items);
    self.tree.items[index].expanded = true;
}
/// Reveal only ancestors of the opened source; do not flatten unrelated folders.
fn revealTreePath(self: *Shell, path: []const u8) !void {
    var index: usize = 0;
    while (index < self.tree.items.len) : (index += 1) {
        const row = self.tree.items[index];
        if (row.directory and !row.expanded and path.len > row.path.len and std.mem.startsWith(u8, path, row.path) and path[row.path.len] == std.fs.path.sep) try expandDirectory(self, index);
    }
}

pub fn openPath(self: *Shell, path: []const u8) !void {
    if (views_image.supported(path)) {
        const absolute = try std.fs.path.resolve(self.allocator, &.{ self.workspace.root_path, path });
        defer self.allocator.free(absolute);
        const asset = try views_image.Asset.init(self.allocator, self.workspace.io, absolute);
        if (self.image) |*old| old.deinit(self.allocator);
        self.image = asset;
        self.image_zoom = 1;
        self.image_scroll = .{};
        self.panel = .image;
        self.overlay = .none;
        return;
    }
    if (self.active_pane != .secondary or self.secondary == null) self.panel = .editor;
    const id = try self.workspace.open(path);
    if ((try self.workspace.getConst(id)).path) |absolute| revealTreePath(self, absolute) catch {};
    for (self.tabs.items, 0..) |tab, i| if (std.meta.eql(tab.document, id)) {
        if (self.active_pane == .secondary and self.secondary != null) {
            try panes.selectSecondary(self, i);
        } else {
            self.tabs.items[i].primary = true;
            self.active = i;
            self.active_pane = .primary;
        }
        self.editor_focus_request +%= 1;
        self.overlay = .none;
        return;
    };
    errdefer _ = self.workspace.close(id, .discard) catch {};
    var view = try editing.Editor.init(self.allocator);
    errdefer view.deinit();
    const record = try self.workspace.getConst(id);
    self.configureEditor(&view, record.path orelse "");
    var snapshot = record.doc.snapshot();
    defer snapshot.deinit();
    view.synchronize(snapshot);
    try self.tabs.append(self.allocator, .{ .document = id, .editor = view });
    if (self.active_pane == .secondary and self.secondary != null) {
        self.tabs.items[self.tabs.items.len - 1].primary = false;
        try panes.selectSecondary(self, self.tabs.items.len - 1);
    } else {
        self.active = self.tabs.items.len - 1;
        self.active_pane = .primary;
    }
    self.editor_focus_request +%= 1;
    self.overlay = .none;
}

pub fn newFile(self: *Shell) !void {
    if (self.active_pane != .secondary or self.secondary == null) self.panel = .editor;
    const id = try self.workspace.untitled("");
    errdefer _ = self.workspace.close(id, .discard) catch {};
    var view = try editing.Editor.init(self.allocator);
    errdefer view.deinit();
    self.configureEditor(&view, "");
    try self.tabs.append(self.allocator, .{ .document = id, .editor = view });
    if (self.active_pane == .secondary and self.secondary != null) {
        self.tabs.items[self.tabs.items.len - 1].primary = false;
        try panes.selectSecondary(self, self.tabs.items.len - 1);
    } else {
        self.active = self.tabs.items.len - 1;
        self.active_pane = .primary;
    }
    self.editor_focus_request +%= 1;
}

pub fn active(self: *Shell) !struct { id: ws.DocumentId, editor: *editing.Editor } {
    if (self.active_pane == .secondary) if (self.secondary) |*pane| return .{ .id = pane.document, .editor = &pane.editor };
    if (self.tabs.items.len == 0) return error.NoDocument;
    return .{ .id = self.tabs.items[self.active].document, .editor = &self.tabs.items[self.active].editor };
}

fn firstDirty(self: *const Shell) ?usize {
    for (self.tabs.items, 0..) |tab, i| {
        if (self.workspace.dirty(tab.document) catch false) return i;
    }
    return null;
}

pub fn saveTarget(self: *const Shell) !usize {
    if (self.pending) |pending| switch (pending) {
        .tab => |i| return i,
        .window => return firstDirty(self) orelse self.active,
    };
    if (self.tabs.items.len == 0) return error.NoDocument;
    if (self.active_pane == .secondary) if (self.secondary) |pane| {
        for (self.tabs.items, 0..) |tab, i| if (std.meta.eql(tab.document, pane.document)) return i;
    };
    return self.active;
}

pub fn requestTabClose(self: *Shell, cx: *ui.Context(Shell), index: usize) !void {
    if (index >= self.tabs.items.len) return;
    if (try self.workspace.dirty(self.tabs.items[index].document)) {
        self.pending = .{ .tab = index };
        try overlays.show(self, cx, .dirty);
    } else try closeTab(self, cx, index, .if_clean);
}

fn closeTab(self: *Shell, cx: *ui.Context(Shell), index: usize, decision: ws.CloseDecision) !void {
    const id = self.tabs.items[index].document;
    if (decision == .if_clean and try self.workspace.dirty(id)) return error.UnsavedChanges;
    if (services_recovery.enabled(self)) {
        try services_recovery.requestClose(self, cx, .{ .document = .{ .id = id, .state = (try self.workspace.getConst(id)).doc.stateId() } });
    } else try finishCloseTab(self, index);
}

pub fn finishCloseTab(self: *Shell, index: usize) !void {
    const id = self.tabs.items[index].document;
    if (!try self.workspace.close(id, .discard)) return;
    self.git.editing.remove(id);
    if (self.git.editable) |*projection| projection.removeSource(id) catch {};
    if (self.preview) |*preview| if (std.meta.eql(preview.document, id)) {
        preview.view.deinit();
        self.preview = null;
        if (self.panel == .markdown) self.panel = .editor;
    };
    var secondary_closed = false;
    if (self.secondary) |*pane| if (std.meta.eql(pane.document, id)) {
        pane.editor.deinit();
        self.secondary = null;
        secondary_closed = true;
    };
    var removed = self.tabs.orderedRemove(index);
    removed.editor.deinit();
    if (removed.secondary_state) |*state| state.deinit();
    if (removed.language_path) |path| self.allocator.free(path);
    if (removed.language_name) |name| self.allocator.free(name);
    self.active = if (self.tabs.items.len == 0) 0 else @min(self.active, self.tabs.items.len - 1);
    if (secondary_closed) {
        var next: ?usize = null;
        for (self.tabs.items, 0..) |tab, i| if (tab.secondary) {
            next = i;
            break;
        };
        if (next) |i| try panes.selectSecondary(self, i) else self.active_pane = .primary;
    }
    panes.normalizePrimary(self);
    self.overlay = .none;
    self.pending = null;
}

fn finishPending(self: *Shell, cx: *ui.Context(Shell)) !void {
    if (self.pending) |pending| switch (pending) {
        .tab => |i| try closeTab(self, cx, i, .if_clean),
        .window => {
            if (firstDirty(self) != null) {
                try overlays.show(self, cx, .dirty);
            } else {
                if (services_recovery.enabled(self)) try services_recovery.requestClose(self, cx, .window_save) else {
                    self.allow_close = true;
                    try cx.app.requestCloseWindow(self.window.?);
                }
            }
        },
    } else self.overlay = .none;
}

pub fn applyOutcome(self: *Shell, cx: *ui.Context(Shell), id: ws.DocumentId, pane: u8, outcome: *editing.Outcome, origin: ws.ChangeOrigin) !void {
    defer if (outcome.change) |change| {
        self.publishDocumentChange(id, origin, change);
        outcome.change = null;
    } else if (outcome.history_reset) |reset| self.publishDocumentReset(id, if (reset.action == .undo) .undo else .redo, reset.before);
    if (outcome.change == null and !outcome.reset) return;
    defer cx.notify();
    self.language.clearCompletion();
    var snapshot = try self.workspace.snapshot(id);
    defer snapshot.deinit();
    for (self.tabs.items) |*tab| if (std.meta.eql(tab.document, id) and pane != 0) {
        if (outcome.change) |*change| tab.editor.mapChange(change);
        tab.editor.synchronize(snapshot);
    };
    for (self.tabs.items) |*tab| if (std.meta.eql(tab.document, id)) if (tab.secondary_state) |*state| {
        if (outcome.change) |*change| state.mapChange(change);
        state.synchronize(snapshot);
    };
    if (self.secondary) |*other| if (std.meta.eql(other.document, id) and pane != 1) {
        if (outcome.change) |*change| other.editor.mapChange(change);
        other.editor.synchronize(snapshot);
    };
    for (self.tabs.items, 0..) |*tab, index| if (std.meta.eql(tab.document, id) and index == self.active) try prepareEditor(self, cx, &tab.editor, snapshot, "primary-editor");
    if (self.secondary) |*other| if (std.meta.eql(other.document, id)) try prepareEditor(self, cx, &other.editor, snapshot, "secondary-editor");
    for (self.git.editing.views.items) |*view| if (std.meta.eql(view.document, id)) {
        if (pane != 2) {
            if (outcome.change) |*change| view.editor.mapChange(change);
            view.editor.synchronize(snapshot);
        }
    };
    if (self.preview) |*preview| if (std.meta.eql(preview.document, id)) try preview.view.refresh(snapshot);
}

pub fn editorInput(self: *Shell, e: *ui.Event(ui.Input), cx: *ui.Context(Shell), pane: u8) !bool {
    if (pane == 1 and self.secondary == null) return false;
    if (pane == 0 and self.tabs.items.len == 0) return false;
    if (e.data == .pointer_down) self.active_pane = if (pane == 0) .primary else .secondary;
    const selected: struct { id: ws.DocumentId, editor: *editing.Editor } = if (pane == 1) .{ .id = self.secondary.?.document, .editor = &self.secondary.?.editor } else .{ .id = self.tabs.items[self.active].document, .editor = &self.tabs.items[self.active].editor };
    const record = try self.workspace.get(selected.id);
    try symbol_hover.pointer(self, cx, selected.editor, &record.doc, selected.id, e);
    if (try editor_git.handle(self, cx, selected.editor, &record.doc, selected.id, e)) return true;
    const old_gutter_hover = selected.editor.gutter_hovered;
    const shortcut = self.key_bindings.resolve(e.data);
    var outcome = if (shortcut == .delete_line or shortcut == .toggle_comment) try selected.editor.execute(&record.doc, if (shortcut == .delete_line) .delete_line else .toggle_comment) else try selected.editor.handle(&record.doc, e);
    errdefer if (outcome.change) |*change| change.deinit();
    if (outcome.handled and (shortcut == .delete_line or shortcut == .toggle_comment)) e.preventDefault();
    if (outcome.request_find) {
        self.vim_find_pending = true;
        try buffer_find.open(self, cx, false);
    }
    if (outcome.request_project_search) try execute(self, cx, .project_search, e);
    if (outcome.change != null or outcome.reset) {
        self.allocator.free(self.status);
        self.status = &.{};
        self.status_is_error = false;
    }
    const changed = outcome.change != null or outcome.reset;
    const origin: ws.ChangeOrigin = if (shortcut == .undo) .undo else if (shortcut == .redo) .redo else .typing;
    try applyOutcome(self, cx, selected.id, pane, &outcome, origin);
    if (changed and self.git.repository) try services_git.start(self, cx, .refresh);
    if (self.language.pending) |pending| if (outcome.handled and (!std.meta.eql(pending.document, selected.id) or pending.cursor != selected.editor.primary().head)) self.language.clearCompletion();
    const typed: []const u8 = switch (e.data) {
        .text => |bytes| bytes,
        .edit => |edit| if (edit.composing) "" else edit.text,
        else => "",
    };
    if (changed and typed.len == 1 and typed[0] == '.') services_language.request(self, cx) catch |err| switch (err) {
        error.NoLanguageServer, error.ServerNotReady, error.CompletionNotSupported => {},
        else => try self.reportError(err),
    };
    if (outcome.handled or old_gutter_hover != selected.editor.gutter_hovered) cx.notify();
    return outcome.handled;
}

pub fn execute(self: *Shell, cx: *ui.Context(Shell), which: Command, event: ?*ui.Event(ui.Input)) !void {
    if (which != .complete) self.language.clearCompletion();
    if (try git_editing.command(self, cx, which)) return;
    if (try git_commands.execute(self, cx, which)) return;
    if (try open_project.command(self, cx, which)) return;
    switch (which) {
        .open_project,
        .browse_project,
        .submit_project,
        .git_changes,
        .git_history,
        .git_network_menu,
        .git_changes_menu,
        .git_branches,
        .git_stashes,
        .git_fetch_from,
        .git_push_to,
        .git_fetch,
        .git_pull,
        .git_pull_rebase,
        .git_push,
        .git_publish,
        .git_force_push,
        .git_stash_all,
        .git_stash_tracked,
        .git_stash_pop,
        .git_stash_apply,
        .git_stash_show,
        .git_create_branch,
        .git_refresh,
        .git_diff_all,
        .git_collapse_all,
        .git_unified_view,
        .git_split_view,
        .git_prepare_commit,
        .git_stage,
        .git_unstage,
        .git_stage_all,
        .git_unstage_all,
        .git_commit,
        .git_working_diff,
        .git_staged_diff,
        .git_open_file,
        => unreachable,
        .show_symbol_info => try symbol_hover.show(self, cx),
        .go_to_definition => services_language.requestDefinition(self, cx) catch |err| switch (err) {
            error.NoLanguageServer, error.ServerNotReady, error.DefinitionNotSupported => {},
            else => return err,
        },
        .cut, .copy, .paste => {
            // Native menu actions arrive through globalInput with the original
            // event surface. Palette actions are handled by the focused editor.
            const current = try active(self);
            var key_event: ui.Event(ui.Input) = .{ .data = .{ .key_down = .{ .key = if (which == .cut) .x else if (which == .copy) .c else .v, .modifiers = .{ .command = true } } } };
            if (self.window) |handle| key_event._surface = (try cx.app.window(handle)).surface;
            if (git_editing.active(self)) {
                try git_editing.clipboard(self, cx, &key_event);
            } else {
                var outcome = try current.editor.handle(&(try self.workspace.get(current.id)).doc, &key_event);
                try applyOutcome(self, cx, current.id, if (self.active_pane == .primary) 0 else 1, &outcome, .typing);
            }
        },
        // Retired actions can still occur in saved key bindings.
        .agent_mode, .agent_transcript, .agent_new, .agent_connect, .agent_send, .agent_cancel, .agent_config, .agent_reload, .agent_context, .agent_toggle_editor, .layout_agentic => {},
        .recent_projects, .language_picker, .language_servers, .editor_options => try workspace_controls.open(self, cx, which),
        .stop_language_servers => {
            self.language_stopped = true;
            self.language.deinit(self.allocator);
        },
        .layout_classic => {
            self.agent_mode = false;
            try cx.update(self.settings.?, settings_model.Settings.apply, .{settings_model.Patch{ .panel_layout = .classic }});
        },
        .toggle_terminal => {
            if (self.terminal.sessions.items.len == 0) try terminal_module.create(self) else {
                self.terminal.visible = !self.terminal.visible;
                self.terminal.focused = self.terminal.visible;
                if (self.terminal.visible) self.terminal.focus +%= 1 else self.editor_focus_request +%= 1;
            }
        },
        .new_terminal => try terminal_module.create(self),
        .terminal_bottom, .terminal_right => {
            self.terminal.dock = if (which == .terminal_bottom) .bottom else .right;
            try cx.update(self.settings.?, settings_model.Settings.apply, .{settings_model.Patch{ .terminal_dock = self.terminal.dock }});
        },
        .show_image => {
            if (self.image != null) self.panel = .image;
        },
        .close_image => {
            if (self.image) |*asset| asset.deinit(self.allocator);
            self.image = null;
            if (self.panel == .image) self.panel = .editor;
        },
        .image_zoom_in => self.image_zoom = @min(8, self.image_zoom * 1.25),
        .image_zoom_out => self.image_zoom = @max(0.1, self.image_zoom / 1.25),
        .image_zoom_reset => self.image_zoom = 1,
        .workspace_menu => self.menu_open = true,
        .project_files => {
            self.sidebar_visible = !(self.sidebar_visible and self.left_panel == .project);
            self.left_panel = .project;
        },
        .markdown_preview => {
            const current = try active(self);
            const record = try self.workspace.getConst(current.id);
            var snapshot = record.doc.snapshot();
            defer snapshot.deinit();
            var preview = try views_markdown.Preview.init(self.allocator, self.workspace.io, record.path, snapshot);
            preview.colors = self.previewColors();
            if (self.preview) |*old| old.view.deinit();
            self.preview = .{ .document = current.id, .view = preview };
            self.panel = .markdown;
        },
        .complete => try services_language.request(self, cx),
        .back_to_editor => {
            if (self.active_pane == .secondary and self.secondary != null) self.secondary_tool = null else self.panel = .editor;
        },
        .extensions => {
            self.agent_mode = false;
            self.showTool(.extensions);
        },
        .install_extension => try overlays.show(self, cx, .extension_path),
        .install_bundled_extension => try services_extensions.installBundled(self, cx),
        .project_search => {
            if (self.currentTool(if (self.active_pane == .secondary) 1 else 0) == .search) {
                if (self.active_pane == .secondary) self.secondary_tool = null else self.panel = .editor;
                return;
            }
            self.showTool(.search);
            self.overlay = .none;
            self.search_focus_request +%= 1;
        },
        .run_project_search => try services_search.start(self, cx),

        .settings => {
            if (self.settings_window) |handle| {
                if (cx.app.raiseWindow(handle)) |_| return else |err| if (err != error.WindowNotFound) return err;
            }
            const View = settings_view.View;
            const handle = try cx.app.openChildWindow(self.window.?, View, .{ .title = "Zircon Settings", .chrome = .integrated, .width = 1000, .height = 700 }, .{ .allocator = self.allocator, .settings = self.settings.?, .workspace = cx.owner, .initial_colors = self.colors, .initial_follows_system = self.follows_system });
            self.settings_window = handle;
            try cx.app.update(try cx.app.windowEntity(View, handle), View.bootstrap, .{handle});
        },
        .new_file => try newFile(self),
        .open_path => try overlays.show(self, cx, .open_path),
        .quick_open => try overlays.show(self, cx, .quick_open),
        .palette => try overlays.show(self, cx, .palette),
        .find => try buffer_find.open(self, cx, false),
        .replace => try buffer_find.open(self, cx, true),
        .toggle_sidebar => self.sidebar_visible = !self.sidebar_visible,
        .split_menu => self.split_menu_open = !self.split_menu_open,
        .restart_language_servers => {
            self.language_stopped = false;
            self.language.deinit(self.allocator);
        },
        .extension_search => try catalog.search(self, cx),
        .install_language_support => try catalog.recommend(self, cx),
        .toggle_vim, .toggle_line_numbers, .toggle_indent_guides, .toggle_inline_blame => {
            const Patch = settings_model.Patch;
            const patch: Patch = switch (which) {
                .toggle_vim => .{ .vim_mode = !self.editor_options.vim_mode },
                .toggle_line_numbers => .{ .line_numbers = !self.editor_options.line_numbers },
                .toggle_indent_guides => .{ .indent_guides = !self.editor_options.indent_guides },
                else => .{ .git_inline_blame = !self.inline_blame_enabled },
            };
            try cx.update(self.settings.?, settings_model.Settings.apply, .{patch});
        },
        .toggle_soft_wrap => try cx.update(self.settings.?, settings_model.Settings.apply, .{settings_model.Patch{ .soft_wrap = if (self.editor_options.soft_wrap == .none) .editor_width else .none }}),
        .git_next_change, .git_previous_change, .git_toggle_hunk => {
            if (self.currentTool(if (self.active_pane == .secondary) 1 else 0) == .git_diff) {
                try git_diff_controls.navigate(self, cx, which);
                return;
            }
            const current = try active(self);
            const record = try self.workspace.getConst(current.id);
            var snapshot = record.doc.snapshot();
            defer snapshot.deinit();
            const row = (try snapshot.pointAt(current.editor.primary().head)).line;
            const changes = current.editor.visibleChanges(snapshot.revision());
            if (changes.len > 0) {
                var index: usize = 0;
                if (which == .git_toggle_hunk) {
                    for (changes, 0..) |change, i| if (row >= change.start and row < @max(change.end, change.start + 1)) {
                        current.editor.git_changes[i].expanded = !change.expanded;
                        break;
                    };
                } else {
                    if (which == .git_next_change) {
                        for (changes, 0..) |change, i| if (change.start > row) {
                            index = i;
                            break;
                        };
                    } else {
                        index = changes.len - 1;
                        var i = changes.len;
                        while (i > 0) {
                            i -= 1;
                            if (changes[i].start < row) {
                                index = i;
                                break;
                            }
                        }
                    }
                    const position = try snapshot.lineStart(@min(changes[index].start, snapshot.lineCount() - 1));
                    try current.editor.setSelection(snapshot, .{ .start = position, .end = position });
                    current.editor.reveal(snapshot);
                }
            }
        },
        .git_blame => {
            const current = try active(self);
            if (current.editor.inline_blame != null and current.editor.inline_blame.?.expanded) {
                current.editor.hideBlame();
                current.editor.blame_pinned = false;
                current.editor.blame_hovered = false;
            } else {
                current.editor.blame_pinned = true;
                const record = try self.workspace.getConst(current.id);
                var snapshot = record.doc.snapshot();
                defer snapshot.deinit();
                const point = try snapshot.pointAt(current.editor.primary().head);
                try services_git.start(self, cx, .{ .blame = .{ .line = point.line + 1 } });
            }
        },
        .split_left, .split_right, .split_up, .split_down, .close_split, .split => {
            if (self.secondary != null and (which == .split or which == .close_split)) {
                panes.closeSplit(self);
            } else if (which != .close_split and self.secondary == null) {
                try panes.selectSecondary(self, self.active);
            }
            if (which != .split and which != .close_split) {
                self.split_vertical = which == .split_up or which == .split_down;
                self.split_reverse = which == .split_left or which == .split_up;
                self.split_ratio = 0.5;
                self.active_pane = .secondary;
            }
            self.panel = .editor;
        },
        .save => {
            const index = try saveTarget(self);
            const record = try self.workspace.getConst(self.tabs.items[index].document);
            if (record.path == null) try overlays.show(self, cx, .save_as) else {
                try self.workspace.save(self.tabs.items[index].document, null);
                historyBoundary(self, self.tabs.items[index].document);
                try self.setStatus(try self.allocator.dupe(u8, "Saved"));
            }
        },
        .save_as => try overlays.show(self, cx, .save_as),
        .close_tab => {
            const pane: u8 = if (self.active_pane == .secondary) 1 else 0;
            if (self.currentTool(pane)) |tool| {
                var click: ui.Event(ui.Click) = .{ .data = .{} };
                if (tool == .git_diff and self.git.selected_commit.len > 0) {
                    for (self.git.history_tabs.items, 0..) |tab, index| if (std.mem.eql(u8, tab.oid, self.git.selected_commit)) {
                        self.onCloseHistoryTab(&click, cx, @intCast(index));
                        return;
                    };
                }
                self.onCloseTool(&click, cx, .{ .tool = tool, .pane = pane });
                return;
            }
            if (pane == 1 and self.secondary != null) {
                const index = try saveTarget(self);
                if (self.tabs.items[index].primary) panes.closeSecondaryTab(self, index) else try requestTabClose(self, cx, index);
            } else if (self.panel == .image) {
                if (self.image) |*asset| asset.deinit(self.allocator);
                self.image = null;
                self.panel = .editor;
            } else if (self.tabs.items.len > 0) {
                const index = try saveTarget(self);
                if (self.tabs.items[index].secondary) panes.closePrimaryTab(self, index) else try requestTabClose(self, cx, index);
            }
        },
        .quit => try cx.app.requestCloseWindow(self.window.?),
        .dismiss => {
            self.overlay = .none;
            self.vim_find_pending = false;
            self.pending = null;
        },
        .discard_dirty => {
            if (self.pending) |pending| switch (pending) {
                .tab => |i| try closeTab(self, cx, i, .discard),
                .window => {
                    if (services_recovery.enabled(self)) try services_recovery.requestClose(self, cx, .{ .window_discard = try services_recovery.fingerprint(self) }) else {
                        self.allow_close = true;
                        try cx.app.requestCloseWindow(self.window.?);
                    }
                },
            };
        },
        .save_dirty => {
            const index = try saveTarget(self);
            const id = self.tabs.items[index].document;
            const record = try self.workspace.getConst(id);
            if (record.path == null) try overlays.show(self, cx, .save_as) else {
                try self.workspace.save(id, null);
                historyBoundary(self, id);
                try finishPending(self, cx);
            }
        },
        .submit_path => {
            const bytes = try field_input.read(cx, self.fields.?.workspace.path, self.allocator);
            defer self.allocator.free(bytes);
            const path = std.mem.trim(u8, bytes, " \t");
            if (path.len == 0) return error.InvalidPath;
            if (self.overlay == .extension_path) {
                try services_extensions.install(self, cx, path);
                self.overlay = .none;
            } else if (self.overlay == .open_path) {
                try openPath(self, path);
            } else {
                const index = try saveTarget(self);
                const id = self.tabs.items[index].document;
                try self.workspace.save(id, path);
                historyBoundary(self, id);
                const record = try self.workspace.getConst(id);
                var snapshot = record.doc.snapshot();
                defer snapshot.deinit();
                for (self.tabs.items) |*tab| if (std.meta.eql(tab.document, id)) {
                    self.configureEditor(&tab.editor, record.path.?);
                    tab.editor.synchronize(snapshot);
                    if (tab.secondary_state) |*state| {
                        self.configureEditor(state, record.path.?);
                        state.synchronize(snapshot);
                    }
                };
                if (self.secondary) |*pane| if (std.meta.eql(pane.document, id)) {
                    self.configureEditor(&pane.editor, record.path.?);
                    pane.editor.synchronize(snapshot);
                };
                for (self.git.editing.views.items) |*view| if (std.meta.eql(view.document, id)) {
                    self.configureEditor(&view.editor, record.path.?);
                    view.editor.synchronize(snapshot);
                };
                try services_language.invalidateDocument(self, id);
                self.overlay = .none;
                try finishPending(self, cx);
            }
        },
        .find_next, .find_previous, .replace_one, .replace_all => {
            const finder = buffer_find;
            const current = try active(self);
            if (!self.find.visible and (which == .replace_one or which == .replace_all)) return finder.open(self, cx, true);
            try finder.bind(self, cx, current.id, if (self.active_pane == .secondary) 1 else 0);
            return finder.action(self, cx, which);
        },
        .toggle_comment, .delete_line, .undo, .redo, .select_all => {
            const current = try active(self);
            const record = try self.workspace.get(current.id);
            var result = try current.editor.execute(&record.doc, switch (which) {
                .delete_line => .delete_line,
                .toggle_comment => .toggle_comment,
                .undo => .undo,
                .redo => .redo,
                else => .select_all,
            });
            try applyOutcome(self, cx, current.id, if (self.active_pane == .primary) 0 else 1, &result, if (which == .undo) .undo else if (which == .redo) .redo else .project_edit);
        },
        .zoom_in, .zoom_out => {
            const current = try active(self);
            current.editor.font_size = std.math.clamp(current.editor.font_size + @as(f32, if (which == .zoom_in) 1 else -1), 10, 26);
            current.editor.line_height = current.editor.font_size + 8;
        },
    }
    _ = event;
}

pub fn rootInput(self: *Shell, e: *ui.Event(ui.Input), cx: *ui.Context(Shell)) !void {
    if (e.data == .close) try services_recovery.validateClose(self, cx);
    if (e.data == .close and !self.allow_close and firstDirty(self) != null) {
        self.pending = .window;
        try overlays.show(self, cx, .dirty);
        e.preventDefault();
        cx.notify();
    } else if (e.data == .close and !self.allow_close and services_recovery.enabled(self)) {
        e.preventDefault();
        if (self.recovery.?.close == null) try services_recovery.requestClose(self, cx, .window_save);
    }
}

pub fn globalInput(self: *Shell, e: *ui.Event(ui.Input), cx: *ui.Context(Shell)) !void {
    symbol_hover.dismissOutside(self, cx, e.data);
    if (e.data == .action) {
        const which = std.enums.fromInt(Command, e.data.action) orelse return;
        // Clipboard actions stay on the focused text input, including search
        // and commit fields. Other actions use the application's command path.
        if (which == .cut or which == .copy or which == .paste or which == .select_all or which == .undo or which == .redo) {
            e.data = .{ .key_down = .{ .key = switch (which) {
                .cut => .x,
                .copy => .c,
                .paste => .v,
                .select_all => .a,
                else => .z,
            }, .modifiers = .{ .command = true, .shift = which == .redo } } };
        } else {
            self.menu_open = false;
            execute(self, cx, which, e) catch |err| try self.reportError(err);
            e.preventDefault();
            e.stopPropagation();
            cx.notify();
            return;
        }
    }
    if (try workspace_controls.input(self, e, cx)) return;
    if (self.popup == .none and self.overlay == .none and self.terminal.visible and self.terminal.focused and e.data == .key_down) {
        const key = e.data.key_down;
        if (!key.modifiers.command or key.key == .v or key.key == .c or key.key == .a) return;
        if (key.modifiers.command and key.key == .w) {
            try terminal_module.closeActive(self, cx);
            e.preventDefault();
            e.stopPropagation();
            return;
        }
    }
    editor_git.dismissOutside(self, cx, e);
    if (e.data == .focus and !e.data.focus) self.dragging = .none;
    if (e.data == .appearance) {
        if (self.system_dark == e.data.appearance) return;
        self.system_dark = e.data.appearance;
        if (self.settings) |settings| try self.onSettings(cx, settings);
        return;
    }
    if (e.data != .key_down) return;
    const key = e.data.key_down;
    if (self.overlay == .none and self.find.visible and key.key == .escape) {
        buffer_find.close(self, cx);
        e.preventDefault();
        e.stopPropagation();
        return;
    }
    if (try git_controls.input(self, e, cx)) return;
    if ((self.menu_open or self.split_menu_open) and key.key == .escape) {
        self.menu_open = false;
        self.split_menu_open = false;
        e.preventDefault();
        e.stopPropagation();
        cx.notify();
        return;
    }
    if (self.tab_drag != null and key.key == .escape) {
        panes.cancel(self);
        e.releasePointer();
        e.preventDefault();
        e.stopPropagation();
        cx.notify();
        return;
    }
    if (self.overlay == .none and key.key == .escape and self.tabs.items.len > 0) {
        const current = try active(self);
        if (current.editor.inline_blame != null and current.editor.inline_blame.?.expanded) {
            current.editor.hideBlame();
            current.editor.blame_pinned = false;
            current.editor.blame_hovered = false;
            e.preventDefault();
            e.stopPropagation();
            cx.notify();
            return;
        }
    }
    if (self.overlay == .none and self.language.completions != null and (key.key == .escape or key.key == .enter or key.key == .up or key.key == .down)) {
        if (key.key == .enter) services_language.accept(self, cx, @intCast(self.language.completion_index)) catch |err| try self.reportError(err) else if (key.key == .escape) self.language.clearCompletion() else {
            const count = self.language.completions.?.data.completion.items.len;
            if (count > 0) self.language.completion_index = if (key.key == .down) (self.language.completion_index + 1) % count else (self.language.completion_index + count - 1) % count;
        }
        e.preventDefault();
        e.stopPropagation();
        cx.notify();
        return;
    }
    if (self.overlay != .none) {
        if (key.key == .escape) {
            self.overlay = .none;
            self.pending = null;
            e.preventDefault();
            e.stopPropagation();
            cx.notify();
            return;
        }
        if (key.key == .enter) {
            const which: Command = switch (self.overlay) {
                .open_project => .submit_project,
                .open_path, .save_as, .extension_path => .submit_path,
                .find, .replace => if (key.modifiers.shift) .find_previous else .find_next,
                .project_search => .run_project_search,
                else => .dismiss,
            };
            if (self.overlay == .palette or self.overlay == .quick_open) try overlays.activateSelected(self, cx) else execute(self, cx, which, e) catch |err| try self.reportError(err);
            if (self.vim_find_pending and self.overlay == .find) {
                self.vim_find_pending = false;
                self.overlay = .none;
                self.editor_focus_request +%= 1;
            }
            e.preventDefault();
            e.stopPropagation();
            cx.notify();
            return;
        }
        if ((key.key == .down or key.key == .up) and (self.overlay == .palette or self.overlay == .quick_open)) {
            const count = try overlays.filteredCount(self, cx);
            if (count > 0) self.overlay_index = if (key.key == .down) (self.overlay_index + 1) % count else (self.overlay_index + count - 1) % count;
            e.preventDefault();
            e.stopPropagation();
            cx.notify();
        }
        return;
    }
    if (self.key_bindings.resolve(e.data)) |which| {
        if (which == .delete_line or which == .toggle_comment) return;
        execute(self, cx, which, e) catch |err| try self.reportError(err);
        e.preventDefault();
        e.stopPropagation();
        cx.notify();
    }
}

pub fn drag(self: *Shell, e: *ui.Event(ui.Input), cx: *ui.Context(Shell), kind: u8) !void {
    switch (e.data) {
        .pointer_down => |pointer| {
            if (pointer.button != .primary) return;
            self.dragging = if (kind == 0) .sidebar else .split;
            e.capturePointer();
        },
        .pointer_move => |pointer| {
            if (self.dragging == .none) return;
            const size = try e.windowSize();
            if (self.dragging == .sidebar) {
                const width = std.math.clamp(pointer.position.x, 120, @min(480, @max(120, size.width * 0.4)));
                if (self.left_panel == .project) self.sidebar_width = width else self.git_sidebar_width = width;
            } else {
                const start = if (self.sidebar_visible) @min(self.panelWidth(), @max(140, size.width * 0.4)) + 5 else 0;
                const ratio = if (self.split_vertical) (pointer.position.y - 66) / @max(1, size.height - 90) else (pointer.position.x - start) / @max(1, size.width - start);
                self.split_ratio = std.math.clamp(if (self.split_reverse) 1 - ratio else ratio, 0.2, 0.8);
            }
        },
        .pointer_up => {
            self.dragging = .none;
            e.releasePointer();
        },
        else => return,
    }
    e.preventDefault();
    cx.notify();
}

fn historyBoundary(self: *Shell, id: ws.DocumentId) void {
    const record = self.workspace.get(id) catch return;
    record.doc.breakHistoryGroup();
    for (self.tabs.items) |*tab| if (std.meta.eql(tab.document, id)) {
        tab.editor.typing_group = 0;
    };
    if (self.secondary) |*pane| if (std.meta.eql(pane.document, id)) {
        pane.editor.typing_group = 0;
    };
}

pub fn prepareEditor(self: *Shell, cx: *ui.Context(Shell), state: *editing.Editor, snapshot: text.Snapshot, key: []const u8) !void {
    if (state.soft_wrap == .none) {
        state.reveal(snapshot);
        return;
    }
    const handle = self.window orelse return;
    const window = try cx.app.window(handle);
    var viewport = state.last_viewport;
    for (window.frames.committed.nodes.items, 0..) |node, i| if (node.key) |id| if (id == .string and std.mem.eql(u8, id.string, key)) {
        const bounds = window.frames.committed.bounds[i];
        viewport = .{ .width = bounds.width, .height = bounds.height };
        break;
    };
    var fixed: ui.layout.FixedMetrics = .{ .advance = state.font_size * 0.6, .line_height = state.line_height };
    const metrics = if (window.surface) |surface| surface.measurer() else fixed.measurer();
    try state.prepareView(snapshot, viewport, metrics);
}
