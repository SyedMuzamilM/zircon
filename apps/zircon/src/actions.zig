//! Application commands and file policy. Editing is delegated to zircon_editor;
//! persistence is delegated to zircon_workspace. Errors leave the view usable.
const std = @import("std");
const ui = @import("zircon_ui");
const editing = @import("zircon_editor");
const text = @import("zircon_text");
const ws = @import("zircon_workspace");
const model = @import("shell.zig");
const Shell = model.Shell;
const Command = @import("commands.zig").Command;
pub fn bootstrap(self: *Shell, cx: *ui.Context(Shell), window: ui.WindowHandle) !void {
    self.window = window;
    if ((try cx.app.window(window)).surface) |surface| self.system_dark = surface.systemDark();
    if (self.settings == null) try self.loadSettings(cx, null);
    _ = try cx.observe(self.settings.?, Shell.onSettings);
    try self.onSettings(cx, self.settings.?);
    if (self.fields == null) {
        const query = try cx.createChild(ui.controls.TextInput, try ui.controls.TextInput.init(self.allocator, ""));
        var project_input = try ui.controls.TextInput.init(self.allocator, "");
        project_input.leading_icon = .search;
        project_input.placeholder = "Search project files and open buffers…";
        var extension_input = try ui.controls.TextInput.init(self.allocator, "");
        extension_input.leading_icon = .search;
        extension_input.placeholder = "Search Zed extensions…";
        const extension_query = try cx.createChild(ui.controls.TextInput, extension_input);
        const project_query = try cx.createChild(ui.controls.TextInput, project_input);
        const replacement = try cx.createChild(ui.controls.TextInput, try ui.controls.TextInput.init(self.allocator, ""));
        const destination = try cx.createChild(ui.controls.TextInput, try ui.controls.TextInput.init(self.allocator, ""));
        const path = try cx.createChild(ui.controls.TextInput, try ui.controls.TextInput.init(self.allocator, ""));
        var commit_input = try ui.controls.TextInput.init(self.allocator, "");
        commit_input.placeholder = "Commit message…";
        const commit = cx.createChild(ui.controls.TextInput, commit_input) catch |err| {
            commit_input.deinit(self.allocator);
            return err;
        };
        self.fields = .{ .extension_query = extension_query, .query = query, .project_query = project_query, .replacement = replacement, .path = path, .destination = destination, .commit = commit };
    }
    _ = try cx.observe(self.fields.?.path, Shell.onGitPickerQuery);
    try self.styleInputs(cx);
    try @import("project_index.zig").start(self, cx);
    try @import("services/git.zig").start(self, cx, .refresh);
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
    for (self.tree.items) |row| freeRow(self.allocator, row);
    self.tree.clearRetainingCapacity();
    try loadTree(self);
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
    if (@import("views/image.zig").supported(path)) {
        const absolute = try std.fs.path.resolve(self.allocator, &.{ self.workspace.root_path, path });
        defer self.allocator.free(absolute);
        const asset = try @import("views/image.zig").Asset.init(self.allocator, self.workspace.io, absolute);
        if (self.image) |*old| old.deinit(self.allocator);
        self.image = asset;
        self.panel = .image;
        self.overlay = .none;
        return;
    }
    self.panel = .editor;
    const id = try self.workspace.open(path);
    if ((try self.workspace.getConst(id)).path) |absolute| revealTreePath(self, absolute) catch {};
    for (self.tabs.items, 0..) |tab, i| if (std.meta.eql(tab.document, id)) {
        self.active = i;
        self.active_pane = .primary;
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
    self.active = self.tabs.items.len - 1;
    self.active_pane = .primary;
    self.editor_focus_request +%= 1;
    self.overlay = .none;
}
pub fn newFile(self: *Shell) !void {
    const id = try self.workspace.untitled("");
    errdefer _ = self.workspace.close(id, .discard) catch {};
    var view = try editing.Editor.init(self.allocator);
    errdefer view.deinit();
    self.configureEditor(&view, "");
    try self.tabs.append(self.allocator, .{ .document = id, .editor = view });
    self.active = self.tabs.items.len - 1;
    self.active_pane = .primary;
    self.editor_focus_request +%= 1;
}
pub fn active(self: *Shell) !struct { id: ws.DocumentId, editor: *editing.Editor } {
    if (self.active_pane == .secondary) if (self.secondary) |*pane| return .{ .id = pane.document, .editor = &pane.editor };
    if (self.tabs.items.len == 0) return error.NoDocument;
    return .{ .id = self.tabs.items[self.active].document, .editor = &self.tabs.items[self.active].editor };
}
fn field(cx: *ui.Context(Shell), handle: ui.Entity(ui.controls.TextInput), a: std.mem.Allocator) ![]u8 {
    var bytes: []u8 = undefined;
    try cx.read(handle, ui.controls.TextInput.copy, .{ a, &bytes });
    return bytes;
}
fn setField(cx: *ui.Context(Shell), handle: ui.Entity(ui.controls.TextInput), value: []const u8, placeholder: []const u8) !void {
    const Update = struct {
        fn call(input: *ui.controls.TextInput, context: *ui.Context(ui.controls.TextInput), bytes: []const u8, label: []const u8) !void {
            try input.bytes.ensureTotalCapacity(input.allocator, bytes.len);
            input.bytes.clearRetainingCapacity();
            input.bytes.appendSliceAssumeCapacity(bytes);
            input.cursor = bytes.len;
            input.anchor = bytes.len;
            input.marked = null;
            input.revision +%= 1;
            input.placeholder = label;
            context.notify();
        }
    };
    try cx.update(handle, Update.call, .{ value, placeholder });
}
fn show(self: *Shell, cx: *ui.Context(Shell), which: model.Overlay) !void {
    self.overlay = which;
    self.overlay_index = 0;
    if (self.fields) |fields| {
        const SetQuery = struct {
            fn call(input: *ui.controls.TextInput, context: *ui.Context(ui.controls.TextInput), picker: bool) void {
                input.height = if (picker) 38 else 30;
                input.font_size = if (picker) 14 else 13;
                input.leading_icon = if (picker) .search else null;
                input.show_focus_border = !picker;
                context.notify();
            }
        };
        try cx.update(fields.query, SetQuery.call, .{which == .palette or which == .quick_open});
    }
    if (self.fields) |fields| switch (which) {
        .palette => try setField(cx, fields.query, "", "Search commands…"),
        .quick_open => try setField(cx, fields.query, "", "Find a file…"),
        .open_path => try setField(cx, fields.path, "", "Path relative to the project, or an absolute path"),
        .extension_path => try setField(cx, fields.path, "", "Directory containing extension.json"),
        .save_as => {
            const selected = try saveTarget(self);
            const record = try self.workspace.getConst(self.tabs.items[selected].document);
            try setField(cx, fields.path, record.path orelse "untitled.zig", "Save file as…");
        },
        .find, .replace => try setField(cx, fields.query, "", "Find in document…"),
        else => {},
    };
}
fn firstDirty(self: *const Shell) ?usize {
    for (self.tabs.items, 0..) |tab, i| {
        if (self.workspace.dirty(tab.document) catch false) return i;
    }
    return null;
}
fn saveTarget(self: *const Shell) !usize {
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
        try show(self, cx, .dirty);
    } else try closeTab(self, index, .if_clean);
}
fn closeTab(self: *Shell, index: usize, decision: ws.CloseDecision) !void {
    const id = self.tabs.items[index].document;
    if (!try self.workspace.close(id, decision)) return;
    if (self.preview) |*preview| if (std.meta.eql(preview.document, id)) {
        preview.view.deinit();
        self.preview = null;
        if (self.panel == .markdown) self.panel = .editor;
    };
    if (self.secondary) |*pane| if (std.meta.eql(pane.document, id)) {
        pane.editor.deinit();
        self.secondary = null;
        self.active_pane = .primary;
    };
    var removed = self.tabs.orderedRemove(index);
    removed.editor.deinit();
    self.active = if (self.tabs.items.len == 0) 0 else @min(self.active, self.tabs.items.len - 1);
    self.overlay = .none;
    self.pending = null;
}
fn finishPending(self: *Shell, cx: *ui.Context(Shell)) !void {
    if (self.pending) |pending| switch (pending) {
        .tab => |i| try closeTab(self, i, .if_clean),
        .window => {
            if (firstDirty(self) != null) {
                try show(self, cx, .dirty);
            } else {
                self.allow_close = true;
                try cx.app.requestCloseWindow(self.window.?);
            }
        },
    } else self.overlay = .none;
}
pub fn applyOutcome(self: *Shell, cx: *ui.Context(Shell), id: ws.DocumentId, pane: u8, outcome: *editing.Outcome) !void {
    defer if (outcome.change) |*change| change.deinit();
    if (outcome.change == null and !outcome.reset) return;
    self.language.clearCompletion();
    var snapshot = try self.workspace.snapshot(id);
    defer snapshot.deinit();
    for (self.tabs.items) |*tab| if (std.meta.eql(tab.document, id) and pane != 0) {
        if (outcome.change) |*change| tab.editor.mapChange(change);
        tab.editor.synchronize(snapshot);
    };
    if (self.secondary) |*other| if (std.meta.eql(other.document, id) and pane != 1) {
        if (outcome.change) |*change| other.editor.mapChange(change);
        other.editor.synchronize(snapshot);
    };
    for (self.tabs.items, 0..) |*tab, index| if (std.meta.eql(tab.document, id) and index == self.active) try prepareEditor(self, cx, &tab.editor, snapshot, "primary-editor");
    if (self.secondary) |*other| if (std.meta.eql(other.document, id)) try prepareEditor(self, cx, &other.editor, snapshot, "secondary-editor");
    if (self.preview) |*preview| if (std.meta.eql(preview.document, id)) try preview.view.refresh(snapshot);
}
pub fn editorInput(self: *Shell, e: *ui.Event(ui.Input), cx: *ui.Context(Shell), pane: u8) !bool {
    if (pane == 1 and self.secondary == null) return false;
    if (pane == 0 and self.tabs.items.len == 0) return false;
    if (e.data == .pointer_down) self.active_pane = if (pane == 0) .primary else .secondary;
    const selected: struct { id: ws.DocumentId, editor: *editing.Editor } = if (pane == 1) .{ .id = self.secondary.?.document, .editor = &self.secondary.?.editor } else .{ .id = self.tabs.items[self.active].document, .editor = &self.tabs.items[self.active].editor };
    const record = try self.workspace.get(selected.id);
    if (try @import("editor_git.zig").handle(self, cx, selected.editor, &record.doc, selected.id, e)) return true;
    var outcome = if (self.key_bindings.resolve(e.data) == .delete_line) try selected.editor.execute(&record.doc, .delete_line) else try selected.editor.handle(&record.doc, e);
    if (outcome.handled and self.key_bindings.resolve(e.data) == .delete_line) e.preventDefault();
    if (outcome.request_find) {
        self.vim_find_pending = true;
        try show(self, cx, .find);
    }
    if (outcome.change != null or outcome.reset) {
        self.allocator.free(self.status);
        self.status = &.{};
        self.status_is_error = false;
        if (self.git.repository) try @import("services/git.zig").start(self, cx, .refresh);
    }
    try applyOutcome(self, cx, selected.id, pane, &outcome);
    if (outcome.handled) cx.notify();
    return outcome.handled;
}
pub fn execute(self: *Shell, cx: *ui.Context(Shell), which: Command, event: ?*ui.Event(ui.Input)) !void {
    if (which != .complete) self.language.clearCompletion();
    switch (which) {
        .open_project => {
            self.overlay = .open_project;
            self.open_kind = .local_folder;
            try setField(cx, self.fields.?.path, "", "Folder path or Git repository URL");
        },
        .browse_project => {
            if (try (try cx.app.window(self.window.?)).surface.?.choosePath(self.allocator, .folder)) |path| {
                defer self.allocator.free(path);
                try setField(cx, self.fields.?.path, path, "Folder path");
            }
        },
        .submit_project => {
            const path = try field(cx, self.fields.?.path, self.allocator);
            defer self.allocator.free(path);
            const requested = std.mem.trim(u8, path, " \t");
            if (requested.len == 0) return error.InvalidPath;
            if (self.open_kind == .clone) {
                const destination = try field(cx, self.fields.?.destination, self.allocator);
                defer self.allocator.free(destination);
                if (std.mem.trim(u8, destination, " \t").len == 0) return error.InvalidPath;
                try @import("projects.zig").clone(self, cx, requested, destination);
            } else _ = try @import("projects.zig").open(self, cx, requested, self.open_kind);
        },
        .workspace_menu => self.menu_open = true,
        .project_files => {
            self.left_panel = .project;
            self.sidebar_visible = true;
        },
        .markdown_preview => {
            const current = try active(self);
            const record = try self.workspace.getConst(current.id);
            var snapshot = record.doc.snapshot();
            defer snapshot.deinit();
            var preview = try @import("views/markdown.zig").Preview.init(self.allocator, self.workspace.io, record.path, snapshot);
            preview.colors = self.previewColors();
            if (self.preview) |*old| old.view.deinit();
            self.preview = .{ .document = current.id, .view = preview };
            self.panel = .markdown;
        },
        .complete => try @import("services/language.zig").request(self, cx),
        .git_changes => {
            self.git.stash_view = false;
            std.heap.page_allocator.free(self.git.selected_commit);
            self.git.selected_commit = &.{};
            std.heap.page_allocator.free(self.git.selected_path);
            self.git.selected_path = &.{};
            self.git.combined = true;
            self.panel = .git_diff;
            self.left_panel = .git_changes;
            self.git.sidebar_scroll.offset = 0;
            self.sidebar_visible = true;
            try @import("services/git.zig").start(self, cx, .all_diff);
        },
        .git_history => {
            self.left_panel = .git_history;
            self.git.sidebar_scroll.offset = 0;
            self.sidebar_visible = true;
            try @import("services/git.zig").start(self, cx, .refresh);
        },
        .git_network_menu => self.git.menu = .network,
        .git_changes_menu => self.git.menu = .changes,
        .git_branches => {
            self.git.needs_metadata = true;
            self.git.picker_index = 0;
            self.git.picker_scroll.offset = 0;
            self.git.menu = .branches;
            try setField(cx, self.fields.?.path, "", "Switch or type to create a branch…");
            try @import("services/git.zig").start(self, cx, .refresh);
        },
        .git_stashes => {
            self.git.needs_metadata = true;
            self.git.picker_index = 0;
            self.git.picker_scroll.offset = 0;
            std.heap.page_allocator.free(self.git.stash_oid);
            self.git.stash_oid = &.{};
            self.git.menu = .stashes;
            self.git.stash_selected = null;
            try setField(cx, self.fields.?.path, "", "Search stashes…");
            try @import("services/git.zig").start(self, cx, .refresh);
        },
        .git_fetch_from, .git_push_to => {
            self.git.picker_index = 0;
            self.git.picker_scroll.offset = 0;
            self.git.menu = if (which == .git_fetch_from) .fetch_remote else .push_remote;
            try setField(cx, self.fields.?.path, "", "Search remotes…");
        },
        .git_fetch => try @import("services/git.zig").start(self, cx, .{ .network = .{ .fetch = "" } }),
        .git_pull, .git_pull_rebase => try @import("services/git.zig").start(self, cx, .{ .network = .{ .pull = which == .git_pull_rebase } }),
        .git_push, .git_publish, .git_force_push => {
            const remote = @import("views/git_controls.zig").defaultRemote(self);
            try @import("services/git.zig").start(self, cx, .{ .network = .{ .push = .{ .remote = if (which == .git_publish) remote else "", .publish = which == .git_publish, .force_with_lease = which == .git_force_push } } });
        },
        .git_stash_all, .git_stash_tracked => try @import("services/git.zig").start(self, cx, .{ .stash_save = which == .git_stash_all }),
        .git_stash_pop, .git_stash_apply, .git_stash_show => try @import("views/git_controls.zig").stashAction(self, cx, which),
        .git_create_branch => {
            const name = try field(cx, self.fields.?.path, self.allocator);
            defer self.allocator.free(name);
            try @import("services/git.zig").start(self, cx, .{ .switch_branch = .{ .name = std.mem.trim(u8, name, " "), .create = true } });
            self.git.menu = .none;
        },
        .git_refresh => {
            self.git.needs_metadata = true;
            try @import("services/git.zig").start(self, cx, .refresh);
        },
        .git_diff_all => {
            self.git.stash_view = false;
            self.git.combined = true;
            std.heap.page_allocator.free(self.git.selected_path);
            std.heap.page_allocator.free(self.git.selected_commit);
            self.git.selected_path = &.{};
            self.git.selected_commit = &.{};
            self.panel = .git_diff;
            try @import("services/git.zig").start(self, cx, .all_diff);
        },
        .git_stage => try @import("services/git.zig").start(self, cx, .{ .stage = self.git.selected_path }),
        .git_unstage => try @import("services/git.zig").start(self, cx, .{ .unstage = self.git.selected_path }),
        .git_stage_all => try @import("services/git.zig").start(self, cx, .stage_all),
        .git_unstage_all => try @import("services/git.zig").start(self, cx, .unstage_all),
        .git_commit => {
            const message = try field(cx, self.fields.?.commit, self.allocator);
            defer self.allocator.free(message);
            if (std.mem.trim(u8, message, " \t\r\n").len == 0) return error.EmptyCommitMessage;
            try @import("services/git.zig").start(self, cx, .{ .commit = message });
        },
        .git_working_diff, .git_staged_diff => {
            self.git.combined = false;
            std.heap.page_allocator.free(self.git.selected_commit);
            self.git.selected_commit = &.{};
            self.panel = .git_diff;
            try @import("services/git.zig").start(self, cx, .{ .diff = .{ .path = self.git.selected_path, .staged = which == .git_staged_diff } });
        },
        .git_open_file => {
            const absolute = try std.fs.path.join(self.allocator, &.{ self.workspace.root_path, self.git.selected_path });
            defer self.allocator.free(absolute);
            try self.openPath(absolute);
            self.panel = .editor;
        },
        .back_to_editor => self.panel = .editor,
        .extensions => self.panel = .extensions,
        .install_extension => try show(self, cx, .extension_path),
        .install_bundled_extension => try @import("services/extensions.zig").installBundled(self, cx),
        .project_search => {
            self.panel = .search;
            self.tool_tabs.search = true;
            self.overlay = .none;
            self.search_focus_request +%= 1;
        },
        .run_project_search => try @import("services/search.zig").start(self, cx),

        .settings => {
            if (self.settings_window) |handle| {
                if (cx.app.raiseWindow(handle)) |_| return else |err| if (err != error.WindowNotFound) return err;
            }
            const View = @import("settings/view.zig").View;
            const handle = try cx.app.openChildWindow(self.window.?, View, .{ .title = "Zircon Settings", .chrome = .integrated, .width = 1000, .height = 700 }, .{ .allocator = self.allocator, .settings = self.settings.?, .workspace = cx.owner, .initial_colors = self.colors, .initial_follows_system = self.follows_system });
            self.settings_window = handle;
            try cx.app.update(try cx.app.windowEntity(View, handle), View.bootstrap, .{handle});
        },
        .new_file => try newFile(self),
        .open_path => try show(self, cx, .open_path),
        .quick_open => try show(self, cx, .quick_open),
        .palette => try show(self, cx, .palette),
        .find => try show(self, cx, .find),
        .replace => try show(self, cx, .replace),
        .toggle_sidebar => self.sidebar_visible = !self.sidebar_visible,
        .split_menu => self.split_menu_open = !self.split_menu_open,
        .restart_language_servers => self.language.deinit(self.allocator),
        .extension_search => try @import("services/catalog.zig").search(self, cx),
        .install_language_support => try @import("services/catalog.zig").recommend(self, cx),
        .toggle_soft_wrap => try cx.update(self.settings.?, @import("settings/model.zig").Settings.apply, .{@import("settings/model.zig").Patch{ .soft_wrap = if (self.editor_options.soft_wrap == .none) .editor_width else .none }}),
        .git_next_change, .git_previous_change, .git_toggle_hunk => {
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
                try @import("services/git.zig").start(self, cx, .{ .blame = .{ .line = point.line + 1 } });
            }
        },
        .split_left, .split_right, .split_up, .split_down, .close_split, .split => {
            if (self.secondary != null and (which == .split or which == .close_split)) {
                const pane = &self.secondary.?;
                pane.editor.deinit();
                self.secondary = null;
                self.active_pane = .primary;
            } else if (which != .close_split and self.secondary == null) {
                const current = try active(self);
                var other = try editing.Editor.init(self.allocator);
                errdefer other.deinit();
                const record = try self.workspace.getConst(current.id);
                self.configureEditor(&other, record.path orelse "");
                var snapshot = try self.workspace.snapshot(current.id);
                defer snapshot.deinit();
                other.synchronize(snapshot);
                self.secondary = .{ .document = current.id, .editor = other };
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
            if (record.path == null) try show(self, cx, .save_as) else {
                try self.workspace.save(self.tabs.items[index].document, null);
                historyBoundary(self, self.tabs.items[index].document);
                try self.setStatus(try self.allocator.dupe(u8, "Saved"));
            }
        },
        .save_as => try show(self, cx, .save_as),
        .close_tab => {
            if (self.panel == .image) {
                if (self.image) |*asset| asset.deinit(self.allocator);
                self.image = null;
                self.panel = .editor;
            } else if (self.panel != .editor and self.panel != .markdown) {
                switch (self.panel) {
                    .search => self.tool_tabs.search = false,
                    .git_diff => self.tool_tabs.git_diff = false,
                    .extensions => self.tool_tabs.extensions = false,
                    else => {},
                }
                self.panel = .editor;
            } else if (self.tabs.items.len > 0) try requestTabClose(self, cx, self.active);
        },
        .quit => try cx.app.requestCloseWindow(self.window.?),
        .dismiss => {
            self.overlay = .none;
            self.vim_find_pending = false;
            self.pending = null;
        },
        .discard_dirty => {
            if (self.pending) |pending| switch (pending) {
                .tab => |i| try closeTab(self, i, .discard),
                .window => {
                    self.allow_close = true;
                    try cx.app.requestCloseWindow(self.window.?);
                },
            };
        },
        .save_dirty => {
            const index = try saveTarget(self);
            const id = self.tabs.items[index].document;
            const record = try self.workspace.getConst(id);
            if (record.path == null) try show(self, cx, .save_as) else {
                try self.workspace.save(id, null);
                historyBoundary(self, id);
                try finishPending(self, cx);
            }
        },
        .submit_path => {
            const bytes = try field(cx, self.fields.?.path, self.allocator);
            defer self.allocator.free(bytes);
            const path = std.mem.trim(u8, bytes, " \t");
            if (path.len == 0) return error.InvalidPath;
            if (self.overlay == .extension_path) {
                try @import("services/extensions.zig").install(self, cx, path);
                self.overlay = .none;
            } else if (self.overlay == .open_path) {
                try openPath(self, path);
            } else {
                const index = try saveTarget(self);
                const id = self.tabs.items[index].document;
                try self.workspace.save(id, path);
                historyBoundary(self, id);
                const record = try self.workspace.getConst(id);
                self.configureEditor(&self.tabs.items[index].editor, record.path.?);
                var snapshot = record.doc.snapshot();
                defer snapshot.deinit();
                self.tabs.items[index].editor.synchronize(snapshot);
                self.overlay = .none;
                try finishPending(self, cx);
            }
        },
        .find_next, .find_previous, .replace_one, .replace_all => {
            const current = try active(self);
            const record = try self.workspace.get(current.id);
            const query = try field(cx, self.fields.?.query, self.allocator);
            defer self.allocator.free(query);
            if (query.len == 0) return;
            if (which == .replace_all) {
                const replacement = try field(cx, self.fields.?.replacement, self.allocator);
                defer self.allocator.free(replacement);
                var result = try current.editor.replaceAll(&record.doc, query, replacement);
                try applyOutcome(self, cx, current.id, if (self.active_pane == .primary) 0 else 1, &result);
            } else if (which == .replace_one) {
                var snapshot = record.doc.snapshot();
                defer snapshot.deinit();
                const range = current.editor.primary().range();
                const selected = try snapshot.copy(self.allocator, range);
                defer self.allocator.free(selected);
                if (std.mem.eql(u8, selected, query)) {
                    const replacement = try field(cx, self.fields.?.replacement, self.allocator);
                    defer self.allocator.free(replacement);
                    var result = try current.editor.execute(&record.doc, .{ .insert = replacement });
                    try applyOutcome(self, cx, current.id, if (self.active_pane == .primary) 0 else 1, &result);
                }
                _ = try current.editor.findNext(&record.doc, query, false);
            } else {
                const found = try current.editor.findNext(&record.doc, query, (which == .find_previous) != (self.vim_find_pending and current.editor.vim.search_backward));
                if (!found) try self.setStatus(try self.allocator.dupe(u8, "No matches"));
            }
        },
        .delete_line, .undo, .redo, .select_all => {
            const current = try active(self);
            const record = try self.workspace.get(current.id);
            var result = try current.editor.execute(&record.doc, switch (which) {
                .delete_line => .delete_line,
                .undo => .undo,
                .redo => .redo,
                else => .select_all,
            });
            try applyOutcome(self, cx, current.id, if (self.active_pane == .primary) 0 else 1, &result);
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
    if (e.data == .close and !self.allow_close and firstDirty(self) != null) {
        self.pending = .window;
        try show(self, cx, .dirty);
        e.preventDefault();
        cx.notify();
    }
}
pub fn globalInput(self: *Shell, e: *ui.Event(ui.Input), cx: *ui.Context(Shell)) !void {
    @import("editor_git.zig").dismissOutside(self, cx, e);
    if (e.data == .focus and !e.data.focus) self.dragging = .none;
    if (e.data == .appearance) {
        if (self.system_dark == e.data.appearance) return;
        self.system_dark = e.data.appearance;
        if (self.settings) |settings| try self.onSettings(cx, settings);
        return;
    }
    if (e.data != .key_down) return;
    const key = e.data.key_down;
    if (try @import("views/git_controls.zig").input(self, e, cx)) return;
    if ((self.menu_open or self.split_menu_open) and key.key == .escape) {
        self.menu_open = false;
        self.split_menu_open = false;
        e.preventDefault();
        e.stopPropagation();
        cx.notify();
        return;
    }
    if (self.tab_drag != null and key.key == .escape) {
        @import("panes.zig").cancel(self);
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
        if (key.key == .enter) @import("services/language.zig").accept(self, cx, @intCast(self.language.completion_index)) catch |err| try self.reportError(err) else if (key.key == .escape) self.language.clearCompletion() else {
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
            if (self.overlay == .palette or self.overlay == .quick_open) try activateSelected(self, cx) else execute(self, cx, which, e) catch |err| try self.reportError(err);
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
            const count = try filteredCount(self, cx);
            if (count > 0) self.overlay_index = if (key.key == .down) (self.overlay_index + 1) % count else (self.overlay_index + count - 1) % count;
            e.preventDefault();
            e.stopPropagation();
            cx.notify();
        }
        return;
    }
    if (self.key_bindings.resolve(e.data)) |which| {
        if (which == .delete_line) return;
        execute(self, cx, which, e) catch |err| try self.reportError(err);
        e.preventDefault();
        e.stopPropagation();
        cx.notify();
    }
}
fn filteredCount(self: *Shell, cx: *ui.Context(Shell)) !usize {
    const query = try field(cx, self.fields.?.query, self.allocator);
    defer self.allocator.free(query);
    var count: usize = 0;
    if (self.overlay == .palette) {
        for (@import("commands.zig").commands) |entry| {
            if (@import("view.zig").matches(query, entry.label)) count += 1;
        }
    } else {
        for (self.file_index.items) |entry| {
            if (@import("view.zig").matches(query, entry.label)) count += 1;
        }
    }
    return count;
}
fn activateSelected(self: *Shell, cx: *ui.Context(Shell)) !void {
    const query = try field(cx, self.fields.?.query, self.allocator);
    defer self.allocator.free(query);
    var n: usize = 0;
    if (self.overlay == .palette) {
        for (@import("commands.zig").commands) |entry| {
            if (!@import("view.zig").matches(query, entry.label)) continue;
            if (n == self.overlay_index) {
                self.overlay = .none;
                execute(self, cx, entry.command, null) catch |err| try self.reportError(err);
                return;
            }
            n += 1;
        }
    } else {
        for (self.file_index.items) |entry| {
            if (!@import("view.zig").matches(query, entry.label)) continue;
            if (n == self.overlay_index) {
                try openPath(self, entry.path);
                return;
            }
            n += 1;
        }
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
