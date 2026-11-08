//! Command palette, quick-open and path dialogs. Inputs and opening behavior
//! are kept beside their rendered layouts.
const std = @import("std");
const ui = @import("zircon_ui");
const actions = @import("../actions.zig");
const catalogue = @import("../commands.zig");
const shell = @import("../shell.zig");
const components = @import("components.zig");
const field_input = @import("input.zig");
const views_open_project = @import("open_project.zig");
const Shell = shell.Shell;
const Command = catalogue.Command;
const Palette = components.Palette;
const result_limit = 12;
const label = workspace_label;
const commandButton = components.actionButton;

pub const Fields = struct {
    query: field_input.Handle,
    path: field_input.Handle,

    pub fn init(cx: *ui.Context(Shell), a: std.mem.Allocator) !Fields {
        return .{
            .query = try field_input.create(cx, a, .{}),
            .path = try field_input.create(cx, a, .{}),
        };
    }
};

fn workspace_label(b: *ui.Ui, _: Palette, bytes: []const u8, color: ui.Color, size: f32) !ui.Element {
    return b.fluent().text(bytes).text_size(size).text_color(color).build();
}

pub fn render(self: *const Shell, b: *ui.Ui) !ui.Element {
    if (self.overlay == .open_project) return views_open_project.render(self, b);
    const colors = self.colors;
    const fields = self.fields.?;
    const width = @min(if (self.overlay == .palette or self.overlay == .quick_open) @as(f32, 560) else 580, @max(0, b.viewport().width - 48));
    var children: std.ArrayList(ui.Element) = .empty;
    const title: []const u8 = switch (self.overlay) {
        .open_project => unreachable,
        .palette => "Commands",
        .quick_open => "Go to file",
        .open_path => "Open file",
        .extension_path => "Install development extension",
        .project_search => "Search project",
        .save_as => "Save file as",
        .find => "Find",
        .replace => "Find and replace",
        .rename => "Rename symbol",
        .dirty => "Save your changes?",
        .none => unreachable,
    };
    const picker = self.overlay == .palette or self.overlay == .quick_open;
    const title_row = try b.fluent().div().h(.{ .px = 26 }).items_center().gap_px(12).flex().children(.{
        b.fluent().adopt(try label(b, colors, title, colors.text, 15))
            .style(.{ .flex_grow = 1, .text = .{ .size = 15, .color = colors.text } }),
        commandButton(b, colors, .dismiss, "Esc", false),
    }).build();
    if (!picker) try children.append(b.allocator(), title_row);
    switch (self.overlay) {
        .open_project => unreachable,
        .palette, .quick_open => {
            try children.append(b.allocator(), try b.fluent().adopt(try inputField(b, fields.workspace.query, "query", true))
                .style(.{ .height = .{ .px = 38 }, .flex_shrink = 0 })
                .build());
            try children.append(b.allocator(), try components.rule(b, colors));
            const query = try field_input.text(b, fields.workspace.query);
            if (self.overlay == .palette) {
                const filtered = try filteredCommands(b, query);
                const limit = resultCapacity(self, b);
                const start = resultStart(filtered.len, self.overlay_index, limit);
                for (filtered[start..@min(start + limit, filtered.len)], start..) |index, visible| {
                    const entry = catalogue.commands[index];
                    try children.append(b.allocator(), try components.menuRow(b, colors, entry.command, entry.label, try self.key_bindings.shortcut(b.allocator(), entry.command), visible == self.overlay_index));
                }
                if (filtered.len == 0) try children.append(b.allocator(), try label(b, colors, "No matching commands.", colors.muted, 12));
            } else {
                const filtered = try filteredFiles(self, b, query);
                const limit = resultCapacity(self, b);
                const start = resultStart(filtered.len, self.overlay_index, limit);
                for (filtered[start..@min(start + limit, filtered.len)], start..) |index, visible| {
                    const row = try b.fluent().button(.{
                        .label = self.file_index.items[index].label,
                    })
                        .style(resultStyle(colors, visible == self.overlay_index))
                        .on_click(b.onClickWith(Shell.onFile, @as(u32, @intCast(index))))
                        .build();
                    try children.append(b.allocator(), try b.fluent().adopt(row)
                        .id(.{ .number = @intCast(index) })
                        .build());
                }
                if (filtered.len == 0) try children.append(b.allocator(), try label(b, colors, if (self.indexing) "Indexing files…" else "No matching files. Open a file by path with ⌘O.", colors.muted, 12));
            }
            try children.append(b.allocator(), try components.rule(b, colors));
            try children.append(b.allocator(), try b.fluent().div()
                .h(.{ .px = 24 })
                .shrink_0()
                .items_center()
                .gap_px(10)
                .padding(.{ .left = 10, .right = 8 })
                .flex()
                .children(&.{
                    try label(b, colors, "↑ ↓ to navigate", colors.muted, 11),
                    try b.fluent().div().grow().children(.{}).build(),
                    try label(b, colors, "↵ Confirm", colors.muted, 11),
                    try label(b, colors, "esc Close", colors.muted, 11),
                }).build());
        },
        .open_path, .save_as, .extension_path => {
            try children.appendSlice(b.allocator(), &.{
                try label(b, colors, "Enter a path relative to this project, or an absolute path.", colors.muted, 12),
                try inputField(b, fields.workspace.path, "path", true),
                try footer(b, &.{ try commandButton(b, colors, .dismiss, "Cancel", false), try commandButton(b, colors, .submit_path, if (self.overlay == .extension_path) "Install" else if (self.overlay == .save_as) "Save" else "Open", true) }),
            });
        },
        .project_search => {
            const input = try inputField(b, fields.project_search.query, "query", true);
            try children.appendSlice(b.allocator(), &.{ try b.fluent().adopt(input)
                .listeners(.{ .on_input = b.onInput(Shell.onSearchQuery) })
                .build(), try commandButton(b, colors, .run_project_search, "Search", true) });
        },
        .find, .replace => {
            try children.append(b.allocator(), try inputField(b, fields.workspace.query, "query", true));
            if (self.overlay == .replace) try children.append(b.allocator(), try inputField(b, fields.buffer_search.replacement, "replacement", false));
            var buttons: std.ArrayList(ui.Element) = .empty;
            try buttons.appendSlice(b.allocator(), &.{ try commandButton(b, colors, .find_previous, "Previous", false), try commandButton(b, colors, .find_next, "Next", true) });
            if (self.overlay == .replace) try buttons.appendSlice(b.allocator(), &.{ try commandButton(b, colors, .replace_one, "Replace", false), try commandButton(b, colors, .replace_all, "Replace all", false) });
            try children.append(b.allocator(), try footer(b, buttons.items));
            try children.append(b.allocator(), try label(b, colors, "Search matches exact text. Escape returns to the editor.", colors.muted, 11));
        },
        .rename => {
            try children.append(b.allocator(), try label(b, colors, "Rename the symbol in every file supported by the language server.", colors.muted, 12));
            try children.append(b.allocator(), try inputField(b, fields.workspace.query, "rename", true));
            try children.append(b.allocator(), try footer(b, &.{ try commandButton(b, colors, .dismiss, "Cancel", false), try commandButton(b, colors, .submit_rename, "Rename", true) }));
        },
        .dirty => {
            try children.append(b.allocator(), try label(b, colors, "Your changes will be lost if you discard them.", colors.muted, 13));
            const dirty_title = try pendingTitle(self, b);
            if (dirty_title.len > 0) try children.append(b.allocator(), try label(b, colors, dirty_title, colors.text, 13));
            try children.append(b.allocator(), try footer(b, &.{ try commandButton(b, colors, .dismiss, "Cancel", false), try commandButton(b, colors, .discard_dirty, "Discard", false), try commandButton(b, colors, .save_dirty, "Save", true) }));
        },
        .none => unreachable,
    }
    if (self.status.len > 0 and self.status_is_error) try children.append(b.allocator(), try label(b, colors, self.status, colors.warning, 12));
    const panel_height = @min(try overlayHeight(self, b), @max(120, b.viewport().height - 100));
    const panel = try b.fluent().adopt(try components.floatingPanel(b, colors, .{ .width = width, .height = panel_height }, ui.Insets.all(if (picker) 6 else 12), if (picker) 0 else 8, children.items))
        .id(.{ .string = "dialog" })
        .build();
    const shade: ui.Color = .{ .r = 0, .g = 0, .b = 0, .a = if (picker) 0 else 0.2 };
    return b.fluent().div().padding(.{
        .top = @min(@as(f32, 78), b.viewport().height * 0.13),
        .bottom = 20,
    })
        .items_center()
        .justify(.start)
        .background(shade)
        .overflow_hidden()
        .stack()
        .children(.{panel})
        .id(.{ .string = @tagName(self.overlay) })
        .listeners(.{ .on_input = b.onInput(Shell.onOverlayInput) })
        .modal()
        .build();
}

fn overlayHeight(self: *const Shell, b: *ui.Ui) !f32 {
    const error_height: f32 = if (self.status.len > 0 and self.status_is_error) 30 else 0;
    return error_height + switch (self.overlay) {
        .open_project => 432,
        .palette, .quick_open => blk: {
            const query = try field_input.text(b, self.fields.?.workspace.query);
            const count = if (self.overlay == .palette) (try filteredCommands(b, query)).len else (try filteredFiles(self, b, query)).len;
            break :blk 84 + @as(f32, @floatFromInt(@max(@as(usize, 1), @min(count, resultCapacity(self, b))))) * 30;
        },
        .open_path, .save_as, .extension_path => 204,
        .find => 196,
        .project_search => 174,
        .replace => 246,
        .rename => 174,
        .dirty => 188,
        .none => 0,
    };
}

fn resultStart(count: usize, selected: usize, limit: usize) usize {
    if (count <= limit or selected < limit) return 0;
    return @min(selected - limit + 1, count - limit);
}

fn resultCapacity(self: *const Shell, b: *const ui.Ui) usize {
    const reserved: f32 = if (self.status.len > 0 and self.status_is_error) 222 else 192;
    const available = @max(42, b.viewport().height - reserved);
    return @min(result_limit, @as(usize, @intFromFloat(@floor(available / 30))));
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

fn resultStyle(colors: Palette, selected: bool) ui.Style {
    return .{ .height = .{ .px = 30 }, .flex_shrink = 0, .padding = .{ .left = 10, .right = 10, .top = 7 }, .radius = components.metrics.control_radius, .background = if (selected) colors.selected else colors.panel, .hover_background = colors.hover, .text = .{ .size = 12, .color = colors.text }, .overflow = .hidden };
}

fn footer(b: *ui.Ui, children: []const ui.Element) !ui.Element {
    return b.fluent().div().h(.{ .px = 30 }).gap_px(8).justify(.end).flex().children(children).build();
}

fn inputField(b: *ui.Ui, handle: ui.Entity(ui.controls.TextInput), key: []const u8, focus: bool) !ui.Element {
    const element = try b.fluent().view(handle).id(.{ .string = key }).build();
    return if (focus) b.fluent().adopt(element).autofocus().build() else element;
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

pub fn show(self: *Shell, cx: *ui.Context(Shell), which: shell.Overlay) !void {
    self.overlay = which;
    self.overlay_index = 0;
    if (self.fields) |fields| switch (which) {
        .palette => try field_input.reset(cx, fields.workspace.query, "", .{
            .placeholder = "Search commands…",
            .height = 38,
            .font_size = 14,
            .borderless = true,
            .transparent_background = true,
        }),
        .quick_open => try field_input.reset(cx, fields.workspace.query, "", .{
            .placeholder = "Find a file…",
            .height = 38,
            .font_size = 14,
            .borderless = true,
            .transparent_background = true,
        }),
        .open_path => try field_input.reset(cx, fields.workspace.path, "", .{ .placeholder = "Path relative to the project, or an absolute path" }),
        .extension_path => try field_input.reset(cx, fields.workspace.path, "", .{ .placeholder = "Directory containing extension.json" }),
        .save_as => {
            const selected = try actions.saveTarget(self);
            const record = try self.workspace.getConst(self.tabs.items[selected].document);
            try field_input.reset(cx, fields.workspace.path, record.path orelse "untitled.zig", .{ .placeholder = "Save file as…" });
        },
        .find, .replace => try field_input.reset(cx, fields.workspace.query, "", .{ .placeholder = "Find in document…" }),
        .rename => try field_input.reset(cx, fields.workspace.query, "", .{ .placeholder = "New symbol name…" }),
        else => {},
    };
}

pub fn filteredCount(self: *Shell, cx: *ui.Context(Shell)) !usize {
    const query = try field_input.read(cx, self.fields.?.workspace.query, self.allocator);
    defer self.allocator.free(query);
    var count: usize = 0;
    if (self.overlay == .palette) {
        for (catalogue.commands) |entry| {
            if (matches(query, entry.label)) count += 1;
        }
    } else {
        for (self.file_index.items) |entry| {
            if (matches(query, entry.label)) count += 1;
        }
    }
    return count;
}

pub fn activateSelected(self: *Shell, cx: *ui.Context(Shell)) !void {
    const query = try field_input.read(cx, self.fields.?.workspace.query, self.allocator);
    defer self.allocator.free(query);
    var n: usize = 0;
    if (self.overlay == .palette) {
        for (catalogue.commands) |entry| {
            if (!matches(query, entry.label)) continue;
            if (n == self.overlay_index) {
                self.overlay = .none;
                actions.execute(self, cx, entry.command, null) catch |err| try self.reportError(err);
                return;
            }
            n += 1;
        }
    } else {
        for (self.file_index.items) |entry| {
            if (!matches(query, entry.label)) continue;
            if (n == self.overlay_index) {
                try self.openPath(entry.path);
                return;
            }
            n += 1;
        }
    }
}
