//! Resolves installed data contributions into effective editor behavior. The
//! shell retains a registry generation while any editor profile borrows it.
const std = @import("std");
const ui = @import("zircon_ui");
const ext = @import("zircon_extensions");
const editor = @import("zircon_editor");
const Shell = @import("../shell.zig").Shell;
pub fn refresh(self: *Shell, cx: *ui.Context(Shell)) !void {
    if (self.extensions) |*registry| {
        var next = registry.snapshot();
        var previous = self.extension_snapshot;
        self.extension_snapshot = next;
        self.onSettings(cx, self.settings.?) catch |err| {
            self.extension_snapshot = previous;
            next.deinit();
            return err;
        };
        self.language.deinit(self.allocator);
        if (previous) |*snapshot| snapshot.deinit();
    }
    cx.notify();
}
pub fn color(value: ext.Color) ui.Color {
    return .{ .r = @as(f32, @floatFromInt((value.rgba >> 24) & 255)) / 255, .g = @as(f32, @floatFromInt((value.rgba >> 16) & 255)) / 255, .b = @as(f32, @floatFromInt((value.rgba >> 8) & 255)) / 255, .a = @as(f32, @floatFromInt(value.rgba & 255)) / 255 };
}
pub fn applyTheme(self: *Shell, id: []const u8) void {
    const snapshot = self.extension_snapshot orelse return;
    const contribution = snapshot.resolveTheme(id) orelse return;
    inline for (.{ "document", "chrome", "sidebar", "panel", "line", "text", "muted", "accent", "selected", "warning", "primary" }) |name| @field(self.colors, name) = color(@field(contribution.colors, name));
    self.colors.tab_bar = self.colors.sidebar;
    self.colors.hover = self.colors.selected;
    self.colors.element = self.colors.chrome;
    self.colors.border_subtle = self.colors.line;
    self.colors.primary_hover = self.colors.selected;
    self.colors.on_primary = self.colors.text;
    const palette: editor.Theme = .{ .background = color(contribution.colors.document), .foreground = color(contribution.colors.text), .active_line = color(contribution.colors.chrome), .selection = color(contribution.colors.selected), .inactive_selection = color(contribution.colors.panel), .caret = color(contribution.colors.accent), .line_number = color(contribution.colors.muted), .active_number = color(contribution.colors.text), .scrollbar = color(contribution.colors.line), .tokens = .{ color(contribution.syntax.plain), color(contribution.syntax.keyword), color(contribution.syntax.string), color(contribution.syntax.number), color(contribution.syntax.comment), color(contribution.syntax.punctuation), color(contribution.syntax.builtin) } };
    self.editor_options.theme = palette;
    for (self.tabs.items) |*tab| tab.editor.theme = palette;
    if (self.secondary) |*pane| pane.editor.theme = palette;
}
pub fn applyLanguage(self: *Shell, state: *editor.Editor, path: []const u8) void {
    state.language_profile = null;
    state.language = editor.syntax.languageForPath(path);
    const snapshot = self.extension_snapshot orelse return;
    if (snapshot.languageForPath(path)) |language| {
        state.language = .custom;
        state.language_profile = .{ .keywords = language.keywords, .line_comment = language.line_comment, .block_comment = if (language.block_comment) |block| .{ .start = block.start, .end = block.end, .nested = block.nested } else null, .string_delimiters = language.string_delimiters };
    }
}
pub fn install(self: *Shell, cx: *ui.Context(Shell), path: []const u8) !void {
    const registry = if (self.extensions) |*value| value else return error.ExtensionsNotConfigured;
    _ = try registry.install(path);
    try refresh(self, cx);
    self.panel = .extensions;
}
pub fn installBundled(self: *Shell, cx: *ui.Context(Shell)) !void {
    const registry = if (self.extensions) |*value| value else return error.ExtensionsNotConfigured;
    const directory = try std.fs.path.join(self.allocator, &.{ registry.home, ".bundled-oxide" });
    defer self.allocator.free(directory);
    try std.Io.Dir.cwd().createDirPath(self.workspace.io, directory);
    defer std.Io.Dir.cwd().deleteTree(self.workspace.io, directory) catch {};
    const manifest = try std.fs.path.join(self.allocator, &.{ directory, "extension.json" });
    defer self.allocator.free(manifest);
    try std.Io.Dir.cwd().writeFile(self.workspace.io, .{ .sub_path = manifest, .data = ext.bundledManifest });
    try install(self, cx, directory);
}
