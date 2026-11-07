//! Language discovery, document rebinding and searchable selection.
const std = @import("std");
const ui = @import("zircon_ui");
const Shell = @import("../../shell.zig").Shell;
const v = @import("../components.zig");
const view = @import("../../view.zig");
const panel = @import("panel.zig");
pub const Choice = struct { name: []const u8, path: []const u8 };
const defaults = [_]Choice{
    .{ .name = "Plain Text", .path = "plain.txt" }, .{ .name = "Zig", .path = "file.zig" },
    .{ .name = "Rust", .path = "file.rs" },         .{ .name = "JSON", .path = "file.json" },
    .{ .name = "Markdown", .path = "file.md" },
};
pub fn choices(self: *const Shell, a: std.mem.Allocator, query: []const u8) ![]Choice {
    var items: std.ArrayList(Choice) = .empty;
    for (defaults) |choice| if (view.matches(query, choice.name)) try items.append(a, choice);
    if (self.extension_snapshot) |snapshot| for (snapshot.installed()) |extension| if (extension.enabled) {
        for (extension.languages) |language| {
            var duplicate = false;
            for (defaults) |choice| if (std.ascii.eqlIgnoreCase(choice.name, language.name)) {
                duplicate = true;
                break;
            };
            if (duplicate or !view.matches(query, language.name)) continue;
            const path = if (language.extensions.len > 0) try std.fmt.allocPrint(a, "file.{s}", .{std.mem.trimStart(u8, language.extensions[0], ".")}) else if (language.filenames.len > 0) language.filenames[0] else continue;
            try items.append(a, .{ .name = language.name, .path = path });
        }
    };
    return items.toOwnedSlice(a);
}
fn onChoice(self: *Shell, event: *ui.Event(ui.Click), cx: *ui.Context(Shell), index: u32) !void {
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const query = try @import("../../actions.zig").field(cx, self.fields.?.query, arena.allocator());
    const items = try choices(self, arena.allocator(), query);
    if (index < items.len) try choose(self, event, cx, items[index]);
}
pub fn choose(self: *Shell, _: *ui.Event(ui.Click), cx: *ui.Context(Shell), choice: Choice) !void {
    const current = try @import("../../actions.zig").active(self);
    const path = try self.allocator.dupe(u8, choice.path);
    errdefer self.allocator.free(path);
    const name = try self.allocator.dupe(u8, choice.name);
    errdefer self.allocator.free(name);
    try @import("../../services/language.zig").invalidateDocument(self, current.id);
    for (self.tabs.items) |*tab| if (std.meta.eql(tab.document, current.id)) {
        if (tab.language_path) |old| self.allocator.free(old);
        if (tab.language_name) |old| self.allocator.free(old);
        tab.language_path = path;
        tab.language_name = name;
        @import("../../services/extensions.zig").applyLanguage(self, &tab.editor, path);
        tab.editor.syntax_cache.clear();
        tab.editor.grammar_revision = null;
        if (tab.secondary_state) |*state| {
            @import("../../services/extensions.zig").applyLanguage(self, state, path);
            state.syntax_cache.clear();
            state.grammar_revision = null;
        }
        if (self.secondary) |*pane| if (std.meta.eql(pane.document, current.id)) {
            @import("../../services/extensions.zig").applyLanguage(self, &pane.editor, path);
            pane.editor.syntax_cache.clear();
            pane.editor.grammar_revision = null;
        };
        break;
    };
    self.popup = .none;
    self.editor_focus_request +%= 1;
    cx.notify();
}

pub fn render(self: *const Shell, b: *ui.Ui) !ui.Element {
    const c = self.colors;
    const query = try view.fieldText(b, self.fields.?.query);
    var rows: std.ArrayList(ui.Element) = .empty;
    try panel.query(self, b, &rows);
    var options: std.ArrayList(ui.Element) = .empty;
    const items = try choices(self, b.allocator(), query);
    for (items, 0..) |choice, i| {
        const id = if (self.active_pane == .secondary and self.secondary != null) self.secondary.?.document else self.tabs.items[self.active].document;
        const selected_name = self.languageName(id);
        const selected = if (selected_name) |name| std.mem.eql(u8, name, choice.name) else std.mem.eql(u8, std.fs.path.extension((try self.workspace.getConst(id)).path orelse ""), std.fs.path.extension(choice.path));
        try options.append(b.allocator(), try b.button(.{ .label = choice.name, .children = &.{ try v.fileGlyph(self, b, choice.path, false, false, 14), try v.text(b, choice.name, c.text, 13), try b.div(.{ .flex_grow = 1 }, &.{}), try v.text(b, if (selected) "Current" else "", c.muted, 11) }, .on_click = b.onClickWith(onChoice, @as(u32, @intCast(i))), .style = .{ .direction = .row, .height = .{ .px = 30 }, .flex_shrink = 0, .align_items = .center, .gap = 8, .padding = .{ .left = 10, .right = 10 }, .background = if (i == @min(self.overlay_index, items.len -| 1)) c.selected else null, .hover_background = c.hover } }));
    }
    if (options.items.len == 0) try options.append(b.allocator(), try v.text(b, "No matches", c.muted, 13));
    const visible = try panel.options(self, b, &rows, options.items, 30);
    return panel.render(self, b, .{ .width = 520, .height = 52 + visible, .centered = true }, rows.items);
}
pub fn input(self: *Shell, e: *ui.Event(ui.Input), cx: *ui.Context(Shell)) !bool {
    const key = e.data.key_down.key;
    if (key != .up and key != .down and key != .enter) return false;
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const query = try @import("../../actions.zig").field(cx, self.fields.?.query, arena.allocator());
    const items = try choices(self, arena.allocator(), query);
    if (items.len > 0) {
        self.overlay_index = @min(self.overlay_index, items.len - 1);
        if (key == .down) self.overlay_index = (self.overlay_index + 1) % items.len;
        if (key == .up) self.overlay_index = (self.overlay_index + items.len - 1) % items.len;
        if (key == .enter) {
            var click: ui.Event(ui.Click) = .{ .data = .{} };
            try choose(self, &click, cx, items[self.overlay_index]);
        }
    }
    return true;
}
