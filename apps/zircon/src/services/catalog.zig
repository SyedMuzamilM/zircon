//! Search the official Zed registry and install through the atomic local registry.
const std = @import("std");
const ui = @import("zircon_ui");
const actions = @import("../actions.zig");
const language_suggestions = @import("../language_suggestions.zig");
const shell = @import("../shell.zig");
const host = @import("extension_host.zig");
const extensions_module = @import("extensions.zig");
const Shell = shell.Shell;
const a = std.heap.page_allocator;
pub const Entry = struct { installed_id: ?[]const u8 = null, source: []const u8 = "zed", id: []const u8, name: []const u8, version: []const u8, description: []const u8, provides: []const []const u8, metadata_available: bool };
pub const Response = struct { source: []const u8, total: usize, entries: []const Entry };
pub const Model = struct {
    parsed: ?std.json.Parsed(Response) = null,
    generation: u64 = 0,
    busy: bool = false,
    installing: ?[]u8 = null,
    install_id: ?[]u8 = null,
    show_available: bool = false,
    error_text: []u8 = &.{},
    scroll: ui.controls.Scroll = .{},
    installed_scroll: ui.controls.Scroll = .{},
    pub fn deinit(self: *Model) void {
        if (self.parsed) |*p| p.deinit();
        if (self.installing) |path| a.free(path);
        if (self.install_id) |id| a.free(id);
        a.free(self.error_text);
    }
};
fn errorText(self: *Shell, message: []const u8) !void {
    const next = try a.dupe(u8, message);
    a.free(self.catalog.error_text);
    self.catalog.error_text = next;
}

pub fn search(self: *Shell, cx: *ui.Context(Shell)) !void {
    if (self.catalog.busy) return;
    var query: []u8 = undefined;
    try cx.read(self.fields.?.extensions.query, ui.controls.TextInput.copy, .{ a, &query });
    defer a.free(query);
    self.catalog.generation +%= 1;
    try host.start(self, cx, &.{ "catalog", query }, null, .{ .generation = self.catalog.generation }, searched);
    self.catalog.busy = true;
    self.catalog.scroll.offset = 0;
    try errorText(self, "");
    cx.notify();
}

fn searched(self: *Shell, cx: *ui.Context(Shell), raw: anyerror!*host.Box) !void {
    self.catalog.busy = false;
    const box = raw catch |err| {
        try errorText(self, @errorName(err));
        cx.notify();
        return;
    };
    var result = box.take();
    defer result.deinit();
    if (result.stamp.generation != self.catalog.generation) return;
    if (!result.success) {
        try errorText(self, result.stderr);
        cx.notify();
        return;
    }
    const parsed = std.json.parseFromSlice(Response, a, result.stdout, .{ .allocate = .alloc_always }) catch |err| {
        try errorText(self, @errorName(err));
        cx.notify();
        return;
    };
    if (self.catalog.parsed) |*old| old.deinit();
    self.catalog.parsed = parsed;
    cx.notify();
}

pub fn install(self: *Shell, cx: *ui.Context(Shell), id: []const u8) !void {
    if (self.catalog.installing != null) return error.ExtensionInstallBusy;
    const registry = if (self.extensions) |*r| r else return error.ExtensionsNotConfigured;
    const directory = try std.fmt.allocPrint(a, "{s}/.zed-download-{d}", .{ registry.home, std.Io.Clock.real.now(self.workspace.io).nanoseconds });
    errdefer a.free(directory);
    const owned_id = try a.dupe(u8, id);
    errdefer a.free(owned_id);
    try host.start(self, cx, &.{ "install", id, directory }, null, .{}, installed);
    self.catalog.installing = directory;
    self.catalog.install_id = owned_id;
    try errorText(self, "");
    cx.notify();
}

pub fn importDev(self: *Shell, cx: *ui.Context(Shell), source: []const u8) !void {
    if (self.catalog.installing != null) return error.ExtensionInstallBusy;
    const registry = if (self.extensions) |*r| r else return error.ExtensionsNotConfigured;
    const directory = try std.fmt.allocPrint(a, "{s}/.zed-import-{d}", .{ registry.home, std.Io.Clock.real.now(self.workspace.io).nanoseconds });
    errdefer a.free(directory);
    const id = try a.dupe(u8, "dev-extension");
    errdefer a.free(id);
    try host.start(self, cx, &.{ "import-copy", source, directory }, null, .{}, installed);
    self.catalog.installing = directory;
    self.catalog.install_id = id;
    cx.notify();
}

fn installed(self: *Shell, cx: *ui.Context(Shell), raw: anyerror!*host.Box) !void {
    const directory = self.catalog.installing orelse return;
    self.catalog.installing = null;
    defer a.free(directory);
    defer std.Io.Dir.cwd().deleteTree(self.workspace.io, directory) catch {};
    if (self.catalog.install_id) |id| a.free(id);
    self.catalog.install_id = null;
    const box = raw catch |err| {
        try errorText(self, @errorName(err));
        cx.notify();
        return;
    };
    var result = box.take();
    defer result.deinit();
    if (!result.success) {
        try errorText(self, result.stderr);
        cx.notify();
        return;
    }
    if (self.extensions.?.install(directory)) |_| {} else |err| switch (err) {
        error.ExtensionAlreadyInstalled => self.extensions.?.upgrade(directory) catch |failure| {
            try errorText(self, @errorName(failure));
            cx.notify();
            return;
        },
        else => {
            try errorText(self, @errorName(err));
            cx.notify();
            return;
        },
    }
    extensions_module.refresh(self, cx) catch |err| {
        try errorText(self, @errorName(err));
        cx.notify();
        return;
    };
    self.catalog.show_available = false;
    cx.notify();
}

pub fn recommend(self: *Shell, cx: *ui.Context(Shell)) !void {
    const current = try actions.active(self);
    const record = try self.workspace.getConst(current.id);
    const suffix = language_suggestions.query(record.path orelse record.title());
    const Set = struct {
        fn call(field: *ui.controls.TextInput, context: *ui.Context(ui.controls.TextInput), value: []const u8) !void {
            try field.bytes.ensureTotalCapacity(field.allocator, value.len);
            field.bytes.clearRetainingCapacity();
            field.bytes.appendSliceAssumeCapacity(value);
            field.cursor = value.len;
            field.anchor = value.len;
            field.marked = null;
            field.revision +%= 1;
            context.notify();
        }
    };
    try cx.update(self.fields.?.extensions.query, Set.call, .{suffix});
    self.showTool(.extensions);
    self.tool_tabs.extensions = true;
    self.catalog.show_available = true;
    try search(self, cx);
}
