//! Window-owned workspace state. Input adapters only borrow this entity during
//! dispatch; canvases receive retained immutable text snapshots through Editor.
const std = @import("std");
const ui = @import("zircon_ui");
const workspace = @import("zircon_workspace");
const editor = @import("zircon_editor");
const command = @import("commands.zig");
const actions = @import("actions.zig");
pub const Command = command.Command;
pub const Tab = struct { document: workspace.DocumentId, editor: editor.Editor };
pub const Pane = struct { document: workspace.DocumentId, editor: editor.Editor };
pub const TreeRow = struct { name: []u8, path: []u8, directory: bool, depth: u16 = 0, expanded: bool = false };
pub const IndexedFile = struct { path: []u8, label: []u8 };
pub const Overlay = enum { none, palette, quick_open, open_path, save_as, extension_path, project_search, find, replace, dirty };
pub const CloseTarget = union(enum) { tab: usize, window };
pub const Fields = struct { query: ui.Entity(ui.controls.TextInput), project_query: ui.Entity(ui.controls.TextInput), replacement: ui.Entity(ui.controls.TextInput), path: ui.Entity(ui.controls.TextInput), commit: ui.Entity(ui.controls.TextInput) };
pub const Shell = struct {
    allocator: std.mem.Allocator,
    workspace: workspace.Workspace,
    tabs: std.ArrayList(Tab) = .empty,
    active: usize = 0,
    editor_focus_request: u64 = 1,
    secondary: ?Pane = null,
    active_pane: enum { primary, secondary } = .primary,
    sidebar_visible: bool = true,
    sidebar_width: f32 = 220,
    split_ratio: f32 = 0.5,
    tree: std.ArrayList(TreeRow) = .empty,
    file_index: std.ArrayList(IndexedFile) = .empty,
    indexing: bool = false,
    overlay_index: usize = 0,
    tree_scroll: ui.controls.Scroll = .{},
    overlay: Overlay = .none,
    pending: ?CloseTarget = null,
    allow_close: bool = false,
    window: ?ui.WindowHandle = null,
    fields: ?Fields = null,
    extensions: ?@import("zircon_extensions").Registry = null,
    extension_snapshot: ?@import("zircon_extensions").Snapshot = null,
    active_icon_theme: []u8 = &.{},
    icons: @import("services/icons.zig").Cache = .{},
    settings: ?ui.Entity(@import("settings/model.zig").Settings) = null,
    settings_window: ?ui.WindowHandle = null,
    colors: @import("theme.zig").Palette = .{},
    editor_options: struct { font_size: f32 = 14, tab_width: usize = 4, line_numbers: bool = true, git_gutters: bool = true, theme: editor.Theme = .{} } = .{},
    git: @import("services/git.zig").Model = .{},
    search: @import("services/search.zig").Model = .{},
    language: @import("services/language.zig").Model = .{},
    left_panel: enum { project, git_changes, git_history } = .project,
    panel: enum { editor, git_diff, extensions, search, image, markdown } = .editor,
    image: ?@import("views/image.zig").Asset = null,
    preview: ?struct { document: workspace.DocumentId, view: @import("views/markdown.zig").Preview } = null,
    status: []u8 = &.{},
    status_is_error: bool = false,
    dragging: enum { none, sidebar, split } = .none,
    tab_drag: ?@import("panes.zig").Session = null,
    pub fn init(a: std.mem.Allocator, io: std.Io, root_path: []const u8, initial: ?[]const u8) !Shell {
        var self: Shell = .{ .allocator = a, .workspace = try workspace.Workspace.init(a, io, root_path) };
        errdefer self.deinit(a);
        try actions.loadTree(&self);
        if (initial) |path| try self.openPath(path) else try self.newFile();
        return self;
    }
    pub fn deinit(self: *Shell, _: std.mem.Allocator) void {
        @import("panes.zig").cancel(self);
        for (self.tabs.items) |*tab| tab.editor.deinit();
        self.tabs.deinit(self.allocator);
        if (self.secondary) |*pane| pane.editor.deinit();
        for (self.tree.items) |row| {
            self.allocator.free(row.name);
            self.allocator.free(row.path);
        }
        self.tree.deinit(self.allocator);
        for (self.file_index.items) |row| {
            self.allocator.free(row.path);
            self.allocator.free(row.label);
        }
        self.file_index.deinit(self.allocator);
        self.allocator.free(self.status);
        self.git.deinit();
        self.search.deinit();
        self.language.deinit(self.allocator);
        if (self.image) |*asset| asset.deinit(self.allocator);
        if (self.preview) |*preview| preview.view.deinit();
        if (self.extension_snapshot) |*snapshot| snapshot.deinit();
        if (self.extensions) |*registry| registry.deinit();
        self.allocator.free(self.active_icon_theme);
        self.icons.deinit(self.allocator);
        self.workspace.deinit();
    }
    pub fn render(self: *const Shell, b: *ui.Ui) !ui.Element {
        return @import("view.zig").render(self, b);
    }
    pub fn bootstrap(self: *Shell, cx: *ui.Context(Shell), window: ui.WindowHandle) !void {
        try actions.bootstrap(self, cx, window);
    }
    pub fn loadSettings(self: *Shell, cx: *ui.Context(Shell), path: ?[]const u8) !void {
        const Settings = @import("settings/model.zig").Settings;
        var value = try Settings.init(self.allocator, self.workspace.io, path);
        self.settings = cx.app.createEntity(Settings, value) catch |err| {
            value.deinit(self.allocator);
            return err;
        };
    }
    pub fn loadExtensions(self: *Shell, cx: *ui.Context(Shell), home: []const u8) !void {
        var registry = try @import("zircon_extensions").Registry.init(self.allocator, self.workspace.io, home);
        var old_registry = self.extensions;
        var old_snapshot = self.extension_snapshot;
        self.extension_snapshot = registry.snapshot();
        self.extensions = registry;
        if (self.settings) |settings| self.onSettings(cx, settings) catch |err| {
            self.extension_snapshot.?.deinit();
            self.extension_snapshot = old_snapshot;
            self.extensions = old_registry;
            registry.deinit();
            return err;
        };
        self.language.deinit(self.allocator);
        if (old_snapshot) |*old| old.deinit();
        if (old_registry) |*old| old.deinit();
        cx.notify();
    }
    pub fn copyExtensions(self: *const Shell, output: *?@import("zircon_extensions").Snapshot) void {
        output.* = if (self.extension_snapshot) |snapshot| snapshot.clone() else null;
    }
    pub fn onSettings(self: *Shell, cx: *ui.Context(Shell), settings: ui.Entity(@import("settings/model.zig").Settings)) !void {
        const preferences = @import("settings/model.zig");
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        var values: preferences.Values = undefined;
        try cx.read(settings, preferences.Settings.copy, .{ arena.allocator(), &values });
        const icon_theme = try self.allocator.dupe(u8, values.icon_theme);
        errdefer self.allocator.free(icon_theme);
        var icons: @import("services/icons.zig").Cache = .{};
        errdefer icons.deinit(self.allocator);
        if (self.extension_snapshot) |snapshot| if (snapshot.resolveIconTheme(values.icon_theme)) |contribution| {
            icons = try @import("services/icons.zig").Cache.init(self.allocator, contribution);
        };
        for (self.tabs.items) |tab| _ = try self.workspace.getConst(tab.document);
        if (self.secondary) |pane| _ = try self.workspace.getConst(pane.document);
        try cx.app.setReducedMotion(values.reduced_motion);
        const light = std.mem.eql(u8, values.theme, "zircon.light");
        self.colors = if (light) @import("theme.zig").Palette.light else .{};
        for (self.tabs.items) |*tab| {
            tab.editor.font_size = values.font_size;
            tab.editor.line_height = values.font_size + 8;
            tab.editor.tab_width = values.tab_width;
            tab.editor.show_line_numbers = values.line_numbers;
            tab.editor.theme = if (light) editor.Theme.light else .{};
            tab.editor.show_git_gutters = values.git_gutters;
        }
        if (self.secondary) |*pane| {
            pane.editor.font_size = values.font_size;
            pane.editor.line_height = values.font_size + 8;
            pane.editor.tab_width = values.tab_width;
            pane.editor.show_line_numbers = values.line_numbers;
            pane.editor.theme = if (light) editor.Theme.light else .{};
            pane.editor.show_git_gutters = values.git_gutters;
        }
        self.allocator.free(self.active_icon_theme);
        self.active_icon_theme = icon_theme;
        self.icons.deinit(self.allocator);
        self.icons = icons;
        self.editor_options.theme = if (light) editor.Theme.light else .{};
        @import("services/extensions.zig").applyTheme(self, values.theme);
        if (self.preview) |*preview| preview.view.colors = self.previewColors();
        for (self.tabs.items) |*tab| {
            const record = self.workspace.getConst(tab.document) catch unreachable;
            @import("services/extensions.zig").applyLanguage(self, &tab.editor, record.path orelse "");
            tab.editor.syntax_cache.clear();
            var snapshot = record.doc.snapshot();
            defer snapshot.deinit();
            tab.editor.synchronize(snapshot);
        }
        if (self.secondary) |*pane| {
            const record = self.workspace.getConst(pane.document) catch unreachable;
            @import("services/extensions.zig").applyLanguage(self, &pane.editor, record.path orelse "");
            pane.editor.syntax_cache.clear();
            var snapshot = record.doc.snapshot();
            defer snapshot.deinit();
            pane.editor.synchronize(snapshot);
        }
        self.editor_options = .{ .font_size = values.font_size, .tab_width = values.tab_width, .line_numbers = values.line_numbers, .git_gutters = values.git_gutters, .theme = self.editor_options.theme };
        cx.notify();
    }
    pub fn configureEditor(self: *Shell, state: *editor.Editor, path: []const u8) void {
        const options = self.editor_options;
        state.font_size = options.font_size;
        state.line_height = options.font_size + 8;
        state.tab_width = options.tab_width;
        state.show_line_numbers = options.line_numbers;
        state.show_git_gutters = options.git_gutters;
        state.theme = options.theme;
        @import("services/extensions.zig").applyLanguage(self, state, path);
    }
    pub fn previewColors(self: *const Shell) @import("views/markdown.zig").Colors {
        return .{ .background = self.colors.document, .text = self.colors.text, .muted = self.colors.muted, .accent = self.colors.accent, .code = self.colors.sidebar, .border = self.colors.line };
    }
    pub fn openPath(self: *Shell, path: []const u8) !void {
        try actions.openPath(self, path);
    }
    pub fn newFile(self: *Shell) !void {
        try actions.newFile(self);
    }
    pub fn onCommand(self: *Shell, e: *ui.Event(ui.Click), cx: *ui.Context(Shell), which: Command) !void {
        if (self.overlay == .palette) self.overlay = .none;
        actions.execute(self, cx, which, null) catch |err| try self.reportError(err);
        if (self.overlay == .none) self.editor_focus_request +%= 1;
        e.preventDefault();
        cx.notify();
    }
    pub fn onRoot(self: *Shell, e: *ui.Event(ui.Input), cx: *ui.Context(Shell)) !void {
        try actions.rootInput(self, e, cx);
    }
    pub fn onGlobal(self: *Shell, e: *ui.Event(ui.Input), cx: *ui.Context(Shell)) !void {
        try actions.globalInput(self, e, cx);
    }
    pub fn onEditor(self: *Shell, e: *ui.Event(ui.Input), cx: *ui.Context(Shell), pane: u8) !void {
        _ = actions.editorInput(self, e, cx, pane) catch |err| {
            try self.reportError(err);
            cx.notify();
            return;
        };
    }
    pub fn onTab(self: *Shell, _: *ui.Event(ui.Click), cx: *ui.Context(Shell), index: u32) !void {
        if (index < self.tabs.items.len) {
            self.active = index;
            self.active_pane = .primary;
            if (self.panel != .markdown) self.panel = .editor;
            self.editor_focus_request +%= 1;
            @import("services/git.zig").start(self, cx, .refresh) catch |err| try self.reportError(err);
        }
        cx.notify();
    }
    pub fn onCloseTab(self: *Shell, _: *ui.Event(ui.Click), cx: *ui.Context(Shell), index: u32) !void {
        actions.requestTabClose(self, cx, index) catch |err| try self.reportError(err);
        if (self.overlay == .none) self.editor_focus_request +%= 1;
        cx.notify();
    }
    pub fn onTree(self: *Shell, _: *ui.Event(ui.Click), cx: *ui.Context(Shell), index: u32) !void {
        actions.activateTree(self, index) catch |err| try self.reportError(err);
        cx.notify();
    }
    pub fn onFile(self: *Shell, _: *ui.Event(ui.Click), cx: *ui.Context(Shell), index: u32) !void {
        if (index < self.file_index.items.len) {
            self.openPath(self.file_index.items[index].path) catch |err| try self.reportError(err);
            self.overlay = .none;
        }
        cx.notify();
    }
    pub fn onDrag(self: *Shell, e: *ui.Event(ui.Input), cx: *ui.Context(Shell), kind: u8) !void {
        try actions.drag(self, e, cx, kind);
    }
    pub fn onTabDrag(self: *Shell, e: *ui.Event(ui.Input), cx: *ui.Context(Shell), id: workspace.DocumentId) !void {
        try @import("panes.zig").tabInput(self, e, cx, id);
    }
    pub fn onTreeDrag(self: *Shell, e: *ui.Event(ui.Input), cx: *ui.Context(Shell), index: u32) !void {
        try @import("panes.zig").treeInput(self, e, cx, index);
    }
    pub fn onTreeInput(self: *Shell, e: *ui.Event(ui.Input), cx: *ui.Context(Shell)) !void {
        if (e.data == .scroll) {
            self.tree_scroll.wheel(e.data.scroll.y, @as(f32, @floatFromInt(self.tree.items.len)) * 24, e.bounds.height);
            e.preventDefault();
            cx.notify();
        }
    }
    pub fn onGitFile(self: *Shell, _: *ui.Event(ui.Click), cx: *ui.Context(Shell), index: u32) !void {
        if (self.git.status) |status| if (index < status.entries.len) {
            const path = try std.heap.page_allocator.dupe(u8, status.entries[index].path);
            std.heap.page_allocator.free(self.git.selected_path);
            self.git.selected_path = path;
            std.heap.page_allocator.free(self.git.selected_commit);
            self.git.selected_commit = &.{};
            self.panel = .git_diff;
            @import("services/git.zig").start(self, cx, .{ .diff = .{ .path = path, .staged = status.entries[index].staged and !status.entries[index].unstaged } }) catch |err| try self.reportError(err);
        };
        cx.notify();
    }
    pub fn onGitCommit(self: *Shell, _: *ui.Event(ui.Click), cx: *ui.Context(Shell), index: u32) !void {
        if (index >= self.git.commits.len) return;
        const oid = try std.heap.page_allocator.dupe(u8, self.git.commits[index].oid);
        std.heap.page_allocator.free(self.git.selected_commit);
        self.git.selected_commit = oid;
        self.panel = .git_diff;
        @import("services/git.zig").start(self, cx, .{ .history = oid }) catch |err| try self.reportError(err);
        cx.notify();
    }
    pub fn onGitScroll(self: *Shell, e: *ui.Event(ui.Input), cx: *ui.Context(Shell), which: u8) void {
        if (e.data != .scroll) return;
        if (which == 0) {
            const count = if (self.left_panel == .git_history) self.git.commits.len else if (self.git.status) |status| status.entries.len else 0;
            self.git.sidebar_scroll.wheel(e.data.scroll.y, @as(f32, @floatFromInt(count)) * 54, e.bounds.height);
        } else {
            const count = if (self.git.diff) |diff| std.mem.count(u8, diff.text, "\n") + 1 else 0;
            self.git.diff_scroll.wheel(e.data.scroll.y, @as(f32, @floatFromInt(count)) * 22, e.bounds.height);
        }
        e.preventDefault();
        cx.notify();
    }
    pub fn onSearchResult(self: *Shell, _: *ui.Event(ui.Click), cx: *ui.Context(Shell), payload: @import("views/search.zig").Target) !void {
        @import("services/search.zig").activate(self, cx, payload.group, payload.match) catch |err| {
            try self.reportError(err);
            cx.notify();
        };
    }
    pub fn pollLanguage(self: *Shell, cx: *ui.Context(Shell)) !void {
        try @import("services/language.zig").poll(self, cx);
        if (self.git.repository) {
            const current: ?workspace.DocumentId = if (self.active_pane == .secondary and self.secondary != null) self.secondary.?.document else if (self.tabs.items.len > 0) self.tabs.items[self.active].document else null;
            if (!std.meta.eql(current, self.git.active_document)) try @import("services/git.zig").start(self, cx, .refresh);
        }
    }
    pub fn onPreview(self: *Shell, e: *ui.Event(ui.Input), cx: *ui.Context(Shell)) !void {
        const preview = if (self.preview) |*value| value else return;
        const outcome = try preview.view.handle(e);
        if (outcome.open_path) |relative| {
            const record = try self.workspace.getConst(preview.document);
            const path = try std.fs.path.resolve(self.allocator, &.{ if (record.path) |p| std.fs.path.dirname(p) orelse self.workspace.root_path else self.workspace.root_path, relative });
            defer self.allocator.free(path);
            try self.openPath(path);
        } else if (outcome.open_url) |url| {
            var process = try std.process.spawn(self.workspace.io, .{ .argv = &.{ "/usr/bin/open", url } });
            _ = try process.wait(self.workspace.io);
        } else if (outcome.source_offset) |offset| {
            for (self.tabs.items, 0..) |*tab, index| if (std.meta.eql(tab.document, preview.document)) {
                var snapshot = try self.workspace.snapshot(tab.document);
                defer snapshot.deinit();
                try tab.editor.setSelection(snapshot, .{ .start = offset, .end = offset });
                tab.editor.reveal(snapshot);
                self.active = index;
                self.active_pane = .primary;
                self.editor_focus_request +%= 1;
                break;
            };
        }
        if (outcome.handled) cx.notify();
    }
    pub fn onCompletion(self: *Shell, _: *ui.Event(ui.Click), cx: *ui.Context(Shell), index: u32) !void {
        @import("services/language.zig").accept(self, cx, index) catch |err| try self.reportError(err);
        cx.notify();
    }
    pub fn onDiagnostic(self: *Shell, _: *ui.Event(ui.Click), cx: *ui.Context(Shell), index: u32) !void {
        @import("services/language.zig").selectDiagnostic(self, cx, index) catch |err| try self.reportError(err);
        cx.notify();
    }
    pub fn onSearchScroll(self: *Shell, e: *ui.Event(ui.Input), cx: *ui.Context(Shell)) void {
        if (e.data != .scroll) return;
        var height: f32 = 0;
        if (self.search.results) |results| for (results.groups) |group| {
            height += 42;
            for (group.excerpts) |excerpt| height += (@as(f32, @floatFromInt(std.mem.count(u8, excerpt.bytes, "\n") + 1))) * 22 + 16;
        };
        self.search.scroll.wheel(e.data.scroll.y, height, e.bounds.height);
        e.preventDefault();
        cx.notify();
    }
    pub fn onSearchQuery(self: *Shell, e: *ui.Event(ui.Input), cx: *ui.Context(Shell)) !void {
        if (e.data != .key_down or e.data.key_down.key != .enter) return;
        @import("services/search.zig").start(self, cx) catch |err| try self.reportError(err);
        e.preventDefault();
        e.stopPropagation();
        cx.notify();
    }
    pub fn reportError(self: *Shell, err: anyerror) !void {
        try self.setStatus(try self.allocator.dupe(u8, @import("errors.zig").message(err)));
        self.status_is_error = true;
    }
    pub fn setStatus(self: *Shell, owned: []u8) !void {
        self.allocator.free(self.status);
        self.status = owned;
        self.status_is_error = false;
    }
};
