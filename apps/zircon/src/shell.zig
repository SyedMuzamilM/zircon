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
pub const Overlay = enum { none, palette, quick_open, open_path, save_as, find, replace, dirty };
pub const CloseTarget = union(enum) { tab: usize, window };
pub const Fields = struct { query: ui.Entity(ui.controls.TextInput), replacement: ui.Entity(ui.controls.TextInput), path: ui.Entity(ui.controls.TextInput) };
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
    status: []u8 = &.{},
    status_is_error: bool = false,
    dragging: enum { none, sidebar, split } = .none,
    pub fn init(a: std.mem.Allocator, io: std.Io, root_path: []const u8, initial: ?[]const u8) !Shell {
        var self: Shell = .{ .allocator = a, .workspace = try workspace.Workspace.init(a, io, root_path) };
        errdefer self.deinit(a);
        try actions.loadTree(&self);
        if (initial) |path| try self.openPath(path) else try self.newFile();
        return self;
    }
    pub fn deinit(self: *Shell, _: std.mem.Allocator) void {
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
        self.workspace.deinit();
    }
    pub fn render(self: *const Shell, b: *ui.Ui) !ui.Element {
        return @import("view.zig").render(self, b);
    }
    pub fn bootstrap(self: *Shell, cx: *ui.Context(Shell), window: ui.WindowHandle) !void {
        try actions.bootstrap(self, cx, window);
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
            self.editor_focus_request +%= 1;
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
    pub fn onTreeInput(self: *Shell, e: *ui.Event(ui.Input), cx: *ui.Context(Shell)) !void {
        if (e.data == .scroll) {
            self.tree_scroll.wheel(e.data.scroll.y, @as(f32, @floatFromInt(self.tree.items.len)) * 24, e.bounds.height);
            e.preventDefault();
            cx.notify();
        }
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
