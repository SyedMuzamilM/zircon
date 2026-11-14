//! Window-owned workspace state. Input adapters only borrow this entity during
//! dispatch; canvases receive retained immutable text snapshots through Editor.
const std = @import("std");
const editor = @import("zircon_editor");
const zircon_extensions = @import("zircon_extensions");
const multibuffer = @import("zircon_multibuffer");
const zircon_text = @import("zircon_text");
const ui = @import("zircon_ui");
const workspace = @import("zircon_workspace");
const actions = @import("actions.zig");
const command = @import("commands.zig");
const errors = @import("errors.zig");
const git_selection = @import("git_selection.zig");
const key_bindings_module = @import("key_bindings.zig");
const panes = @import("panes.zig");
const projects = @import("projects.zig");
const recent_module = @import("recent.zig");
const search_selection = @import("search_selection.zig");
const services_agents = @import("services/agents.zig");
const buffer_find = @import("services/buffer_find.zig");
const services_catalog = @import("services/catalog.zig");
const services_extensions = @import("services/extensions.zig");
const services_git = @import("services/git.zig");
const services_icons = @import("services/icons.zig");
const services_language = @import("services/language.zig");
const services_project = @import("services/project.zig");
const services_recovery = @import("services/recovery.zig");
const services_search = @import("services/search.zig");
const symbol_hover = @import("services/symbol_hover.zig");
const model = @import("settings/model.zig");
const settings_store = @import("settings/store.zig");
const terminal_module = @import("terminal.zig");
const theme_module = @import("theme.zig");
const view_module = @import("view.zig");
const views_diagnostics = @import("views/diagnostics.zig");
const editor_context_menu = @import("views/editor_context_menu.zig");
const views_image = @import("views/image.zig");
const view_inputs = @import("views/inputs.zig");
const views_markdown = @import("views/markdown.zig");
const views_search = @import("views/project_search.zig");
pub const Command = command.Command;
pub const Tab = struct { document: workspace.DocumentId, editor: editor.Editor, primary: bool = true, secondary: bool = false, language_path: ?[]u8 = null, language_name: ?[]u8 = null, secondary_state: ?editor.Editor = null };
pub const Pane = struct { document: workspace.DocumentId, editor: editor.Editor };
pub const TreeRow = struct { name: []u8, path: []u8, directory: bool, depth: u16 = 0, expanded: bool = false };
pub const IndexedFile = struct { path: []u8, label: []u8 };
pub const Overlay = enum {
    none,
    open_project,
    palette,
    quick_open,
    open_path,
    save_as,
    extension_path,
    project_search,
    find,
    replace,
    rename,
    dirty,
};
pub const CloseTarget = union(enum) { tab: usize, window };
pub const Fields = view_inputs.Fields;
pub const Shell = struct {
    allocator: std.mem.Allocator,
    workspace: workspace.Workspace,
    /// Ordered document events waiting for service consumers. The queue owns
    /// copied mappings and is drained on the UI thread.
    document_changes: workspace.ChangeLog = .{},
    tabs: std.ArrayList(Tab) = .empty,
    active: usize = 0,
    editor_focus_request: u64 = 1,
    secondary: ?Pane = null,
    active_pane: enum { primary, secondary } = .primary,
    sidebar_visible: bool = true,
    sidebar_width: f32 = 250,
    project_default_width: f32 = 250,
    project_entry_spacing: f32 = 24,
    project_file_icons: bool = true,
    project_folder_icons: bool = true,
    tooltips: bool = true,
    tooltip_delay: f32 = 400,
    agent_editor_setting: bool = true,
    git_sidebar_width: f32 = 320,
    menu_anchor: ui.Rect = .{},
    split_anchor: ui.Rect = .{},
    git_anchor: ui.Rect = .{},
    menu_open: bool = false,
    popup: enum { none, recent, language, servers, editor } = .none,
    popup_anchor: ui.Rect = .{},
    recent: recent_module.Recent = .{},
    language_stopped: bool = false,
    layout_setting: settings_store.PanelLayout = .classic,
    terminal: terminal_module.Model = .{},
    image_zoom: f32 = 1,
    image_scroll: ui.Point = .{},

    split_menu_open: bool = false,
    inline_blame_enabled: bool = true,
    system_dark: bool = true,
    follows_system: bool = false,
    key_bindings: key_bindings_module.Overrides = .{},
    split_vertical: bool = false,
    split_reverse: bool = false,
    open_kind: projects.Kind = .local_folder,
    cloning: bool = false,
    search_focus_request: u64 = 0,
    tool_tabs: ToolTabs = .{},
    secondary_tools: ToolTabs = .{},
    secondary_tool: ?Tool = null,
    split_ratio: f32 = 0.5,
    tree: std.ArrayList(TreeRow) = .empty,
    project_watch: services_project.Model = .{},
    file_index: std.ArrayList(IndexedFile) = .empty,
    indexing: bool = false,
    overlay_index: usize = 0,
    vim_find_pending: bool = false,
    tree_scroll: ui.controls.Scroll = .{},
    overlay: Overlay = .none,
    pending: ?CloseTarget = null,
    allow_close: bool = false,
    window: ?ui.WindowHandle = null,
    fields: ?Fields = null,
    extensions: ?zircon_extensions.Registry = null,
    extension_snapshot: ?zircon_extensions.Snapshot = null,
    active_icon_theme: []u8 = &.{},
    icons: services_icons.Cache = .{},
    settings: ?ui.Entity(model.Settings) = null,
    settings_window: ?ui.WindowHandle = null,
    colors: theme_module.Palette = .{},
    editor_options: struct { indent_guides: bool = true, active_line: bool = true, fold_controls: bool = true, soft_wrap: editor.wrap.Mode = .none, vim_mode: bool = false, vim_bindings: editor.vim.Bindings = .{}, font_size: f32 = 14, line_height: f32 = 1.6, tab_width: usize = 4, line_numbers: bool = true, git_gutters: bool = true, theme: editor.Theme = .{} } = .{},
    git: services_git.Model = .{},
    recovery: ?services_recovery.Model = null,
    search: services_search.Model = .{},
    multibuffer_history: multibuffer.Transactions = .init(std.heap.page_allocator),
    find: buffer_find.Model = .{},
    catalog: services_catalog.Model = .{},
    extension_host_path: ?[]const u8 = null,
    language: services_language.Model = .{},
    symbol_hover: symbol_hover.Model = .{},
    agents: services_agents.Model = .{},
    agent_mode: bool = false,
    agent_editor: bool = true,
    left_panel: enum { project, git_changes, git_history } = .project,
    panel: Panel = .editor,
    diagnostics: views_diagnostics.Model = .{},
    editor_context_menu: ?editor_context_menu.Model = null,
    image: ?views_image.Asset = null,
    preview: ?struct { document: workspace.DocumentId, view: views_markdown.Preview } = null,
    status: []u8 = &.{},
    status_is_error: bool = false,
    status_origin: union(enum) { general, syntax: workspace.DocumentId } = .general,
    status_sequence: u64 = 0,
    dragging: enum { none, sidebar, split } = .none,
    tab_drag: ?panes.Session = null,
    pub fn init(a: std.mem.Allocator, io: std.Io, root_path: []const u8, initial: ?[]const u8) !Shell {
        var self: Shell = .{ .allocator = a, .workspace = try workspace.Workspace.init(a, io, root_path) };
        errdefer self.deinit(a);
        try actions.loadTree(&self);
        if (initial) |path| try self.openPath(path) else try self.newFile();
        return self;
    }
    pub fn deinit(self: *Shell, _: std.mem.Allocator) void {
        self.symbol_hover.deinit();
        panes.cancel(self);
        self.recent.deinit(self.allocator);
        self.terminal.deinit(self.allocator);
        for (self.tabs.items) |*tab| {
            tab.editor.deinit();
            if (tab.secondary_state) |*state| state.deinit();
            if (tab.language_path) |path| self.allocator.free(path);
            if (tab.language_name) |name| self.allocator.free(name);
        }
        self.tabs.deinit(self.allocator);
        self.document_changes.clear();
        self.git.clearEditable();
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
        if (self.recovery) |*recovery| recovery.deinit(self.allocator);
        self.git.deinit();
        self.search.deinit();
        self.multibuffer_history.deinit();
        self.find.deinit(self.allocator);
        self.catalog.deinit();
        self.agents.deinit(self.allocator);
        self.language.deinit(self.allocator);
        if (self.image) |*asset| asset.deinit(self.allocator);
        if (self.preview) |*preview| preview.view.deinit();
        if (self.extension_snapshot) |*snapshot| snapshot.deinit();
        if (self.extensions) |*registry| registry.deinit();
        self.allocator.free(self.active_icon_theme);
        self.icons.deinit(self.allocator);
        self.workspace.deinit();
    }
    pub fn publishDocumentChange(self: *Shell, id: workspace.DocumentId, origin: workspace.ChangeOrigin, change: zircon_text.Change) void {
        self.document_changes.push(workspace.DocumentChange.take(id, origin, change));
    }
    pub fn publishDocumentReset(self: *Shell, id: workspace.DocumentId, origin: workspace.ChangeOrigin, before: u64) void {
        const record = self.workspace.getConst(id) catch return;
        self.document_changes.push(.{ .allocator = self.allocator, .document = id, .origin = origin, .before = before, .after = record.doc.revision(), .state = record.doc.stateId(), .mappings = &.{} });
    }
    pub fn documentChangeCount(self: *const Shell) usize {
        return self.document_changes.len;
    }
    pub fn documentChangeOrigin(self: *const Shell, index: usize) ?workspace.ChangeOrigin {
        return if (self.document_changes.get(index)) |change| change.origin else null;
    }
    pub fn documentChangeSince(self: *const Shell, id: workspace.DocumentId, before: u64, after: u64) ?*const workspace.DocumentChange {
        for (0..self.document_changes.len) |index| {
            const change = self.document_changes.get(index).?;
            if (std.meta.eql(change.document, id) and change.before == before and change.after == after) return change;
        }
        return null;
    }
    pub fn clearDocumentChanges(self: *Shell, cx: *ui.Context(Shell)) void {
        self.document_changes.clear();
        cx.notify();
    }
    pub const configureAgents = services_agents.configure;
    pub fn render(self: *const Shell, b: *ui.Ui) !ui.Element {
        return view_module.render(self, b);
    }
    pub fn bootstrap(self: *Shell, cx: *ui.Context(Shell), window: ui.WindowHandle) !void {
        try actions.bootstrap(self, cx, window);
    }
    pub fn loadSettings(self: *Shell, cx: *ui.Context(Shell), path: ?[]const u8) !void {
        const Settings = model.Settings;
        var value = try Settings.init(self.allocator, self.workspace.io, path);
        self.settings = cx.app.createEntity(Settings, value) catch |err| {
            value.deinit(self.allocator);
            return err;
        };
    }
    /// Restores an unlocked session and enables asynchronous checkpoints.
    pub fn initRecovery(self: *Shell, cx: *ui.Context(Shell), home: []const u8) !void {
        services_recovery.init(self, home) catch |err| {
            self.recovery = .{ .home = try self.allocator.dupe(u8, home), .store = null, .last_error = err };
            try self.reportError(err);
            cx.notify();
            return;
        };
        cx.notify();
    }
    pub fn loadExtensions(self: *Shell, cx: *ui.Context(Shell), home: []const u8) !void {
        var registry = try zircon_extensions.Registry.init(self.allocator, self.workspace.io, home);
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
    pub fn copyExtensions(self: *const Shell, output: *?zircon_extensions.Snapshot) void {
        output.* = if (self.extension_snapshot) |snapshot| snapshot.clone() else null;
    }
    pub fn onSettings(self: *Shell, cx: *ui.Context(Shell), settings: ui.Entity(model.Settings)) !void {
        const preferences = model;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        var values: preferences.Values = undefined;
        try cx.read(settings, preferences.Settings.copy, .{ arena.allocator(), &values });
        self.key_bindings = values.key_bindings;
        self.terminal.dock = values.terminal_dock;
        self.agent_mode = false;
        self.layout_setting = .classic;
        if (values.project_panel_width != self.project_default_width) {
            self.sidebar_width = values.project_panel_width;
            self.project_default_width = values.project_panel_width;
        }
        self.project_entry_spacing = values.project_entry_spacing;
        self.project_file_icons = values.project_file_icons;
        self.project_folder_icons = values.project_folder_icons;
        self.tooltips = values.tooltips;
        self.tooltip_delay = values.tooltip_delay;
        if (!self.find.visible) {
            self.find.case_sensitive = values.search_case_sensitive;
            self.find.whole_word = values.search_whole_word;
        }
        self.inline_blame_enabled = values.git_inline_blame;
        if (!self.inline_blame_enabled) {
            for (self.tabs.items) |*tab| if (tab.editor.inline_blame != null and !tab.editor.inline_blame.?.expanded) tab.editor.hideBlame();
            if (self.secondary) |*pane| if (pane.editor.inline_blame != null and !pane.editor.inline_blame.?.expanded) pane.editor.hideBlame();
            self.git.blame_target = null;
        }
        const icon_theme = try self.allocator.dupe(u8, values.icon_theme);
        errdefer self.allocator.free(icon_theme);
        var icons: services_icons.Cache = .{};
        errdefer icons.deinit(self.allocator);
        if (self.extension_snapshot) |snapshot| if (snapshot.resolveIconTheme(values.icon_theme)) |contribution| {
            icons = try services_icons.Cache.init(self.allocator, contribution);
        };
        for (self.tabs.items) |tab| _ = try self.workspace.getConst(tab.document);
        if (self.secondary) |pane| _ = try self.workspace.getConst(pane.document);
        try cx.app.setReducedMotion(values.reduced_motion);
        try cx.app.setTypography(.{ .code_family = values.editor_font_name, .ui_family = values.interface_font_name, .code_font = values.font_family, .ui_font = values.ui_font_family, .ui_size = values.ui_font_size, .ligatures = values.font_ligatures });
        const follows_system = std.mem.eql(u8, values.theme, "zircon.system");
        if (follows_system and !self.follows_system) if (self.window) |handle| if ((try cx.app.window(handle)).surface) |surface| {
            self.system_dark = surface.systemDark();
        };
        self.follows_system = follows_system;
        const light = theme_module.isLight(values.theme, self.system_dark);
        self.colors = if (light) theme_module.Palette.light else .{};
        for (self.tabs.items) |*tab| {
            tab.editor.soft_wrap = values.soft_wrap;
            tab.editor.wrap_cache.revision = null;
            tab.editor.setVim(values.vim_mode);
            tab.editor.vim.bindings = values.vim_bindings;
            tab.editor.font_size = values.font_size;
            tab.editor.line_height = values.font_size * values.line_height;
            tab.editor.tab_width = values.tab_width;
            tab.editor.show_line_numbers = values.line_numbers;
            tab.editor.theme = if (light) editor.Theme.light else .{};
            tab.editor.show_git_gutters = values.git_gutters;
            tab.editor.show_indent_guides = values.indent_guides;
            tab.editor.highlight_active_line = values.active_line;
            tab.editor.show_fold_controls = values.fold_controls;
        }
        if (self.secondary) |*pane| {
            pane.editor.soft_wrap = values.soft_wrap;
            pane.editor.wrap_cache.revision = null;
            pane.editor.setVim(values.vim_mode);
            pane.editor.vim.bindings = values.vim_bindings;
            pane.editor.font_size = values.font_size;
            pane.editor.line_height = values.font_size * values.line_height;
            pane.editor.tab_width = values.tab_width;
            pane.editor.show_line_numbers = values.line_numbers;
            pane.editor.theme = if (light) editor.Theme.light else .{};
            pane.editor.show_git_gutters = values.git_gutters;
            pane.editor.show_indent_guides = values.indent_guides;
            pane.editor.highlight_active_line = values.active_line;
            pane.editor.show_fold_controls = values.fold_controls;
        }
        self.allocator.free(self.active_icon_theme);
        self.active_icon_theme = icon_theme;
        self.icons.deinit(self.allocator);
        self.icons = icons;
        self.editor_options.theme = if (light) editor.Theme.light else .{};
        services_extensions.applyTheme(self, values.theme);
        if (self.window) |handle| if ((try cx.app.window(handle)).surface) |surface| {
            const background = self.colors.document;
            const dark = background.r * 0.2126 + background.g * 0.7152 + background.b * 0.0722 < 0.5;
            surface.setAppearance(if (follows_system) null else dark);
        };
        if (self.preview) |*preview| preview.view.colors = self.previewColors();
        for (self.tabs.items) |*tab| {
            const record = self.workspace.getConst(tab.document) catch unreachable;
            services_extensions.applyLanguage(self, &tab.editor, self.languagePath(tab.document, record.path orelse ""));
            tab.editor.syntax_cache.clear();
            var snapshot = record.doc.snapshot();
            defer snapshot.deinit();
            tab.editor.synchronize(snapshot);
            if (std.meta.eql(tab.document, self.tabs.items[self.active].document)) try actions.prepareEditor(self, cx, &tab.editor, snapshot, "primary-editor");
        }
        if (self.secondary) |*pane| {
            const record = self.workspace.getConst(pane.document) catch unreachable;
            services_extensions.applyLanguage(self, &pane.editor, self.languagePath(pane.document, record.path orelse ""));
            pane.editor.syntax_cache.clear();
            var snapshot = record.doc.snapshot();
            defer snapshot.deinit();
            pane.editor.synchronize(snapshot);
            try actions.prepareEditor(self, cx, &pane.editor, snapshot, "secondary-editor");
        }
        self.editor_options = .{ .indent_guides = values.indent_guides, .active_line = values.active_line, .fold_controls = values.fold_controls, .soft_wrap = values.soft_wrap, .vim_mode = values.vim_mode, .vim_bindings = values.vim_bindings, .font_size = values.font_size, .line_height = values.line_height, .tab_width = values.tab_width, .line_numbers = values.line_numbers, .git_gutters = values.git_gutters, .theme = self.editor_options.theme };
        for (self.git.editing.views.items) |*view| {
            const record = self.workspace.getConst(view.document) catch continue;
            self.configureEditor(&view.editor, record.path orelse "");
            view.editor.soft_wrap = values.soft_wrap;
            view.editor.show_fold_controls = false;
            view.editor.show_git_gutters = false;
            view.editor.show_indent_guides = false;
        }
        for (&self.search.editing.panes) |*pane| for (pane.views.items) |*view| {
            const record = self.workspace.getConst(view.document) catch continue;
            self.configureEditor(&view.editor, self.languagePath(view.document, record.path orelse ""));
            view.editor.soft_wrap = .none;
            view.editor.show_fold_controls = false;
            view.editor.show_git_gutters = false;
            view.editor.show_scrollbars = false;
            var snapshot = record.doc.snapshot();
            defer snapshot.deinit();
            view.editor.synchronize(snapshot);
        };
        try self.styleInputs(cx);
        cx.notify();
    }
    pub fn styleInputs(self: *Shell, cx: *ui.Context(Shell)) !void {
        if (self.fields) |fields| try fields.style(cx, self.colors);
    }
    pub fn panelWidth(self: *const Shell) f32 {
        return if (self.left_panel == .project) self.sidebar_width else self.git_sidebar_width;
    }
    pub fn languagePath(self: *const Shell, id: workspace.DocumentId, fallback: []const u8) []const u8 {
        for (self.tabs.items) |tab| if (std.meta.eql(tab.document, id)) return tab.language_path orelse fallback;
        return fallback;
    }
    pub fn languageName(self: *const Shell, id: workspace.DocumentId) ?[]const u8 {
        for (self.tabs.items) |tab| if (std.meta.eql(tab.document, id)) return tab.language_name;
        return null;
    }
    pub fn configureEditor(self: *Shell, state: *editor.Editor, path: []const u8) void {
        const options = self.editor_options;
        state.show_indent_guides = options.indent_guides;
        state.highlight_active_line = options.active_line;
        state.show_fold_controls = options.fold_controls;
        state.soft_wrap = options.soft_wrap;
        state.setVim(options.vim_mode);
        state.vim.bindings = options.vim_bindings;
        state.font_size = options.font_size;
        state.line_height = options.font_size * options.line_height;
        state.tab_width = options.tab_width;
        state.show_line_numbers = options.line_numbers;
        state.show_git_gutters = options.git_gutters;
        state.theme = options.theme;
        services_extensions.applyLanguage(self, state, path);
    }
    pub fn previewColors(self: *const Shell) views_markdown.Colors {
        return .{ .background = self.colors.document, .text = self.colors.text, .muted = self.colors.muted, .accent = self.colors.accent, .code = self.colors.sidebar, .border = self.colors.line, .tokens = self.editor_options.theme.tokens };
    }
    pub fn openPath(self: *Shell, path: []const u8) !void {
        try actions.openPath(self, path);
    }
    pub fn newFile(self: *Shell) !void {
        try actions.newFile(self);
    }
    pub fn onCommand(self: *Shell, e: *ui.Event(ui.Click), cx: *ui.Context(Shell), which: Command) !void {
        self.rememberPanel();
        switch (which) {
            .recent_projects, .language_picker, .language_servers, .editor_options => self.popup_anchor = e.bounds,
            .workspace_menu => self.menu_anchor = e.bounds,
            .split_menu => self.split_anchor = e.bounds,
            .git_network_menu, .git_changes_menu, .git_branches, .git_stashes => self.git_anchor = e.bounds,
            else => {},
        }
        self.git.menu = .none;
        self.popup = .none;
        self.menu_open = false;
        if (which != .split_menu) self.split_menu_open = false;
        if (self.overlay == .palette) self.overlay = .none;
        actions.execute(self, cx, which, null) catch |err| try self.reportError(err);
        self.rememberPanel();
        if (self.overlay == .none) {
            if (self.agent_mode) self.agents.focus +%= 1 else self.editor_focus_request +%= 1;
        }
        e.preventDefault();
        cx.notify();
    }
    pub const Panel = enum { editor, git_diff, extensions, search, image, markdown, diagnostics, language_results };
    pub const Tool = enum { search, git_diff, extensions, diagnostics, language_results };
    pub const ToolTabs = struct {
        search: bool = false,
        git_diff: bool = false,
        extensions: bool = false,
        diagnostics: bool = false,
        language_results: bool = false,

        pub fn contains(self: ToolTabs, tool: Tool) bool {
            inline for (@typeInfo(Tool).@"enum".field_names) |name| if (tool == @field(Tool, name)) return @field(self, name);
            unreachable;
        }
        pub fn set(self: *ToolTabs, tool: Tool, opened: bool) void {
            inline for (@typeInfo(Tool).@"enum".field_names) |name| if (tool == @field(Tool, name)) {
                @field(self, name) = opened;
                return;
            };
        }
    };
    pub fn rememberPanel(self: *Shell) void {
        if (self.currentTool(0)) |tool| self.tool_tabs.set(tool, true);
    }
    pub const ToolTab = struct { tool: Tool, pane: u8 = 0 };
    pub fn showTool(self: *Shell, tool: Tool) void {
        if (self.active_pane == .secondary and self.secondary != null) {
            self.secondary_tool = tool;
            self.secondary_tools.set(tool, true);
        } else {
            inline for (@typeInfo(Tool).@"enum".field_names) |name| if (tool == @field(Tool, name)) {
                self.panel = @field(Panel, name);
            };
            self.rememberPanel();
        }
    }
    pub fn currentTool(self: *const Shell, pane: u8) ?Tool {
        if (pane == 1) return self.secondary_tool;
        return std.meta.stringToEnum(Tool, @tagName(self.panel));
    }
    pub fn onToolTab(self: *Shell, _: *ui.Event(ui.Click), cx: *ui.Context(Shell), target: ToolTab) void {
        if (target.tool == .git_diff) self.git.showWorking();
        self.rememberPanel();
        self.active_pane = if (target.pane == 1 and self.secondary != null) .secondary else .primary;
        self.showTool(target.tool);
        self.overlay = .none;
        cx.notify();
    }
    pub fn onCloseTool(self: *Shell, _: *ui.Event(ui.Click), cx: *ui.Context(Shell), target: ToolTab) void {
        const opened = if (target.pane == 1) &self.secondary_tools else &self.tool_tabs;
        opened.set(target.tool, false);
        if (target.pane == 1) {
            if (self.secondary_tool == target.tool) self.secondary_tool = null;
        } else if (self.currentTool(0) == target.tool) self.panel = .editor;
        self.editor_focus_request +%= 1;
        cx.notify();
    }
    pub fn onOpenKind(self: *Shell, _: *ui.Event(ui.Click), cx: *ui.Context(Shell), kind: projects.Kind) void {
        self.open_kind = kind;
        cx.notify();
    }
    pub fn onRoot(self: *Shell, e: *ui.Event(ui.Input), cx: *ui.Context(Shell)) !void {
        try actions.rootInput(self, e, cx);
    }
    pub const Breadcrumb = struct { document: workspace.DocumentId, prefix: u32, pane: u8 = 0 };
    pub fn onBreadcrumb(self: *Shell, _: *ui.Event(ui.Click), cx: *ui.Context(Shell), target: Breadcrumb) !void {
        const record = try self.workspace.getConst(target.document);
        if (target.prefix > 0) if (record.path) |path| {
            if (target.prefix > path.len) return;
            self.left_panel = .project;
            self.sidebar_visible = true;
            for (self.tree.items, 0..) |row, index| if (std.mem.eql(u8, row.path, path[0..target.prefix])) {
                if (row.directory and !row.expanded) try actions.activateTree(self, index);
                self.tree_scroll.reveal(@as(f32, @floatFromInt(index)) * self.project_entry_spacing, @as(f32, @floatFromInt(index + 1)) * self.project_entry_spacing, @as(f32, @floatFromInt(self.tree.items.len)) * self.project_entry_spacing, 400);
                break;
            };
        };
        if (target.pane == 1 and self.secondary != null and std.meta.eql(self.secondary.?.document, target.document)) {
            self.active_pane = .secondary;
            var snapshot = record.doc.snapshot();
            defer snapshot.deinit();
            self.secondary.?.editor.reveal(snapshot);
        } else for (self.tabs.items, 0..) |*tab, index| if (std.meta.eql(tab.document, target.document)) {
            self.active = index;
            self.active_pane = .primary;
            var snapshot = record.doc.snapshot();
            defer snapshot.deinit();
            tab.editor.reveal(snapshot);
            break;
        };
        self.editor_focus_request +%= 1;
        cx.notify();
    }
    pub fn onOverlayInput(self: *Shell, e: *ui.Event(ui.Input), cx: *ui.Context(Shell)) void {
        if (e.phase == .target and e.data == .pointer_down and self.overlay != .dirty) {
            self.overlay = .none;
            self.vim_find_pending = false;
            self.editor_focus_request +%= 1;
            e.preventDefault();
            cx.notify();
        }
    }
    pub fn onMenuInput(self: *Shell, e: *ui.Event(ui.Input), cx: *ui.Context(Shell)) void {
        if (e.data == .pointer_down and e.phase == .target) {
            self.menu_open = false;
            self.popup = .none;
            self.split_menu_open = false;
            e.preventDefault();
            cx.notify();
        }
    }
    pub fn onGlobal(self: *Shell, e: *ui.Event(ui.Input), cx: *ui.Context(Shell)) !void {
        try actions.globalInput(self, e, cx);
    }
    pub fn onPaneInput(self: *Shell, event: *ui.Event(ui.Input), cx: *ui.Context(Shell), pane: u8) void {
        if (event.data == .pointer_down) {
            self.active_pane = if (pane == 1) .secondary else .primary;
            cx.notify();
        }
    }
    pub fn onEditor(self: *Shell, e: *ui.Event(ui.Input), cx: *ui.Context(Shell), pane: u8) !void {
        _ = actions.editorInput(self, e, cx, pane) catch |err| {
            try self.reportError(err);
            cx.notify();
            return;
        };
    }
    pub fn onTab(self: *Shell, _: *ui.Event(ui.Click), cx: *ui.Context(Shell), target: u32) !void {
        const index = target & 0x7fffffff;
        if (target & 0x80000000 != 0) {
            if (index < self.tabs.items.len) try panes.selectSecondary(self, index);
            cx.notify();
            return;
        }
        if (index < self.tabs.items.len) {
            self.tabs.items[index].primary = true;
            self.active = index;
            self.active_pane = .primary;
            if (self.panel != .markdown) self.panel = .editor;
            self.editor_focus_request +%= 1;
            services_git.start(self, cx, .refresh) catch |err| try self.reportError(err);
        }
        cx.notify();
    }
    pub fn onCloseTab(self: *Shell, _: *ui.Event(ui.Click), cx: *ui.Context(Shell), target: u32) !void {
        const index = target & 0x7fffffff;
        if (index >= self.tabs.items.len) return;
        if (target & 0x80000000 != 0 and self.tabs.items[index].primary) {
            panes.closeSecondaryTab(self, index);
            cx.notify();
            return;
        }
        if (target & 0x80000000 == 0 and self.tabs.items[index].secondary) {
            panes.closePrimaryTab(self, index);
            cx.notify();
            return;
        }
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
    pub fn onTabDrag(self: *Shell, e: *ui.Event(ui.Input), cx: *ui.Context(Shell), target: panes.DragTarget) !void {
        try panes.tabInput(self, e, cx, target);
    }
    pub fn onTreeDrag(self: *Shell, e: *ui.Event(ui.Input), cx: *ui.Context(Shell), index: u32) !void {
        try panes.treeInput(self, e, cx, index);
    }
    pub fn onTreeInput(self: *Shell, e: *ui.Event(ui.Input), cx: *ui.Context(Shell)) !void {
        if (e.data == .scroll) {
            self.tree_scroll.wheel(e.data.scroll.y, @as(f32, @floatFromInt(self.tree.items.len)) * self.project_entry_spacing, e.bounds.height);
            e.preventDefault();
            cx.notify();
        }
    }
    pub fn onGitFile(self: *Shell, _: *ui.Event(ui.Click), cx: *ui.Context(Shell), index: u32) !void {
        self.git.showWorking();
        if (self.git.status) |status| if (index < status.entries.len) {
            const path = try std.heap.page_allocator.dupe(u8, status.entries[index].path);
            std.heap.page_allocator.free(self.git.selected_path);
            self.git.selected_path = path;
            std.heap.page_allocator.free(self.git.selected_commit);
            self.git.selected_commit = &.{};
            self.showTool(.git_diff);
            self.rememberPanel();
            if (self.git.combined) if (self.git.projection) |projection| {
                if (projection.fileOffset(&self.git.diff_view, path, self.editor_options.font_size * self.editor_options.line_height)) |offset| {
                    self.git.diff_scroll.offset = offset;
                    cx.notify();
                    return;
                }
            };
            services_git.start(self, cx, if (self.git.combined) blk: {
                std.heap.page_allocator.free(self.git.reveal_path);
                self.git.reveal_path = try std.heap.page_allocator.dupe(u8, path);
                break :blk .all_diff;
            } else .{ .diff = .{ .path = path, .staged = status.entries[index].staged and !status.entries[index].unstaged } }) catch |err| try self.reportError(err);
        };
        cx.notify();
    }
    pub fn onGitCommit(self: *Shell, _: *ui.Event(ui.Click), cx: *ui.Context(Shell), index: u32) !void {
        self.git.stash_view = false;
        if (index >= self.git.commits.len) return;
        const oid = try std.heap.page_allocator.dupe(u8, self.git.commits[index].oid);
        defer std.heap.page_allocator.free(oid);
        try self.git.openHistoryTab(oid, if (self.active_pane == .secondary) 1 else 0);
        self.showTool(.git_diff);
        self.rememberPanel();
        if (self.git.diff == null) services_git.start(self, cx, .{ .history = self.git.selected_commit }) catch |err| try self.reportError(err);
        cx.notify();
    }
    pub fn onGitHistoryTab(self: *Shell, _: *ui.Event(ui.Click), cx: *ui.Context(Shell), index: u32) !void {
        if (index >= self.git.history_tabs.items.len) return;
        try self.git.openHistoryTab(self.git.history_tabs.items[index].oid, if (self.active_pane == .secondary) 1 else 0);
        self.showTool(.git_diff);
        self.rememberPanel();
        if (self.git.diff == null) services_git.start(self, cx, .{ .history = self.git.selected_commit }) catch |err| try self.reportError(err);
        cx.notify();
    }
    pub fn onCloseHistoryTab(self: *Shell, _: *ui.Event(ui.Click), cx: *ui.Context(Shell), index: u32) void {
        if (index >= self.git.history_tabs.items.len) return;
        if (std.mem.eql(u8, self.git.selected_commit, self.git.history_tabs.items[index].oid)) self.git.showWorking();
        var removed = self.git.history_tabs.orderedRemove(index);
        removed.deinit();
        cx.notify();
    }
    pub fn onGitScroll(self: *Shell, e: *ui.Event(ui.Input), cx: *ui.Context(Shell)) void {
        if (e.data != .scroll) return;
        self.git.editing.horizontal = @max(0, self.git.editing.horizontal - e.data.scroll.x);
        const height = if (self.git.projection) |projection| projection.contentHeight(&self.git.diff_view, self.editor_options.font_size * self.editor_options.line_height) else 0;
        self.git.diff_scroll.wheel(e.data.scroll.y, height, e.bounds.height);
        e.preventDefault();
        cx.notify();
    }
    pub fn onSearchResult(self: *Shell, _: *ui.Event(ui.Click), cx: *ui.Context(Shell), payload: views_search.Target) !void {
        if (self.search.results == null or self.search.results.?.generation != payload.generation) return;
        services_search.activate(self, cx, payload.group, payload.match) catch |err| {
            try self.reportError(err);
            cx.notify();
        };
    }
    pub fn onReference(self: *Shell, _: *ui.Event(ui.Click), cx: *ui.Context(Shell), index: u32) !void {
        services_language.acceptReference(self, cx, index) catch |err| try self.reportError(err);
    }
    pub fn onCodeAction(self: *Shell, _: *ui.Event(ui.Click), cx: *ui.Context(Shell), index: u32) !void {
        services_language.applyCodeAction(self, cx, index) catch |err| try self.reportError(err);
    }
    pub fn onFindQuery(self: *Shell, cx: *ui.Context(Shell), _: ui.Entity(ui.controls.TextInput)) !void {
        if (self.find.visible) try buffer_find.changed(self, cx);
    }
    pub fn pollLanguage(self: *Shell, cx: *ui.Context(Shell)) !void {
        if (self.window) |handle| _ = cx.app.window(handle) catch |err| switch (err) {
            error.WindowNotFound => return,
            else => return err,
        };
        try services_recovery.poll(self, cx);
        try git_selection.poll(self, cx);
        try search_selection.poll(self, cx);
        try terminal_module.poll(self, cx);
        try buffer_find.poll(self, cx);
        try services_language.poll(self, cx);
        try symbol_hover.poll(self, cx);
        try services_project.poll(self, cx);
        try services_git.pollBlame(self, cx);
        if (!self.git.busy) {
            const current: ?workspace.DocumentId = if (self.active_pane == .secondary and self.secondary != null) self.secondary.?.document else if (self.tabs.items.len > 0) self.tabs.items[self.active].document else null;
            if (!std.meta.eql(current, self.git.active_document) or try cx.app.currentTime() >= self.git.next_refresh) try services_git.start(self, cx, .refresh);
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
        services_language.accept(self, cx, index) catch |err| try self.reportError(err);
        cx.notify();
    }
    pub fn onDefinition(self: *Shell, cx: *ui.Context(Shell)) !void {
        if (self.language.definitions) |message| try services_language.acceptDefinition(self, cx, self.language.definition_pending.?.session, message.data);
    }
    pub fn onGitPickerQuery(self: *Shell, cx: *ui.Context(Shell), _: ui.Entity(ui.controls.TextInput)) void {
        if (self.git.menu == .none) return;
        self.git.picker_index = 0;
        self.git.picker_scroll.offset = 0;
        cx.notify();
    }
    pub fn onSearchQuery(self: *Shell, e: *ui.Event(ui.Input), cx: *ui.Context(Shell)) !void {
        const should_start = switch (e.data) {
            .text => true,
            .key_down => |key| key.key == .enter or key.key == .backspace or key.key == .delete,
            else => false,
        };
        if (!should_start) return;
        services_search.start(self, cx) catch |err| try self.reportError(err);
        if (e.data == .key_down and e.data.key_down.key == .enter) {
            e.preventDefault();
            e.stopPropagation();
        }
        cx.notify();
    }

    pub fn reportError(self: *Shell, err: anyerror) !void {
        try self.setStatus(try self.allocator.dupe(u8, errors.message(err)));
        self.status_is_error = true;
    }
    pub fn setStatus(self: *Shell, owned: []u8) !void {
        self.allocator.free(self.status);
        self.status = owned;
        self.status_is_error = false;
        self.status_origin = .general;
        self.status_sequence +%= 1;
    }
};
