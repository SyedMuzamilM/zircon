//! Native preferences window with a full-height navigation rail, persisted
//! controls, independently filtered rows and shared editor state.
const std = @import("std");
const ext = @import("zircon_extensions");
const ui = @import("zircon_ui");
const commands = @import("../commands.zig");
const errors = @import("../errors.zig");
const services_extensions = @import("../services/extensions.zig");
const shell_module = @import("../shell.zig");
const theme_module = @import("../theme.zig");
const v = @import("../views/components.zig");
const field_input = @import("../views/input.zig");
const overlays = @import("../views/overlays.zig");
const model = @import("model.zig");
const Shell = shell_module.Shell;
const Category = enum {
    general,
    appearance,
    typography,
    editor,
    gutter,
    keymap,
    search,
    panels,
    project_panel,
    version_control,
    languages,
    accessibility,
};
const Change = enum {
    indent_guides,
    active_line,
    fold_controls,
    project_file_icons,
    project_folder_icons,
    width_down,
    width_up,
    spacing_down,
    spacing_up,
    tooltips,
    delay_down,
    delay_up,
    search_case_sensitive,
    search_whole_word,
    keymap_json,
    languages_manager,
    wrap,
    vim,
    lilex,
    menlo,
    monaco,
    plex,
    system,
    ui_down,
    ui_up,
    height_down,
    height_up,
    ligatures,
    font_down,
    font_up,
    tab_two,
    tab_four,
    tab_eight,
    dark,
    light,
    automatic,
    default_icons,
    motion,
    numbers,
    gutters,
    blame,
};
const Picker = enum { none, theme, icons, code_font, ui_font };
const Row = enum {
    wrap,
    vim,
    theme,
    icons,
    font_family,
    font,
    ui_font_family,
    ui_font_size,
    line_height,
    ligatures,
    tabs,
    numbers,
    gutters,
    blame,
    motion,
    indent_guides,
    active_line,
    fold_controls,
    project_file_icons,
    project_folder_icons,
    project_panel_width,
    project_entry_spacing,
    tooltips,
    tooltip_delay,
    search_case_sensitive,
    search_whole_word,
    keymap_json,
    languages_manager,
};
const row_height: f32 = 88;
pub const View = struct {
    allocator: std.mem.Allocator,
    settings: ui.Entity(model.Settings),
    font_families: []ui.typography.FontName = &.{},
    workspace: ?ui.Entity(Shell) = null,
    initial_colors: ?v.Palette = null,
    initial_follows_system: bool = false,
    window: ?ui.WindowHandle = null,
    query: ?ui.Entity(ui.controls.TextInput) = null,
    choice_query: ?ui.Entity(ui.controls.TextInput) = null,
    choice_index: usize = 0,
    category: Category = .general,
    expanded: [std.meta.tags(Category).len]bool = @splat(true),
    scroll: ui.controls.Scroll = .{},
    nav_scroll: ui.controls.Scroll = .{},
    picker: Picker = .none,
    picker_anchor: ui.Rect = .{},
    system_dark: bool = true,
    follows_system: bool = false,
    picker_scroll: ui.controls.Scroll = .{},
    error_value: ?anyerror = null,
    pub fn deinit(self: *View, _: std.mem.Allocator) void {
        self.allocator.free(self.font_families);
    }
    pub fn bootstrap(self: *View, cx: *ui.Context(View), window: ui.WindowHandle) !void {
        self.window = window;
        if ((try cx.app.window(window)).surface) |surface| {
            self.system_dark = surface.systemDark();
            self.font_families = try surface.fontFamilies(self.allocator);
        }
        var input = try ui.controls.TextInput.init(self.allocator, "");
        input.placeholder = "Search settings…";
        input.leading_icon = .search;
        self.query = cx.createChild(ui.controls.TextInput, input) catch |err| {
            input.deinit(input.allocator);
            return err;
        };
        var choice = try ui.controls.TextInput.init(self.allocator, "");
        choice.placeholder = "Search choices…";
        choice.leading_icon = .search;
        self.choice_query = try cx.createChild(ui.controls.TextInput, choice);
        _ = try cx.observe(self.choice_query.?, onChoiceQuery);
        _ = try cx.observe(self.query.?, onQuery);
        _ = try cx.observe(self.settings, onSettings);
        if (self.initial_colors) |colors| {
            self.follows_system = self.initial_follows_system;
            if ((try cx.app.window(window)).surface) |surface| {
                const dark = colors.document.r * 0.2126 + colors.document.g * 0.7152 + colors.document.b * 0.0722 < 0.5;
                surface.setAppearance(if (self.follows_system) null else dark);
            }
            const appearance = v.inputAppearance(colors);
            try cx.update(self.query.?, ui.controls.TextInput.setAppearance, .{appearance});
            try cx.update(self.choice_query.?, ui.controls.TextInput.setAppearance, .{appearance});
            self.initial_colors = null;
        } else try self.onSettings(cx, self.settings);
        cx.notify();
    }
    fn onSettings(self: *View, cx: *ui.Context(View), settings: ui.Entity(model.Settings)) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        var values: model.Values = undefined;
        try cx.read(settings, model.Settings.copy, .{ arena.allocator(), &values });
        var snapshot: ?ext.Snapshot = null;
        if (self.workspace) |workspace| try cx.read(workspace, Shell.copyExtensions, .{&snapshot});
        defer if (snapshot) |*value| value.deinit();
        const follows = std.mem.eql(u8, values.theme, "zircon.system");
        if (self.window) |handle| if ((try cx.app.window(handle)).surface) |surface| {
            if (follows and !self.follows_system) self.system_dark = surface.systemDark();
            const background = palette(values, snapshot, self.system_dark).document;
            const dark = background.r * 0.2126 + background.g * 0.7152 + background.b * 0.0722 < 0.5;
            surface.setAppearance(if (follows) null else dark);
        };
        self.follows_system = follows;
        if (self.query) |query| try cx.update(query, ui.controls.TextInput.setAppearance, .{v.inputAppearance(palette(values, snapshot, self.system_dark))});
        if (self.choice_query) |query| try cx.update(query, ui.controls.TextInput.setAppearance, .{v.inputAppearance(palette(values, snapshot, self.system_dark))});
        cx.notify();
    }
    fn onChoiceQuery(self: *View, cx: *ui.Context(View), _: ui.Entity(ui.controls.TextInput)) void {
        self.choice_index = 0;
        self.picker_scroll.offset = 0;
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
        const c = palette(values, generation, self.system_dark);
        b.frame.tooltips_enabled = values.tooltips;
        b.frame.tooltip_delay = values.tooltip_delay / 1000;
        var query: []u8 = &.{};
        if (self.query) |handle| try b.watch(handle, ui.controls.TextInput.copy, .{ b.allocator(), &query });
        var path: ?[]u8 = null;
        try b.watch(self.settings, model.Settings.copyPath, .{ b.allocator(), &path });
        var nav: std.ArrayList(ui.Element) = .empty;
        try nav.append(b.allocator(), try b.fluent().div()
            .h(.{ .px = 36 })
            .shrink_0()
            .children(.{})
            .drag_region()
            .build());
        if (self.query) |handle| {
            const search = try b.fluent().view(handle).id(.{ .string = "settings-search" }).style(.{
                .height = .{ .px = 30 },
                .flex_shrink = 0,
                .min_width = .{ .px = 0 },
            }).build();
            try nav.append(b.allocator(), try b.fluent().adopt(search).autofocus().build());
        }
        try nav.append(b.allocator(), try b.fluent().div().h(.{ .px = 7 }).shrink_0().children(.{}).build());
        var sections: std.ArrayList(ui.Element) = .empty;
        inline for (std.meta.tags(Category)) |category| {
            const parent = parentCategory(category);
            if (parent == null or self.expanded[@backingInt(parent.?)]) {
                const has_children = category == .appearance or category == .editor or category == .panels;
                try sections.append(b.allocator(), try b.fluent().button(.{
                    .label = categoryName(category),
                })
                    .flex()
                    .h(.{ .px = 30 })
                    .shrink_0()
                    .gap_px(6)
                    .padding(.{ .left = if (parent != null) 22 else 6, .right = 6 })
                    .items_center()
                    .rounded_px(v.metrics.control_radius)
                    .background(if (self.category == category) c.selected else null)
                    .hover_background(c.hover)
                    .on_click(b.onClickWith(select, category))
                    .children(&.{
                        if (has_children) try v.icon(b, if (self.expanded[@backingInt(category)]) .chevron_down else .chevron_right, c.muted, 14) else try b.fluent().div()
                            .w(.{ .px = 14 })
                            .shrink_0()
                            .children(.{})
                            .build(),
                        try v.text(b, categoryName(category), c.text, 13),
                    }).build());
            }
        }
        const nav_height = @as(f32, @floatFromInt(sections.items.len)) * 33;
        try nav.append(b.allocator(), try b.fluent().div()
            .grow()
            .min_h(.{ .px = 0 })
            .gap_px(3)
            .scroll_y_px(@min(self.nav_scroll.offset, @max(0, nav_height - @max(0, b.viewport().height - 140))))
            .overflow_hidden()
            .flex_col()
            .children(sections.items)
            .listeners(.{ .on_input = b.onInputWith(scrollNav, nav_height) })
            .build());
        try nav.append(b.allocator(), try v.rule(b, c));
        try nav.append(b.allocator(), try v.text(b, "Zircon settings", c.muted, 11));
        const sidebar = try b.fluent().div()
            .w(.{ .px = 238 })
            .shrink_0()
            .padding(.{ .left = 12, .right = 12, .bottom = 14 })
            .gap_px(5)
            .background(c.sidebar)
            .flex_col()
            .children(nav.items)
            .build();
        var header_items: std.ArrayList(ui.Element) = .empty;
        try header_items.appendSlice(b.allocator(), &.{ try b.fluent().adopt(try v.text(b, "User", c.accent, 13))
            .style(.{
                .padding = .{ .left = 7, .right = 7, .top = 4, .bottom = 4 },
                .radius = v.metrics.control_radius,
                .background = c.hover,
                .text = .{ .size = 13, .color = c.accent },
            })
            .build(), try v.text(b, "Settings", c.text, 13), try b.fluent().div()
            .grow()
            .children(.{})
            .build() });
        if (path != null and self.workspace != null) try header_items.append(b.allocator(), try b.fluent().button(.{
            .label = "Edit in settings.json",
        }).style(choiceStyle(c)).on_click(b.onClick(editJson)).build());
        const header = try b.fluent().div()
            .h(.{ .px = 60 })
            .shrink_0()
            .padding(.{ .left = 32, .right = 30, .top = 13 })
            .gap_px(8)
            .items_center()
            .background(c.document)
            .flex()
            .children(header_items.items)
            .drag_region()
            .build();
        var rows: std.ArrayList(ui.Element) = .empty;
        const searching = std.mem.trim(u8, query, " \t").len > 0;
        try rows.append(b.allocator(), try b.fluent().adopt(try v.text(b, if (searching) "Search results" else categoryName(self.category), c.text, 17))
            .style(.{
                .height = .{ .px = 55 },
                .padding = .{ .top = 20 },
                .flex_shrink = 0,
                .text = .{ .size = 17, .color = c.text },
            }).build());
        var row_count: usize = 0;
        inline for (std.meta.tags(Row)) |entry| {
            if ((searching or contains(self.category, entry)) and overlays.matches(query, rowSearch(entry))) {
                try rows.append(b.allocator(), try settingRow(self, b, c, values, generation, entry));
                row_count += 1;
            }
        }
        if (row_count == 0) try rows.append(b.allocator(), try v.text(b, "No settings match your search.", c.muted, 13));
        if (self.error_value) |err| try rows.append(b.allocator(), try v.text(b, errors.message(err), c.warning, 12));
        const content_height = 55 + @as(f32, @floatFromInt(row_count)) * row_height + 40;
        const list = try b.fluent().div()
            .grow()
            .min_h(.{ .px = 0 })
            .padding(.{ .left = 32, .right = 30, .bottom = 24 })
            .scroll_y_px(@min(self.scroll.offset, @max(0, content_height - @max(1, b.viewport().height - 60))))
            .overflow_hidden()
            .flex_col()
            .children(rows.items)
            .id(.{ .string = "settings-content" })
            .listeners(.{ .on_input = b.onInputWith(onScroll, content_height) })
            .build();
        const main = try b.fluent().div()
            .grow()
            .min_w(.{ .px = 0 })
            .background(c.document)
            .overflow_hidden()
            .flex_col()
            .children(.{ header, list })
            .build();
        const base = try b.fluent().div().background(c.document).flex().children(&.{
            sidebar,
            try b.fluent().div().w(.{ .px = 1 }).shrink_0().background(c.line).children(.{}).build(),
            main,
        }).build();
        var layers: std.ArrayList(ui.Element) = .empty;
        try layers.append(b.allocator(), base);
        if (self.picker != .none) try layers.append(b.allocator(), try pickerView(self, b, c, values, generation));
        return b.fluent().div()
            .background(c.document)
            .stack()
            .children(layers.items)
            .listeners(.{ .on_capture = b.onInput(onGlobal) })
            .build();
    }
    fn select(self: *View, _: *ui.Event(ui.Click), cx: *ui.Context(View), category: Category) void {
        if (category == .appearance or category == .editor or category == .panels) self.expanded[@backingInt(category)] = !self.expanded[@backingInt(category)];
        self.category = category;
        self.scroll.offset = 0;
        self.picker = .none;
        cx.notify();
    }
    fn scrollNav(self: *View, e: *ui.Event(ui.Input), cx: *ui.Context(View), total: f32) void {
        if (e.data != .scroll) return;
        self.nav_scroll.wheel(e.data.scroll.y, total, e.bounds.height);
        e.preventDefault();
        e.stopPropagation();
        cx.notify();
    }
    fn onScroll(self: *View, e: *ui.Event(ui.Input), cx: *ui.Context(View), total: f32) void {
        if (e.data != .scroll) return;
        self.scroll.wheel(e.data.scroll.y, total, e.bounds.height);
        e.preventDefault();
        cx.notify();
    }
    fn onGlobal(self: *View, e: *ui.Event(ui.Input), cx: *ui.Context(View)) !void {
        if (e.data == .appearance) {
            if (self.system_dark == e.data.appearance) return;
            self.system_dark = e.data.appearance;
            try self.onSettings(cx, self.settings);
            return;
        }
        if (e.data != .key_down) return;
        if (self.picker != .none and (e.data.key_down.key == .up or e.data.key_down.key == .down or e.data.key_down.key == .enter)) {
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            var query: []u8 = &.{};
            if (self.choice_query) |handle| try cx.read(handle, ui.controls.TextInput.copy, .{ arena.allocator(), &query });
            var generation: ?ext.Snapshot = null;
            if (self.workspace) |workspace| try cx.read(workspace, Shell.copyExtensions, .{&generation});
            defer if (generation) |*snapshot| snapshot.deinit();
            const choices = try choiceList(arena.allocator(), self.picker, generation, query, self.font_families);
            if (choices.len > 0) {
                if (e.data.key_down.key == .enter) try self.apply(cx, choices[@min(self.choice_index, choices.len - 1)].patch) else {
                    self.choice_index = if (e.data.key_down.key == .down) (self.choice_index + 1) % choices.len else (self.choice_index + choices.len - 1) % choices.len;
                    self.picker_scroll.reveal(@as(f32, @floatFromInt(self.choice_index)) * 32, @as(f32, @floatFromInt(self.choice_index + 1)) * 32, @as(f32, @floatFromInt(choices.len)) * 32, 224);
                }
            }
            e.preventDefault();
            e.stopPropagation();
            cx.notify();
            return;
        }
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
    fn openPicker(self: *View, e: *ui.Event(ui.Click), cx: *ui.Context(View), picker: Picker) !void {
        if (self.choice_query) |query| try cx.update(query, resetChoice, .{});
        self.choice_index = 0;
        self.picker = picker;
        self.picker_scroll.offset = 0;
        self.picker_anchor = e.bounds;
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
        if (which == .keymap_json) {
            var e: ui.Event(ui.Click) = .{ .data = .{} };
            return self.editJson(&e, cx);
        }
        if (which == .languages_manager) {
            const Open = struct {
                fn call(shell: *Shell, context: *ui.Context(Shell), command: commands.Command) !void {
                    var e: ui.Event(ui.Click) = .{ .data = .{} };
                    try shell.onCommand(&e, context, command);
                    if (shell.window) |window| try context.app.raiseWindow(window);
                }
            };
            if (self.workspace) |workspace| try cx.update(workspace, Open.call, .{commands.Command.extensions});
            if (self.window) |window| try cx.app.requestCloseWindow(window);
            return;
        }
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        var values: model.Values = undefined;
        try cx.read(self.settings, model.Settings.copy, .{ arena.allocator(), &values });
        try self.apply(cx, switch (which) {
            .indent_guides => .{ .indent_guides = !values.indent_guides },
            .active_line => .{ .active_line = !values.active_line },
            .fold_controls => .{ .fold_controls = !values.fold_controls },
            .project_file_icons => .{ .project_file_icons = !values.project_file_icons },
            .project_folder_icons => .{ .project_folder_icons = !values.project_folder_icons },
            .width_down => .{ .project_panel_width = @max(120, values.project_panel_width - 20) },
            .width_up => .{ .project_panel_width = @min(700, values.project_panel_width + 20) },
            .spacing_down => .{ .project_entry_spacing = @max(20, values.project_entry_spacing - 2) },
            .spacing_up => .{ .project_entry_spacing = @min(36, values.project_entry_spacing + 2) },
            .tooltips => .{ .tooltips = !values.tooltips },
            .delay_down => .{ .tooltip_delay = @max(0, values.tooltip_delay - 100) },
            .delay_up => .{ .tooltip_delay = @min(2000, values.tooltip_delay + 100) },
            .search_case_sensitive => .{ .search_case_sensitive = !values.search_case_sensitive },
            .search_whole_word => .{ .search_whole_word = !values.search_whole_word },
            .keymap_json, .languages_manager => unreachable,
            .wrap => .{ .soft_wrap = if (values.soft_wrap == .none) .editor_width else .none },
            .vim => .{ .vim_mode = !values.vim_mode },
            .lilex => .{ .font_family = .lilex },
            .menlo => .{ .font_family = .menlo },
            .monaco => .{ .font_family = .monaco },
            .plex => .{ .ui_font_family = .plex },
            .system => .{ .ui_font_family = .system },
            .ui_down => .{ .ui_font_size = @max(10, values.ui_font_size - 1) },
            .ui_up => .{ .ui_font_size = @min(20, values.ui_font_size + 1) },
            .height_down => .{ .line_height = @max(1, values.line_height - 0.1) },
            .height_up => .{ .line_height = @min(2.4, values.line_height + 0.1) },
            .ligatures => .{ .font_ligatures = !values.font_ligatures },
            .font_down => .{ .font_size = @max(10, values.font_size - 1) },
            .font_up => .{ .font_size = @min(32, values.font_size + 1) },
            .tab_two => .{ .tab_width = 2 },
            .tab_four => .{ .tab_width = 4 },
            .tab_eight => .{ .tab_width = 8 },
            .automatic => .{ .theme = "zircon.system" },
            .dark => .{ .theme = "zircon.dark" },
            .light => .{ .theme = "zircon.light" },
            .default_icons => .{ .icon_theme = "zircon.default" },
            .motion => .{ .reduced_motion = !values.reduced_motion },
            .numbers => .{ .line_numbers = !values.line_numbers },
            .gutters => .{ .git_gutters = !values.git_gutters },
            .blame => .{ .git_inline_blame = !values.git_inline_blame },
        });
    }
};
fn categoryName(category: Category) []const u8 {
    return switch (category) {
        .general => "General",
        .appearance => "Appearance",
        .editor => "Editor",
        .version_control => "Git panel",
        .typography => "Typography",
        .gutter => "Gutter and folding",
        .keymap => "Keymap",
        .search => "Search and files",
        .panels => "Panels",
        .project_panel => "Project panel",
        .languages => "Languages and tools",
        .accessibility => "Accessibility",
    };
}

fn parentCategory(category: Category) ?Category {
    return switch (category) {
        .typography => .appearance,
        .gutter => .editor,
        .project_panel, .version_control => .panels,
        else => null,
    };
}

fn contains(category: Category, row: Row) bool {
    if (category == .general) return true;
    return switch (row) {
        .theme, .icons => category == .appearance,
        .font_family, .font, .ui_font_family, .ui_font_size, .line_height, .ligatures => category == .appearance or category == .typography or category == .editor,
        .wrap, .tabs => category == .editor,
        .vim, .keymap_json => category == .keymap or category == .editor,
        .numbers, .indent_guides, .active_line, .fold_controls => category == .editor or category == .gutter,
        .gutters, .blame => category == .version_control or category == .gutter or category == .panels,
        .motion, .tooltips, .tooltip_delay => category == .accessibility,
        .project_file_icons, .project_folder_icons, .project_panel_width, .project_entry_spacing => category == .project_panel or category == .panels,
        .search_case_sensitive, .search_whole_word => category == .search,
        .languages_manager => category == .languages,
    };
}

fn rowSearch(row: Row) []const u8 {
    return switch (row) {
        .theme => "Color theme appearance colors",
        .icons => "File icon theme appearance",
        .vim => "Vim modal editing normal visual insert key bindings",
        .font_family => "Editor font family Lilex Menlo Monaco typography",
        .ui_font_family => "Interface font family IBM Plex Sans System typography",
        .ui_font_size => "Interface font size typography",
        .line_height => "Line height spacing editor typography",
        .ligatures => "Font ligatures editor typography",
        .font => "Font size editor",
        .tabs => "Tab width size indentation editor",
        .wrap => "Word text soft wrapping editor width",
        .numbers => "Line numbers editor",
        .gutters => "Git change markers gutters version control",
        .blame => "Git inline blame author version control",
        .motion => "Reduced motion animations accessibility general",
        .indent_guides => "Indent guides editor gutter",
        .active_line => "Highlight active line editor gutter",
        .fold_controls => "Code folding controls gutter collapse",
        .project_file_icons => "File icons project panel",
        .project_folder_icons => "Folder icons project panel",
        .project_panel_width => "Project panel default width sidebar",
        .project_entry_spacing => "Project entry spacing density sidebar",
        .tooltips => "Icon hover tooltips accessibility",
        .tooltip_delay => "Tooltip delay hover accessibility",
        .search_case_sensitive => "Default match case search",
        .search_whole_word => "Default whole word search",
        .keymap_json => "Keyboard shortcuts keymap settings JSON",
        .languages_manager => "Language servers extensions tools",
    };
}

fn choiceStyle(c: v.Palette) ui.Style {
    var style = v.buttonStyle(c, false);
    style.min_width = .{ .px = 32 };
    return style;
}

fn changeButton(b: *ui.Ui, c: v.Palette, change: Change, label: []const u8) !ui.Element {
    return b.fluent().button(.{
        .label = label,
    }).style(choiceStyle(c)).on_click(b.onClickWith(View.change, change)).children(&.{
        try v.text(b, if (change == .ui_down or change == .height_down) "−" else if (change == .ui_up or change == .height_up) "+" else label, c.text, 13),
    }).build();
}

fn settingRow(self: *const View, b: *ui.Ui, c: v.Palette, values: model.Values, snapshot: ?ext.Snapshot, row: Row) !ui.Element {
    _ = self;
    const title: []const u8 = switch (row) {
        .theme => "Color theme",
        .icons => "File icon theme",
        .vim => "Vim mode",
        .font_family => "Editor font",
        .ui_font_family => "Interface font",
        .ui_font_size => "Interface font size",
        .line_height => "Line height",
        .ligatures => "Font ligatures",
        .font => "Font size",
        .tabs => "Tab width",
        .wrap => "Word wrap",
        .numbers => "Line numbers",
        .gutters => "Git change markers",
        .blame => "Inline Git blame",
        .motion => "Reduced motion",
        .indent_guides => "Indent guides",
        .active_line => "Highlight active line",
        .fold_controls => "Folding controls",
        .project_file_icons => "File icons",
        .project_folder_icons => "Folder icons",
        .project_panel_width => "Project panel default width",
        .project_entry_spacing => "Entry spacing",
        .tooltips => "Icon tooltips",
        .tooltip_delay => "Tooltip delay",
        .search_case_sensitive => "Default match case",
        .search_whole_word => "Default whole word",
        .keymap_json => "Keyboard shortcuts",
        .languages_manager => "Language support",
    };
    const help: []const u8 = switch (row) {
        .wrap => "Wrap long lines at the editor width without changing the file.",
        .theme => "Choose the colors used throughout the editor.",
        .icons => "Choose icons for files and folders in the project panel.",
        .vim => "Normal, Insert and Visual modes. Escape returns to Normal.",
        .font_family => "Choose a bundled or installed font family.",
        .ui_font_family => "Typeface used in tabs, sidebars, controls and settings.",
        .ui_font_size => "Scale interface text independently from editor text.",
        .line_height => "Vertical space per line, as a multiple of the font size.",
        .ligatures => "Combine supported programming symbols into ligatures.",
        .font => "Size of text in editor panes and newly opened files.",
        .tabs => "Number of spaces per indentation stop.",
        .numbers => "Show source line numbers in the editor gutter.",
        .gutters => "Mark added, changed and deleted lines beside the source.",
        .blame => "Show the author of the current line after a short delay.",
        .motion => "Reduce decorative animations across the workspace.",
        .indent_guides => "Show vertical guides at indentation stops.",
        .active_line => "Tint the focused editor's current line.",
        .fold_controls => "Show disclosure arrows beside line numbers on hover.",
        .project_file_icons => "Use the selected icon theme for project files.",
        .project_folder_icons => "Show folder icons beside disclosure arrows.",
        .project_panel_width => "Default width of the project sidebar in pixels.",
        .project_entry_spacing => "Height of file and folder rows in pixels.",
        .tooltips => "Explain icon actions when the pointer pauses over them.",
        .tooltip_delay => "Delay before a tooltip appears, in milliseconds.",
        .search_case_sensitive => "Start buffer searches with case-sensitive matching.",
        .search_whole_word => "Start buffer searches by matching complete words.",
        .keymap_json => "Configure command shortcuts and Vim mappings in settings.json.",
        .languages_manager => "Install language grammars and servers from Extensions.",
    };
    var controls: std.ArrayList(ui.Element) = .empty;
    switch (row) {
        .project_panel_width, .project_entry_spacing, .tooltip_delay => {
            const n = switch (row) {
                .project_panel_width => values.project_panel_width,
                .project_entry_spacing => values.project_entry_spacing,
                else => values.tooltip_delay,
            };
            const down: Change = switch (row) {
                .project_panel_width => .width_down,
                .project_entry_spacing => .spacing_down,
                else => .delay_down,
            };
            const up: Change = switch (row) {
                .project_panel_width => .width_up,
                .project_entry_spacing => .spacing_up,
                else => .delay_up,
            };
            try controls.appendSlice(b.allocator(), &.{ try changeButton(b, c, down, "−"), try v.text(b, try std.fmt.allocPrint(b.allocator(), "{d:.0}", .{n}), c.text, 13), try changeButton(b, c, up, "+") });
        },
        .keymap_json, .languages_manager => try controls.append(b.allocator(), try changeButton(b, c, switch (row) {
            .keymap_json => .keymap_json,
            .languages_manager => .languages_manager,
            else => unreachable,
        }, switch (row) {
            .keymap_json => "Edit shortcuts…",
            .languages_manager => "Open extensions",
            else => unreachable,
        })),
        .theme, .icons => {
            var name: []const u8 = if (row == .theme) (if (std.mem.eql(u8, values.theme, "zircon.system")) "System" else if (std.mem.eql(u8, values.theme, "zircon.light")) "One Light" else "One Dark") else "Zircon icons";
            if (snapshot) |generation| {
                if (row == .theme) {
                    if (generation.resolveTheme(values.theme)) |theme| name = theme.name;
                } else {
                    if (generation.resolveIconTheme(values.icon_theme)) |icons| name = icons.name;
                }
            }
            try controls.append(b.allocator(), try b.fluent().button(.{
                .label = name,
            })
                .flex()
                .h(.{ .px = 28 })
                .min_w(.{ .px = 150 })
                .gap_px(12)
                .padding(.{ .left = 10, .right = 8 })
                .items_center()
                .justify_between()
                .rounded_px(v.metrics.control_radius)
                .background(c.sidebar)
                .hover_background(c.hover)
                .on_click(b.onClickWith(View.openPicker, if (row == .theme) Picker.theme else Picker.icons))
                .children(&.{
                    try v.text(b, name, c.text, 13),
                    try v.icon(b, .chevron_down, c.muted, 12),
                }).build());
        },
        .font_family, .ui_font_family => {
            const name: []const u8 = if (row == .font_family and values.editor_font_name.len > 0) values.editor_font_name.slice() else if (row == .ui_font_family and values.interface_font_name.len > 0) values.interface_font_name.slice() else if (row == .font_family) switch (values.font_family) {
                .lilex => "Lilex",
                .menlo => "Menlo",
                .monaco => "Monaco",
            } else switch (values.ui_font_family) {
                .plex => "IBM Plex Sans",
                .system => "System",
            };
            try controls.append(b.allocator(), try b.fluent().button(.{
                .label = name,
            })
                .flex()
                .h(.{ .px = 28 })
                .min_w(.{ .px = 150 })
                .gap_px(12)
                .padding(.{ .left = 8, .right = 8 })
                .items_center()
                .justify_between()
                .background(c.element)
                .hover_background(c.hover)
                .rounded_px(v.metrics.control_radius)
                .on_click(b.onClickWith(View.openPicker, if (row == .font_family) Picker.code_font else Picker.ui_font))
                .children(&.{
                    try v.text(b, name, c.text, 13),
                    try v.icon(b, .chevron_down, c.muted, 12),
                }).build());
        },
        .ui_font_size, .line_height => {
            const is_ui = row == .ui_font_size;
            const number = if (is_ui) try std.fmt.allocPrint(b.allocator(), "{d:.0}", .{values.ui_font_size}) else try std.fmt.allocPrint(b.allocator(), "{d:.1}", .{values.line_height});
            try controls.appendSlice(b.allocator(), &.{ try changeButton(b, c, if (is_ui) .ui_down else .height_down, if (is_ui) "Decrease interface font size" else "Decrease line height"), try v.text(b, number, c.text, 13), try changeButton(b, c, if (is_ui) .ui_up else .height_up, if (is_ui) "Increase interface font size" else "Increase line height") });
        },
        .font => try controls.appendSlice(b.allocator(), &.{ try changeButton(b, c, .font_down, "−"), try b.fluent().adopt(try v.text(b, try std.fmt.allocPrint(b.allocator(), "{d:.0}", .{values.font_size}), c.text, 13))
            .style(.{
                .min_width = .{ .px = 32 },
                .text = .{ .size = 13, .color = c.text },
            }).build(), try changeButton(b, c, .font_up, "+") }),
        .tabs => {
            inline for (.{ .{ Change.tab_two, "2", 2 }, .{ Change.tab_four, "4", 4 }, .{ Change.tab_eight, "8", 8 } }) |choice| {
                var style = choiceStyle(c);
                if (values.tab_width == choice[2]) style.background = c.selected;
                try controls.append(b.allocator(), try b.fluent().button(.{
                    .label = choice[1],
                }).style(style).on_click(b.onClickWith(View.change, choice[0])).build());
            }
        },
        .wrap, .vim, .numbers, .gutters, .blame, .motion, .ligatures, .indent_guides, .active_line, .fold_controls, .project_file_icons, .project_folder_icons, .tooltips, .search_case_sensitive, .search_whole_word => {
            const enabled = switch (row) {
                .indent_guides => values.indent_guides,
                .active_line => values.active_line,
                .fold_controls => values.fold_controls,
                .project_file_icons => values.project_file_icons,
                .project_folder_icons => values.project_folder_icons,
                .tooltips => values.tooltips,
                .search_case_sensitive => values.search_case_sensitive,
                .search_whole_word => values.search_whole_word,
                .vim => values.vim_mode,
                .ligatures => values.font_ligatures,
                .wrap => values.soft_wrap != .none,
                .numbers => values.line_numbers,
                .gutters => values.git_gutters,
                .blame => values.git_inline_blame,
                else => values.reduced_motion,
            };
            const change: Change = switch (row) {
                .indent_guides => .indent_guides,
                .active_line => .active_line,
                .fold_controls => .fold_controls,
                .project_file_icons => .project_file_icons,
                .project_folder_icons => .project_folder_icons,
                .tooltips => .tooltips,
                .search_case_sensitive => .search_case_sensitive,
                .search_whole_word => .search_whole_word,
                .wrap => .wrap,
                .vim => .vim,
                .ligatures => .ligatures,
                .numbers => .numbers,
                .gutters => .gutters,
                .blame => .blame,
                else => .motion,
            };
            try controls.append(b.allocator(), try b.fluent().button(.{
                .label = title,
            })
                .w(.{ .px = 38 })
                .h(.{ .px = 28 })
                .items_center()
                .justify_center()
                .rounded_px(v.metrics.control_radius)
                .hover_background(c.hover)
                .shrink_0()
                .on_click(b.onClickWith(View.change, change))
                .children(&.{
                    try b.custom(Switch, .{ .enabled = enabled, .colors = c }, .{ .width = .{ .px = 30 }, .height = .{ .px = 18 }, .flex_shrink = 0 }),
                }).build());
        },
    }
    return b.fluent().div().h(.{ .px = row_height }).shrink_0().flex_col().children(&.{
        try b.fluent().div().grow().gap_px(18).items_center().flex().children(&.{
            try b.fluent().div()
                .grow()
                .min_w(.{ .px = 0 })
                .gap_px(7)
                .overflow_hidden()
                .flex_col()
                .children(.{ v.text(b, title, c.text, 14), v.text(b, help, c.muted, 12) })
                .build(),
            try b.fluent().div().gap_px(4).items_center().shrink_0().flex().children(controls.items).build(),
        }).build(),
        try v.rule(b, c),
    }).id(.{ .string = @tagName(row) }).build();
}

fn resetChoice(input: *ui.controls.TextInput, cx: *ui.Context(ui.controls.TextInput)) void {
    input.bytes.clearRetainingCapacity();
    input.cursor = 0;
    input.anchor = 0;
    input.marked = null;
    input.revision +%= 1;
    cx.notify();
}
const Choice = struct { name: []const u8, patch: model.Patch };
fn choiceList(a: std.mem.Allocator, picker: Picker, generation: ?ext.Snapshot, query: []const u8, families: []const ui.typography.FontName) ![]const Choice {
    var choices: std.ArrayList(Choice) = .empty;
    const fixed: []const Choice = switch (picker) {
        .theme => &.{ .{ .name = "System", .patch = .{ .theme = "zircon.system" } }, .{ .name = "One Dark", .patch = .{ .theme = "zircon.dark" } }, .{ .name = "One Light", .patch = .{ .theme = "zircon.light" } } },
        .icons => &.{.{ .name = "Zircon icons", .patch = .{ .icon_theme = "zircon.default" } }},
        .code_font => &.{ .{ .name = "Lilex", .patch = .{ .font_family = .lilex } }, .{ .name = "Menlo", .patch = .{ .font_family = .menlo } }, .{ .name = "Monaco", .patch = .{ .font_family = .monaco } } },
        .ui_font => &.{ .{ .name = "IBM Plex Sans", .patch = .{ .ui_font_family = .plex } }, .{ .name = "System", .patch = .{ .ui_font_family = .system } } },
        .none => &.{},
    };
    for (fixed) |choice| if (overlays.matches(query, choice.name)) try choices.append(a, choice);
    if (picker == .code_font or picker == .ui_font) for (families) |family| {
        const name = family.slice();
        var duplicate = false;
        for (fixed) |choice| if (std.ascii.eqlIgnoreCase(choice.name, name)) {
            duplicate = true;
            break;
        };
        if (!duplicate and overlays.matches(query, name)) try choices.append(a, .{ .name = try a.dupe(u8, name), .patch = if (picker == .code_font) .{ .editor_font_name = family } else .{ .interface_font_name = family } });
    };
    if (generation) |snapshot| for (snapshot.installed()) |entry| {
        if (!entry.enabled) continue;
        if (picker == .theme) {
            for (entry.themes) |theme| {
                if (overlays.matches(query, theme.name)) try choices.append(a, .{ .name = theme.name, .patch = .{ .theme = theme.id } });
            }
        } else if (picker == .icons) {
            for (entry.icon_themes) |icons| {
                if (overlays.matches(query, icons.name)) try choices.append(a, .{ .name = icons.name, .patch = .{ .icon_theme = icons.id } });
            }
        }
    };
    return choices.toOwnedSlice(a);
}

fn selectedChoice(values: model.Values, patch: model.Patch) bool {
    return switch (patch) {
        .theme => |id| std.mem.eql(u8, id, values.theme),
        .icon_theme => |id| std.mem.eql(u8, id, values.icon_theme),
        .font_family => |f| values.editor_font_name.len == 0 and f == values.font_family,
        .ui_font_family => |f| values.interface_font_name.len == 0 and f == values.ui_font_family,
        .editor_font_name => |f| std.meta.eql(f, values.editor_font_name),
        .interface_font_name => |f| std.meta.eql(f, values.interface_font_name),
        else => false,
    };
}
const ChoiceTarget = struct { index: u32, picker: Picker };
fn choose(self: *View, _: *ui.Event(ui.Click), cx: *ui.Context(View), target: ChoiceTarget) !void {
    if (self.picker != target.picker) return;
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    var query: []u8 = &.{};
    if (self.choice_query) |handle| try cx.read(handle, ui.controls.TextInput.copy, .{ arena.allocator(), &query });
    var generation: ?ext.Snapshot = null;
    if (self.workspace) |workspace| try cx.read(workspace, Shell.copyExtensions, .{&generation});
    defer if (generation) |*snapshot| snapshot.deinit();
    const choices = try choiceList(arena.allocator(), self.picker, generation, query, self.font_families);
    if (target.index < choices.len) try self.apply(cx, choices[target.index].patch);
}

fn pickerView(self: *const View, b: *ui.Ui, c: v.Palette, values: model.Values, generation: ?ext.Snapshot) !ui.Element {
    const query = if (self.choice_query) |handle| try field_input.text(b, handle) else "";
    const choices = try choiceList(b.allocator(), self.picker, generation, query, self.font_families);
    const total = @as(f32, @floatFromInt(@max(1, choices.len))) * 32;
    const height = @min(total, @max(32, @min(224, b.viewport().height - 78)));
    const offset = @min(self.picker_scroll.offset, @max(0, total - height));
    const visible = try ui.controls.visibleRows(choices.len, 32, offset, height, 1);
    var rows: std.ArrayList(ui.Element) = .empty;
    if (visible.start > 0) try rows.append(b.allocator(), try b.fluent().div()
        .h(.{ .px = @as(f32, @floatFromInt(visible.start)) * 32 })
        .shrink_0()
        .children(.{})
        .build());
    for (choices[visible.start..visible.end], visible.start..) |choice, i| {
        const current = selectedChoice(values, choice.patch);
        var style = v.buttonStyle(c, false);
        style.height = .{ .px = 32 };
        style.justify_content = .start;
        style.background = if (i == self.choice_index) c.selected else null;
        try rows.append(b.allocator(), try b.fluent().button(.{
            .label = choice.name,
        })
            .style(style)
            .on_click(b.onClickWith(choose, ChoiceTarget{ .index = @intCast(i), .picker = self.picker }))
            .children(&.{
                try b.fluent().div()
                    .w(.{ .px = 16 })
                    .shrink_0()
                    .justify_center()
                    .children(if (current) &.{try v.icon(b, .check, c.accent, 14)} else &.{})
                    .build(),
                try v.text(b, choice.name, c.text, 13),
            }).build());
    }
    if (visible.end < choices.len) try rows.append(b.allocator(), try b.fluent().div()
        .h(.{ .px = @as(f32, @floatFromInt(choices.len - visible.end)) * 32 })
        .shrink_0()
        .children(.{})
        .build());
    if (choices.len == 0) try rows.append(b.allocator(), try v.text(b, "No matching choices", c.muted, 12));
    const list = try b.fluent().div()
        .h(.{ .px = height })
        .min_h(.{ .px = 0 })
        .scroll_y_px(offset)
        .overflow_hidden()
        .flex_col()
        .children(rows.items)
        .listeners(.{ .on_input = b.onInputWith(View.scrollPicker, total) })
        .build();
    var children: std.ArrayList(ui.Element) = .empty;
    if (self.choice_query) |handle| try children.append(b.allocator(), try b.fluent().view(handle)
        .id(.{ .string = "settings-choice-query" })
        .autofocus()
        .build());
    try children.appendSlice(b.allocator(), &.{ try v.rule(b, c), list });
    const placement = v.popoverBounds(b.viewport(), self.picker_anchor, .{ .width = 264, .height = height + 54 });
    const popup = try b.fluent().adopt(try v.floatingPanel(b, c, .{ .width = placement.width, .height = placement.height }, ui.Insets.all(6), 6, children.items))
        .id(.{ .string = "settings-choices" })
        .build();
    return b.fluent().div()
        .items(.start)
        .padding(.{ .top = placement.y, .left = placement.x })
        .stack()
        .children(.{popup})
        .listeners(.{ .on_input = b.onInput(View.closePicker) })
        .modal()
        .build();
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
        try cx.painter.fillRect(.{ .bounds = bounds, .radius = bounds.height / 2, .color = if (self.enabled) self.colors.primary else self.colors.line });
        try cx.painter.fillRect(.{ .bounds = .{ .x = bounds.x + (if (self.enabled) @as(f32, 15) else 3), .y = bounds.y + 3, .width = 12, .height = 12 }, .radius = (bounds.height - 6) / 2, .color = if (self.enabled) self.colors.text else self.colors.muted });
    }
};

fn palette(values: model.Values, generation: ?ext.Snapshot, system_dark: bool) v.Palette {
    var c: v.Palette = if (theme_module.isLight(values.theme, system_dark)) v.Palette.light else .{};
    if (generation) |snapshot| if (snapshot.resolveTheme(values.theme)) |theme| {
        inline for (.{ "document", "chrome", "sidebar", "panel", "line", "text", "muted", "accent", "selected", "warning", "primary" }) |name| @field(c, name) = services_extensions.color(@field(theme.colors, name));
        c.applySelection(services_extensions.color(theme.colors.selected));
        c.element = c.chrome;
        c.primary_hover = c.selected;
        c.on_primary = c.text;
    };
    return c;
}
