//! Native preferences window with a full-height navigation rail, persisted
//! controls, independently filtered rows and shared editor state.
const std = @import("std");
const ui = @import("zircon_ui");
const ext = @import("zircon_extensions");
const model = @import("model.zig");
const Shell = @import("../shell.zig").Shell;
const v = @import("../views/components.zig");
const Category = enum { general, appearance, editor, version_control };
const Change = enum { font_down, font_up, tab_two, tab_four, tab_eight, dark, light, default_icons, motion, numbers, gutters };
const Picker = enum { none, theme, icons };
const Contribution = struct { id: [256]u8 = @splat(0), len: u16, icons: bool };
const Row = enum { theme, icons, font, tabs, numbers, gutters, motion };
const row_height: f32 = 88;
pub const View = struct {
    allocator: std.mem.Allocator,
    settings: ui.Entity(model.Settings),
    workspace: ?ui.Entity(Shell) = null,
    window: ?ui.WindowHandle = null,
    query: ?ui.Entity(ui.controls.TextInput) = null,
    category: Category = .general,
    scroll: ui.controls.Scroll = .{},
    picker: Picker = .none,
    picker_y: f32 = 0,
    picker_scroll: ui.controls.Scroll = .{},
    error_value: ?anyerror = null,
    pub fn bootstrap(self: *View, cx: *ui.Context(View), window: ui.WindowHandle) !void {
        self.window = window;
        var input = try ui.controls.TextInput.init(self.allocator, "");
        input.placeholder = "Search settings…";
        self.query = cx.createChild(ui.controls.TextInput, input) catch |err| {
            input.deinit(input.allocator);
            return err;
        };
        _ = try cx.observe(self.query.?, onQuery);
        cx.notify();
    }
    fn onQuery(self: *View, cx: *ui.Context(View), _: ui.Entity(ui.controls.TextInput)) void {
        self.scroll.offset = 0;
        self.picker = .none;
        cx.notify();
    }
    pub fn render(self: *const View, b: *ui.Ui) !ui.Element {
        var values: model.Values = undefined;
        try b.watch(self.settings, model.Settings.copy, .{ b.allocator(), &values });
        var generation: ?ext.Snapshot = null;
        if (self.workspace) |handle| try b.watch(handle, Shell.copyExtensions, .{&generation});
        defer if (generation) |*value| value.deinit();
        var c: v.Palette = if (std.mem.eql(u8, values.theme, "zircon.light")) v.Palette.light else .{};
        if (generation) |snapshot| if (snapshot.resolveTheme(values.theme)) |theme| {
            inline for (.{ "document", "chrome", "sidebar", "panel", "line", "text", "muted", "accent", "selected", "warning", "primary" }) |name| @field(c, name) = @import("../services/extensions.zig").color(@field(theme.colors, name));
            c.hover = c.selected;
        };
        var query: []u8 = &.{};
        if (self.query) |handle| try b.watch(handle, ui.controls.TextInput.copy, .{ b.allocator(), &query });
        var path: ?[]u8 = null;
        try b.watch(self.settings, model.Settings.copyPath, .{ b.allocator(), &path });
        var nav: std.ArrayList(ui.Element) = .empty;
        try nav.append(b.allocator(), try b.dragRegion(try b.div(.{ .height = .{ .px = 36 }, .flex_shrink = 0 }, &.{})));
        if (self.query) |handle| {
            const search = try b.styled(try b.key(.{ .string = "settings-search" }, try b.view(handle)), .{ .flex_grow = 1, .height = .{ .px = 30 }, .min_width = .{ .px = 0 } });
            try nav.append(b.allocator(), try b.row(.{ .height = .{ .px = 34 }, .flex_shrink = 0, .align_items = .center, .gap = 4, .padding = .{ .left = 8, .right = 4 }, .radius = 4, .background = c.document }, &.{ try v.icon(b, .search, c.muted, 15), try b.autofocus(search) }));
        }
        try nav.append(b.allocator(), try b.div(.{ .height = .{ .px = 7 }, .flex_shrink = 0 }, &.{}));
        inline for (std.meta.tags(Category)) |category| try nav.append(b.allocator(), try b.button(.{ .label = categoryName(category), .children = &.{ try v.icon(b, if (self.category == category) .chevron_down else .chevron_right, c.muted, 14), try v.text(b, categoryName(category), c.text, 13) }, .on_click = try b.onClickWith(category, select), .style = .{ .direction = .row, .height = .{ .px = 32 }, .flex_shrink = 0, .gap = 9, .padding = .{ .left = 8, .right = 8 }, .align_items = .center, .radius = 3, .background = if (self.category == category) c.hover else null, .hover_background = c.hover } }));
        try nav.append(b.allocator(), try b.div(.{ .flex_grow = 1 }, &.{}));
        try nav.append(b.allocator(), try v.rule(b, c));
        try nav.append(b.allocator(), try v.text(b, "Zircon settings", c.muted, 11));
        const sidebar = try b.column(.{ .width = .{ .px = 238 }, .flex_shrink = 0, .padding = .{ .left = 12, .right = 12, .bottom = 14 }, .gap = 5, .background = c.sidebar }, nav.items);
        var header_items: std.ArrayList(ui.Element) = .empty;
        try header_items.appendSlice(b.allocator(), &.{ try b.styled(try v.text(b, "User", c.accent, 13), .{ .padding = .{ .left = 7, .right = 7, .top = 4, .bottom = 4 }, .radius = 3, .background = c.hover, .text = .{ .size = 13, .color = c.accent } }), try v.text(b, "Settings", c.text, 13), try b.div(.{ .flex_grow = 1 }, &.{}) });
        if (path != null and self.workspace != null) try header_items.append(b.allocator(), try b.button(.{ .label = "Edit in settings.json", .on_click = b.onClick(editJson), .style = choiceStyle(c) }));
        const header = try b.dragRegion(try b.row(.{ .height = .{ .px = 60 }, .flex_shrink = 0, .padding = .{ .left = 32, .right = 30, .top = 13 }, .gap = 8, .align_items = .center, .background = c.document }, header_items.items));
        var rows: std.ArrayList(ui.Element) = .empty;
        const searching = std.mem.trim(u8, query, " \t").len > 0;
        try rows.append(b.allocator(), try b.styled(try v.text(b, if (searching) "Search results" else categoryName(self.category), c.text, 17), .{ .height = .{ .px = 55 }, .padding = .{ .top = 20 }, .flex_shrink = 0, .text = .{ .size = 17, .color = c.text } }));
        var row_count: usize = 0;
        inline for (std.meta.tags(Row)) |entry| {
            if ((searching or contains(self.category, entry)) and @import("../view.zig").matches(query, rowSearch(entry))) {
                try rows.append(b.allocator(), try settingRow(self, b, c, values, generation, entry));
                row_count += 1;
            }
        }
        if (row_count == 0) try rows.append(b.allocator(), try v.text(b, "No settings match your search.", c.muted, 13));
        if (self.error_value) |err| try rows.append(b.allocator(), try v.text(b, @import("../errors.zig").message(err), c.warning, 12));
        const content_height = 55 + @as(f32, @floatFromInt(row_count)) * row_height + 40;
        const list = try b.listen(try b.key(.{ .string = "settings-content" }, try b.column(.{ .flex_grow = 1, .min_height = .{ .px = 0 }, .padding = .{ .left = 32, .right = 30, .bottom = 24 }, .scroll_y = @min(self.scroll.offset, @max(0, content_height - @max(1, b.viewport().height - 60))), .overflow = .hidden }, rows.items)), .{ .on_input = try b.onInputWith(content_height, onScroll) });
        const main = try b.column(.{ .flex_grow = 1, .min_width = .{ .px = 0 }, .background = c.document, .overflow = .hidden }, &.{ header, list });
        const base = try b.row(.{ .background = c.document }, &.{ sidebar, try b.div(.{ .width = .{ .px = 1 }, .flex_shrink = 0, .background = c.line }, &.{}), main });
        var layers: std.ArrayList(ui.Element) = .empty;
        try layers.append(b.allocator(), base);
        if (self.picker != .none) try layers.append(b.allocator(), try pickerView(self, b, c, values, generation));
        return b.listen(try b.stack(.{ .background = c.document }, layers.items), .{ .on_capture = b.onInput(onGlobal) });
    }
    fn select(self: *View, _: *ui.Event(ui.Click), cx: *ui.Context(View), category: Category) void {
        self.category = category;
        self.scroll.offset = 0;
        self.picker = .none;
        cx.notify();
    }
    fn onScroll(self: *View, e: *ui.Event(ui.Input), cx: *ui.Context(View), total: f32) void {
        if (e.data != .scroll) return;
        self.scroll.wheel(e.data.scroll.y, total, e.bounds.height);
        e.preventDefault();
        cx.notify();
    }
    fn onGlobal(self: *View, e: *ui.Event(ui.Input), cx: *ui.Context(View)) !void {
        if (e.data != .key_down) return;
        if (e.data.key_down.key == .escape and self.picker != .none) {
            self.picker = .none;
            e.preventDefault();
            e.stopPropagation();
            cx.notify();
        }
        if (e.data.key_down.key == .w and e.data.key_down.modifiers.command) {
            if (self.window) |window| try cx.app.requestCloseWindow(window);
            e.preventDefault();
            e.stopPropagation();
        }
    }
    fn openPicker(self: *View, e: *ui.Event(ui.Click), cx: *ui.Context(View), picker: Picker) void {
        self.picker = picker;
        self.picker_scroll.offset = 0;
        self.picker_y = e.bounds.y + e.bounds.height + 3;
        cx.notify();
    }
    fn scrollPicker(self: *View, e: *ui.Event(ui.Input), cx: *ui.Context(View), total: f32) void {
        if (e.data != .scroll) return;
        self.picker_scroll.wheel(e.data.scroll.y, total, e.bounds.height);
        e.preventDefault();
        e.stopPropagation();
        cx.notify();
    }
    fn closePicker(self: *View, e: *ui.Event(ui.Input), cx: *ui.Context(View)) void {
        if (e.phase == .target and e.data == .pointer_down) {
            self.picker = .none;
            e.preventDefault();
            cx.notify();
        }
    }
    fn editJson(self: *View, _: *ui.Event(ui.Click), cx: *ui.Context(View)) !void {
        cx.update(self.settings, model.Settings.prepareFile, .{}) catch |err| {
            self.error_value = err;
            cx.notify();
            return;
        };
        var path: ?[]u8 = null;
        try cx.read(self.settings, model.Settings.copyPath, .{ self.allocator, &path });
        defer if (path) |owned| self.allocator.free(owned);
        const Open = struct {
            fn apply(shell: *Shell, context: *ui.Context(Shell), file: []const u8) !void {
                try shell.openPath(file);
                shell.panel = .editor;
                if (shell.window) |window| try context.app.raiseWindow(window);
                context.notify();
            }
        };
        if (self.workspace) |workspace| if (path) |file| try cx.update(workspace, Open.apply, .{file});
        if (self.window) |window| try cx.app.requestCloseWindow(window);
    }
    fn contribution(self: *View, _: *ui.Event(ui.Click), cx: *ui.Context(View), value: Contribution) !void {
        const id = value.id[0..value.len];
        try self.apply(cx, if (value.icons) .{ .icon_theme = id } else .{ .theme = id });
    }
    fn apply(self: *View, cx: *ui.Context(View), patch: model.Patch) !void {
        cx.update(self.settings, model.Settings.apply, .{patch}) catch |err| {
            self.error_value = err;
            cx.notify();
            return;
        };
        self.error_value = null;
        self.picker = .none;
        cx.notify();
    }
    fn change(self: *View, _: *ui.Event(ui.Click), cx: *ui.Context(View), which: Change) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        var values: model.Values = undefined;
        try cx.read(self.settings, model.Settings.copy, .{ arena.allocator(), &values });
        try self.apply(cx, switch (which) {
            .font_down => .{ .font_size = @max(10, values.font_size - 1) },
            .font_up => .{ .font_size = @min(32, values.font_size + 1) },
            .tab_two => .{ .tab_width = 2 },
            .tab_four => .{ .tab_width = 4 },
            .tab_eight => .{ .tab_width = 8 },
            .dark => .{ .theme = "zircon.dark" },
            .light => .{ .theme = "zircon.light" },
            .default_icons => .{ .icon_theme = "zircon.default" },
            .motion => .{ .reduced_motion = !values.reduced_motion },
            .numbers => .{ .line_numbers = !values.line_numbers },
            .gutters => .{ .git_gutters = !values.git_gutters },
        });
    }
};
fn categoryName(category: Category) []const u8 {
    return switch (category) {
        .general => "General",
        .appearance => "Appearance",
        .editor => "Editor",
        .version_control => "Version control",
    };
}
fn contains(category: Category, row: Row) bool {
    return category == .general or switch (row) {
        .theme, .icons, .motion => category == .appearance,
        .font, .tabs, .numbers => category == .editor,
        .gutters => category == .version_control,
    };
}
fn rowSearch(row: Row) []const u8 {
    return switch (row) {
        .theme => "Color theme appearance colors",
        .icons => "File icon theme appearance",
        .font => "Font size editor",
        .tabs => "Tab width size indentation editor",
        .numbers => "Line numbers editor",
        .gutters => "Git change markers gutters version control",
        .motion => "Reduced motion animations accessibility general",
    };
}
fn choiceStyle(c: v.Palette) ui.Style {
    return .{ .height = .{ .px = 28 }, .min_width = .{ .px = 32 }, .padding = .{ .left = 10, .right = 10, .top = 5 }, .radius = 3, .background = c.sidebar, .hover_background = c.hover, .text = .{ .size = 13, .color = c.text }, .flex_shrink = 0 };
}
fn changeButton(b: *ui.Ui, c: v.Palette, change: Change, label: []const u8) !ui.Element {
    return b.button(.{ .label = label, .on_click = try b.onClickWith(change, View.change), .style = choiceStyle(c) });
}
fn settingRow(self: *const View, b: *ui.Ui, c: v.Palette, values: model.Values, snapshot: ?ext.Snapshot, row: Row) !ui.Element {
    _ = self;
    const title: []const u8 = switch (row) {
        .theme => "Color theme",
        .icons => "File icon theme",
        .font => "Font size",
        .tabs => "Tab width",
        .numbers => "Line numbers",
        .gutters => "Git change markers",
        .motion => "Reduced motion",
    };
    const help: []const u8 = switch (row) {
        .theme => "Choose the colors used throughout the editor.",
        .icons => "Choose icons for files and folders in the project panel.",
        .font => "Size of text in editor panes. Applies to newly opened files.",
        .tabs => "Number of spaces per indentation stop.",
        .numbers => "Show source line numbers in the editor gutter.",
        .gutters => "Mark added, changed and deleted lines beside the source.",
        .motion => "Reduce decorative animations across the workspace.",
    };
    var controls: std.ArrayList(ui.Element) = .empty;
    switch (row) {
        .theme, .icons => {
            var name: []const u8 = if (row == .theme) (if (std.mem.eql(u8, values.theme, "zircon.light")) "One Light" else "One Dark") else "Zircon";
            if (snapshot) |generation| {
                if (row == .theme) {
                    if (generation.resolveTheme(values.theme)) |theme| name = theme.name;
                } else {
                    if (generation.resolveIconTheme(values.icon_theme)) |icons| name = icons.name;
                }
            }
            try controls.append(b.allocator(), try b.button(.{ .label = name, .children = &.{ try v.text(b, name, c.text, 13), try v.icon(b, .chevron_down, c.muted, 12) }, .on_click = try b.onClickWith(if (row == .theme) Picker.theme else Picker.icons, View.openPicker), .style = .{ .direction = .row, .height = .{ .px = 28 }, .min_width = .{ .px = 150 }, .gap = 12, .padding = .{ .left = 10, .right = 8 }, .align_items = .center, .justify_content = .space_between, .radius = 3, .background = c.sidebar, .hover_background = c.hover } }));
        },
        .font => try controls.appendSlice(b.allocator(), &.{ try changeButton(b, c, .font_down, "−"), try b.styled(try v.text(b, try std.fmt.allocPrint(b.allocator(), "{d:.0}", .{values.font_size}), c.text, 13), .{ .min_width = .{ .px = 32 }, .text = .{ .size = 13, .color = c.text } }), try changeButton(b, c, .font_up, "+") }),
        .tabs => {
            inline for (.{ .{ Change.tab_two, "2", 2 }, .{ Change.tab_four, "4", 4 }, .{ Change.tab_eight, "8", 8 } }) |choice| {
                var style = choiceStyle(c);
                if (values.tab_width == choice[2]) style.background = c.selected;
                try controls.append(b.allocator(), try b.button(.{ .label = choice[1], .on_click = try b.onClickWith(choice[0], View.change), .style = style }));
            }
        },
        .numbers, .gutters, .motion => {
            const enabled = switch (row) {
                .numbers => values.line_numbers,
                .gutters => values.git_gutters,
                else => values.reduced_motion,
            };
            const change: Change = switch (row) {
                .numbers => .numbers,
                .gutters => .gutters,
                else => .motion,
            };
            try controls.append(b.allocator(), try b.button(.{ .label = title, .children = &.{try b.custom(Switch, .{ .enabled = enabled, .colors = c }, .{ .width = .{ .px = 30 }, .height = .{ .px = 18 }, .flex_shrink = 0 })}, .on_click = try b.onClickWith(change, View.change), .style = .{ .width = .{ .px = 38 }, .height = .{ .px = 28 }, .align_items = .center, .justify_content = .center, .radius = 3, .hover_background = c.hover, .flex_shrink = 0 } }));
        },
    }
    return b.key(.{ .string = @tagName(row) }, try b.column(.{ .height = .{ .px = row_height }, .flex_shrink = 0 }, &.{ try b.row(.{ .flex_grow = 1, .gap = 18, .align_items = .center }, &.{ try b.column(.{ .flex_grow = 1, .min_width = .{ .px = 0 }, .gap = 7, .overflow = .hidden }, &.{ try v.text(b, title, c.text, 14), try v.text(b, help, c.muted, 12) }), try b.row(.{ .gap = 4, .align_items = .center, .flex_shrink = 0 }, controls.items) }), try v.rule(b, c) }));
}
fn pickerView(self: *const View, b: *ui.Ui, c: v.Palette, values: model.Values, generation: ?ext.Snapshot) !ui.Element {
    _ = values;
    var choices: std.ArrayList(ui.Element) = .empty;
    if (self.picker == .theme) try choices.appendSlice(b.allocator(), &.{ try changeButton(b, c, .dark, "One Dark"), try changeButton(b, c, .light, "One Light") }) else try choices.append(b.allocator(), try changeButton(b, c, .default_icons, "Zircon"));
    if (generation) |snapshot| for (snapshot.installed()) |entry| {
        if (!entry.enabled) continue;
        if (self.picker == .theme) {
            for (entry.themes) |theme| try choices.append(b.allocator(), try contributionButton(b, c, theme.id, theme.name, false));
        } else {
            for (entry.icon_themes) |icons| try choices.append(b.allocator(), try contributionButton(b, c, icons.id, icons.name, true));
        }
    };
    const total = @as(f32, @floatFromInt(choices.items.len)) * 32 + 10;
    const height = @min(total, 280);
    const popup = try b.listen(try b.key(.{ .string = "settings-choices" }, try b.column(.{ .width = .{ .px = 240 }, .height = .{ .px = height }, .gap = 4, .padding = ui.Insets.all(5), .radius = 4, .background = c.panel, .scroll_y = @min(self.picker_scroll.offset, @max(0, total - height)), .overflow = .hidden }, choices.items)), .{ .on_input = try b.onInputWith(total, View.scrollPicker) });
    return b.modal(try b.listen(try b.stack(.{ .align_items = .end, .padding = .{ .top = @min(self.picker_y, @max(0, b.viewport().height - height - 16)), .right = 30 } }, &.{popup}), .{ .on_input = b.onInput(View.closePicker) }));
}
fn contributionButton(b: *ui.Ui, c: v.Palette, id: []const u8, name: []const u8, icons: bool) !ui.Element {
    if (id.len > 256) return error.ContributionIdTooLong;
    var payload: Contribution = .{ .len = @intCast(id.len), .icons = icons };
    @memcpy(payload.id[0..id.len], id);
    return b.button(.{ .label = name, .on_click = try b.onClickWith(payload, View.contribution), .style = choiceStyle(c) });
}
const Switch = struct {
    enabled: bool,
    colors: v.Palette,
    pub const LayoutState = void;
    pub const PrepaintState = void;
    pub fn requestLayout(_: *Switch, cx: *ui.LayoutCx) !ui.LayoutResult(void) {
        return .{ .size = cx.available, .state = {} };
    }
    pub fn prepaint(_: *Switch, _: *ui.PrepaintCx, _: ui.Rect, _: *void) !void {}
    pub fn paint(self: *Switch, cx: *ui.PaintCx, bounds: ui.Rect, _: *void, _: *void) !void {
        try cx.painter.fillRect(.{ .bounds = bounds, .radius = 9, .color = if (self.enabled) self.colors.primary else self.colors.line });
        try cx.painter.fillRect(.{ .bounds = .{ .x = bounds.x + (if (self.enabled) @as(f32, 15) else 3), .y = bounds.y + 3, .width = 12, .height = 12 }, .radius = 6, .color = if (self.enabled) self.colors.text else self.colors.muted });
    }
};
