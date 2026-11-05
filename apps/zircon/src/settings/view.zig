//! A separate native child window. All controls update the shared, persisted
//! settings entity; no editable state is copied into a detached preferences UI.
const std = @import("std");
const ui = @import("zircon_ui");
const model = @import("model.zig");
const themes = @import("../theme.zig");
const Category = enum { appearance, editor, version_control };
const Change = enum { font_down, font_up, tab_two, tab_four, tab_eight, dark, light, motion, numbers, gutters };
const Contribution = struct { id: [256]u8 = @splat(0), len: u16, icons: bool };
pub const View = struct {
    allocator: std.mem.Allocator,
    settings: ui.Entity(model.Settings),
    workspace: ?ui.Entity(@import("../shell.zig").Shell) = null,
    query: ?ui.Entity(ui.controls.TextInput) = null,
    category: Category = .appearance,
    error_value: ?anyerror = null,
    pub fn bootstrap(self: *View, cx: *ui.Context(View)) !void {
        var input = try ui.controls.TextInput.init(self.allocator, "");
        input.placeholder = "Search settings…";
        self.query = cx.createChild(ui.controls.TextInput, input) catch |err| {
            input.deinit(input.allocator);
            return err;
        };
        cx.notify();
    }
    pub fn render(self: *const View, b: *ui.Ui) !ui.Element {
        var values: model.Values = undefined;
        try b.watch(self.settings, model.Settings.copy, .{ b.allocator(), &values });
        var snapshot: ?@import("zircon_extensions").Snapshot = null;
        if (self.workspace) |handle| try b.watch(handle, @import("../shell.zig").Shell.copyExtensions, .{&snapshot});
        defer if (snapshot) |*value| value.deinit();
        var colors: themes.Palette = if (std.mem.eql(u8, values.theme, "zircon.light")) themes.Palette.light else .{};
        if (snapshot) |generation| if (generation.resolveTheme(values.theme)) |theme| {
            inline for (.{ "document", "chrome", "sidebar", "panel", "line", "text", "muted", "accent", "selected", "warning", "primary" }) |name| @field(colors, name) = @import("../services/extensions.zig").color(@field(theme.colors, name));
        };
        var query: []u8 = &.{};
        if (self.query) |handle| try b.watch(handle, ui.controls.TextInput.copy, .{ b.allocator(), &query });
        var navigation: std.ArrayList(ui.Element) = .empty;
        try navigation.append(b.allocator(), try b.div(.{ .height = .{ .px = 42 }, .flex_shrink = 0 }, &.{}));
        if (self.query) |handle| try navigation.append(b.allocator(), try b.autofocus(try b.key(.{ .string = "settings-search" }, try b.view(handle))));
        inline for (std.meta.tags(Category)) |category| try navigation.append(b.allocator(), try b.button(.{ .label = categoryName(category), .on_click = try b.onClickWith(category, select), .style = .{ .height = .{ .px = 36 }, .padding = .{ .left = 12, .top = 9 }, .radius = 4, .background = if (self.category == category) colors.selected else colors.sidebar, .text = .{ .size = 13, .color = colors.text } } }));
        var content: std.ArrayList(ui.Element) = .empty;
        try content.append(b.allocator(), try heading(b, "Settings", colors, 24));
        if (self.error_value) |err| try content.append(b.allocator(), try heading(b, @import("../errors.zig").message(err), colors, 13));
        const searching = std.mem.trim(u8, query, " \t").len > 0;
        if ((searching or self.category == .appearance) and matches(query, "appearance theme colors motion")) {
            try content.append(b.allocator(), try heading(b, "Appearance", colors, 18));
            try content.append(b.allocator(), try row(b, "Color theme", "Changes the editor, syntax and workspace colors.", &.{ try button(b, .dark, "Dark", colors), try button(b, .light, "Light", colors) }, colors));
            if (snapshot) |generation| for (generation.installed()) |entry| {
                if (!entry.enabled) continue;
                for (entry.themes) |theme| try content.append(b.allocator(), try row(b, theme.name, if (std.mem.eql(u8, values.theme, theme.id)) "Active color theme" else entry.name, &.{try contributionButton(b, theme.id, false, colors)}, colors));
                for (entry.icon_themes) |icons| try content.append(b.allocator(), try row(b, icons.name, if (std.mem.eql(u8, values.icon_theme, icons.id)) "Active icon theme" else entry.name, &.{try contributionButton(b, icons.id, true, colors)}, colors));
            };
            try content.append(b.allocator(), try row(b, "Reduced motion", "Snap decorative transitions to their final value.", &.{try button(b, .motion, if (values.reduced_motion) "On" else "Off", colors)}, colors));
        }
        if ((searching or self.category == .editor) and matches(query, "editor font size tabs indentation line numbers")) {
            try content.append(b.allocator(), try heading(b, "Editor", colors, 18));
            try content.append(b.allocator(), try row(b, "Font size", try std.fmt.allocPrint(b.allocator(), "{d:.0} px", .{values.font_size}), &.{ try button(b, .font_down, "−", colors), try button(b, .font_up, "+", colors) }, colors));
            try content.append(b.allocator(), try row(b, "Tab width", "Spaces per indentation stop.", &.{ try button(b, .tab_two, "2", colors), try button(b, .tab_four, "4", colors), try button(b, .tab_eight, "8", colors) }, colors));
            try content.append(b.allocator(), try row(b, "Line numbers", "Show source line numbers in the editor gutter.", &.{try button(b, .numbers, if (values.line_numbers) "On" else "Off", colors)}, colors));
        }
        if ((searching or self.category == .version_control) and matches(query, "version control git changes gutters")) {
            try content.append(b.allocator(), try heading(b, "Version control", colors, 18));
            try content.append(b.allocator(), try row(b, "Git change markers", "Show added, modified and deleted lines.", &.{try button(b, .gutters, if (values.git_gutters) "On" else "Off", colors)}, colors));
        }
        try content.append(b.allocator(), try heading(b, "Changes apply immediately.", colors, 12));
        const main = try b.column(.{ .flex_grow = 1, .padding = .{ .left = 36, .right = 36, .top = 48 }, .gap = 22, .background = colors.document, .overflow = .hidden }, content.items);
        const header = try b.dragRegion(try b.div(.{ .height = .{ .px = 40 }, .flex_shrink = 0 }, &.{}));
        return b.column(.{ .background = colors.document }, &.{ header, try b.row(.{ .flex_grow = 1 }, &.{ try b.column(.{ .width = .{ .px = 246 }, .flex_shrink = 0, .padding = ui.Insets.all(12), .gap = 10, .background = colors.sidebar }, navigation.items), main }) });
    }
    fn select(self: *View, _: *ui.Event(ui.Click), cx: *ui.Context(View), category: Category) void {
        self.category = category;
        cx.notify();
    }
    fn contribution(self: *View, _: *ui.Event(ui.Click), cx: *ui.Context(View), value: Contribution) !void {
        const id = value.id[0..value.len];
        cx.update(self.settings, model.Settings.apply, .{if (value.icons) model.Patch{ .icon_theme = id } else model.Patch{ .theme = id }}) catch |err| {
            self.error_value = err;
            cx.notify();
            return;
        };
        self.error_value = null;
        cx.notify();
    }
    fn change(self: *View, _: *ui.Event(ui.Click), cx: *ui.Context(View), which: Change) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        var values: model.Values = undefined;
        try cx.read(self.settings, model.Settings.copy, .{ arena.allocator(), &values });
        const patch: model.Patch = switch (which) {
            .font_down => .{ .font_size = @max(10, values.font_size - 1) },
            .font_up => .{ .font_size = @min(32, values.font_size + 1) },
            .tab_two => .{ .tab_width = 2 },
            .tab_four => .{ .tab_width = 4 },
            .tab_eight => .{ .tab_width = 8 },
            .dark => .{ .theme = "zircon.dark" },
            .light => .{ .theme = "zircon.light" },
            .motion => .{ .reduced_motion = !values.reduced_motion },
            .numbers => .{ .line_numbers = !values.line_numbers },
            .gutters => .{ .git_gutters = !values.git_gutters },
        };
        cx.update(self.settings, model.Settings.apply, .{patch}) catch |err| {
            self.error_value = err;
            cx.notify();
            return;
        };
        self.error_value = null;
        cx.notify();
    }
};
fn contributionButton(b: *ui.Ui, id: []const u8, icons: bool, colors: themes.Palette) !ui.Element {
    if (id.len > 256) return error.ContributionIdTooLong;
    var payload: Contribution = .{ .len = @intCast(id.len), .icons = icons };
    @memcpy(payload.id[0..id.len], id);
    return b.button(.{ .label = "Use", .on_click = try b.onClickWith(payload, View.contribution), .style = .{ .height = .{ .px = 30 }, .padding = .{ .left = 12, .right = 12, .top = 7 }, .radius = 4, .background = colors.selected, .text = .{ .size = 13, .color = colors.text } } });
}
fn categoryName(category: Category) []const u8 {
    return switch (category) {
        .appearance => "Appearance",
        .editor => "Editor",
        .version_control => "Version control",
    };
}
fn heading(b: *ui.Ui, text: []const u8, colors: themes.Palette, size: f32) !ui.Element {
    return b.styled(try b.text(text), .{ .text = .{ .size = size, .color = if (size < 14) colors.muted else colors.text } });
}
fn button(b: *ui.Ui, which: Change, label: []const u8, colors: themes.Palette) !ui.Element {
    return b.button(.{ .label = label, .on_click = try b.onClickWith(which, View.change), .style = .{ .height = .{ .px = 30 }, .min_width = .{ .px = 34 }, .padding = .{ .left = 12, .right = 12, .top = 7 }, .radius = 4, .background = colors.selected, .text = .{ .size = 13, .color = colors.text } } });
}
fn row(b: *ui.Ui, title: []const u8, help: []const u8, controls: []const ui.Element, colors: themes.Palette) !ui.Element {
    return b.column(.{ .gap = 16 }, &.{ try b.row(.{ .gap = 14, .align_items = .center }, &.{ try b.column(.{ .flex_grow = 1, .gap = 7 }, &.{ try heading(b, title, colors, 14), try heading(b, help, colors, 12) }), try b.row(.{ .gap = 6 }, controls) }), try b.div(.{ .height = .{ .px = 1 }, .background = colors.line }, &.{}) });
}
fn matches(query: []const u8, text: []const u8) bool {
    return @import("../view.zig").matches(query, text);
}
