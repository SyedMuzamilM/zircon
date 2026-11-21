//! One persisted settings identity shared by editor/settings windows. Candidate
//! validation and atomic disk publication precede the effective-state swap.
const std = @import("std");
const zircon_editor = @import("zircon_editor");
const zircon_ui = @import("zircon_ui");
const key_bindings_module = @import("../key_bindings.zig");
const jsonc = @import("jsonc.zig");
const typography = zircon_ui.typography;
const initial_json = "{\"schema_version\":1}";
pub const TerminalDock = enum { bottom, right };
pub const PanelLayout = enum { classic, agentic };
pub const Scope = enum { user, project };
pub const FormatOnSave = enum { off, on };
pub const Autosave = enum { off, on_focus_change, on_window_change, after_delay };

pub const BufferSettings = struct {
    tab_width: u8 = 4,
    soft_wrap: zircon_editor.wrap.Mode = .none,
    line_height: f32 = 1.6,
    indent_guides: bool = true,
    fold_controls: bool = true,
    line_numbers: bool = true,
    format_on_save: FormatOnSave = .off,
    remove_trailing_whitespace_on_save: bool = false,
    ensure_final_newline_on_save: bool = false,
    autosave: Autosave = .off,
    autosave_delay_ms: u32 = 1000,
};

pub const Values = struct {
    terminal_dock: TerminalDock = .bottom,
    panel_layout: PanelLayout = .classic,
    key_bindings: key_bindings_module.Overrides = .{},
    vim_mode: bool = false,
    cursor_shape: zircon_editor.cursor.Shape = .bar,
    cursor_blink: bool = true,
    smooth_cursor: bool = false,
    soft_wrap: zircon_editor.wrap.Mode = .none,
    vim_bindings: zircon_editor.vim.Bindings = .{},
    font_size: f32 = 14,
    editor_font_name: typography.FontName = .{},
    interface_font_name: typography.FontName = .{},
    font_family: typography.CodeFont = .lilex,
    ui_font_family: typography.UiFont = .plex,
    ui_font_size: f32 = 13,
    line_height: f32 = 1.6,
    font_ligatures: bool = false,
    tab_width: u8 = 4,
    reduced_motion: bool = false,
    line_numbers: bool = true,
    git_gutters: bool = true,
    git_inline_blame: bool = true,
    indent_guides: bool = true,
    active_line: bool = true,
    fold_controls: bool = true,
    project_file_icons: bool = true,
    project_folder_icons: bool = true,
    project_panel_width: f32 = 250,
    project_entry_spacing: f32 = 24,
    tooltips: bool = true,
    tooltip_delay: f32 = 400,
    search_case_sensitive: bool = false,
    search_whole_word: bool = false,
    agent_editor: bool = true,
    format_on_save: FormatOnSave = .off,
    remove_trailing_whitespace_on_save: bool = false,
    ensure_final_newline_on_save: bool = false,
    autosave: Autosave = .off,
    autosave_delay_ms: u32 = 1000,
    theme: []const u8 = "zircon.dark",
    icon_theme: []const u8 = "zircon.default",
};
pub const Patch = union(enum) {
    terminal_dock: TerminalDock,
    panel_layout: PanelLayout,
    indent_guides: bool,
    active_line: bool,
    fold_controls: bool,
    project_file_icons: bool,
    project_folder_icons: bool,
    project_panel_width: f32,
    project_entry_spacing: f32,
    tooltips: bool,
    tooltip_delay: f32,
    search_case_sensitive: bool,
    search_whole_word: bool,
    agent_editor: bool,
    soft_wrap: zircon_editor.wrap.Mode,
    editor_font_name: typography.FontName,
    interface_font_name: typography.FontName,
    vim_mode: bool,
    cursor_shape: zircon_editor.cursor.Shape,
    cursor_blink: bool,
    smooth_cursor: bool,
    font_family: typography.CodeFont,
    ui_font_family: typography.UiFont,
    ui_font_size: f32,
    line_height: f32,
    font_ligatures: bool,
    font_size: f32,
    tab_width: u8,
    reduced_motion: bool,
    line_numbers: bool,
    git_gutters: bool,
    git_inline_blame: bool,
    theme: []const u8,
    icon_theme: []const u8,
    format_on_save: FormatOnSave,
    remove_trailing_whitespace_on_save: bool,
    ensure_final_newline_on_save: bool,
    autosave: Autosave,
    autosave_delay_ms: u32,
};
pub const Store = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    path: ?[]u8,
    parsed: std.json.Parsed(std.json.Value),
    project_path: ?[]u8 = null,
    project_parsed: ?std.json.Parsed(std.json.Value) = null,
    ignored_project_keys: usize = 0,
    revision: u64 = 0,

    pub fn init(a: std.mem.Allocator, io: std.Io, path: ?[]const u8) !Store {
        const owned = if (path) |p| try a.dupe(u8, p) else null;
        errdefer if (owned) |p| a.free(p);
        var parsed = try parseUser(a, io, path);
        errdefer parsed.deinit();
        try validate(parsed.value);
        return .{ .allocator = a, .io = io, .path = owned, .parsed = parsed };
    }
    pub fn deinit(self: *Store) void {
        self.parsed.deinit();
        if (self.path) |path| self.allocator.free(path);
        if (self.project_path) |path| self.allocator.free(path);
        if (self.project_parsed) |*parsed| parsed.deinit();
        self.* = undefined;
    }
    pub fn setProjectRoot(self: *Store, root: ?[]const u8) !void {
        const path = if (root) |dir| try std.fs.path.join(self.allocator, &.{ dir, ".zircon", "settings.json" }) else null;
        if (path) |target| if (self.project_path) |previous| if (std.mem.eql(u8, previous, target)) {
            defer self.allocator.free(target);
            return self.reloadScope(.project, previous);
        };
        if (self.project_path) |old| self.allocator.free(old);
        self.project_path = path;
        self.replaceProject(.{});
        // Keep a new project's path available for repair when its file is invalid.
        if (path) |target| return self.reloadScope(.project, target);
        self.revision +%= 1;
    }

    pub fn reload(self: *Store) !void {
        var user = try parseUser(self.allocator, self.io, self.path);
        errdefer user.deinit();
        try validate(user.value);
        const project: ProjectLayer = if (self.project_path) |path| try self.readProject(path) else .{};
        self.parsed.deinit();
        self.parsed = user;
        self.replaceProject(project);
        self.revision +%= 1;
    }

    pub fn reloadSavedPath(self: *Store, path: []const u8) !bool {
        if (self.path) |user| if (std.mem.eql(u8, user, path)) {
            try self.reloadScope(.user, user);
            return true;
        };
        if (self.project_path) |project| if (std.mem.eql(u8, project, path)) {
            try self.reloadScope(.project, project);
            return true;
        };
        return false;
    }

    fn reloadScope(self: *Store, scope: Scope, path: []const u8) !void {
        switch (scope) {
            .user => {
                var next = try parseUser(self.allocator, self.io, path);
                errdefer next.deinit();
                try validate(next.value);
                self.parsed.deinit();
                self.parsed = next;
            },
            .project => self.replaceProject(try self.readProject(path)),
        }
        self.revision +%= 1;
    }

    fn readProject(self: *const Store, path: []const u8) !ProjectLayer {
        var parsed = (try parseProject(self.allocator, self.io, path)) orelse return .{};
        errdefer parsed.deinit();
        return .{ .parsed = parsed, .ignored = try validateProject(parsed.value) };
    }

    fn replaceProject(self: *Store, project: ProjectLayer) void {
        if (self.project_parsed) |*old| old.deinit();
        self.project_parsed = project.parsed;
        self.ignored_project_keys = project.ignored;
    }

    pub fn values(self: *const Store) Values {
        return self.scopeValues(.project);
    }

    pub fn scopeValues(self: *const Store, scope: Scope) Values {
        return self.valuesWithProject(if (scope == .project) self else null);
    }

    pub fn valuesWithProject(self: *const Store, project: ?*const Store) Values {
        var result = read(self.parsed.value);
        if (project) |layer| if (layer.project_parsed) |parsed| {
            readBufferFields(&result, parsed.value.object, .project);
        };
        return result;
    }

    pub fn bufferSettings(self: *const Store, language_id: []const u8, language_name: []const u8) BufferSettings {
        return self.bufferWithProject(self, language_id, language_name);
    }

    pub fn bufferWithProject(self: *const Store, project: ?*const Store, language_id: []const u8, language_name: []const u8) BufferSettings {
        const project_value = if (project) |layer| layer.project_parsed else null;
        var result: BufferSettings = .{};
        readBufferFields(&result, self.parsed.value.object, .user);
        if (project_value) |parsed| readBufferFields(&result, parsed.value.object, .project);
        applyLanguageLayer(&result, self.parsed.value.object, language_id, language_name, .user);
        if (project_value) |parsed| applyLanguageLayer(&result, parsed.value.object, language_id, language_name, .project);
        return result;
    }

    pub fn hasProjectOverride(self: *const Store, key: []const u8) bool {
        const parsed = self.project_parsed orelse return false;
        return isProjectAllowedKey(key) and parsed.value.object.contains(key);
    }

    pub fn update(self: *Store, patch: Patch) !void {
        try self.updateScope(.user, patch);
    }

    pub fn updateScope(self: *Store, scope: Scope, patch: Patch) !void {
        if (scope == .project) {
            if (!isProjectAllowedPatch(patch)) return error.DisallowedProjectSetting;
            if (self.project_path == null) return error.NoProjectSettings;
        }
        var next = try self.copyLayer(scope);
        errdefer next.deinit();
        if (next.value != .object) return error.InvalidSettings;
        const arena = next.arena.allocator();
        const key = switch (patch) {
            .editor_font_name => "font_family",
            .interface_font_name => "ui_font_family",
            else => @tagName(patch),
        };
        const value: std.json.Value = switch (patch) {
            .editor_font_name, .interface_font_name => |font| .{ .string = try arena.dupe(u8, font.slice()) },
            .font_size, .ui_font_size, .line_height, .project_panel_width, .project_entry_spacing, .tooltip_delay => |n| .{ .float = n },
            .tab_width, .autosave_delay_ms => |n| .{ .integer = n },
            .vim_mode, .cursor_blink, .smooth_cursor, .reduced_motion, .line_numbers, .git_gutters, .git_inline_blame, .font_ligatures, .indent_guides, .active_line, .fold_controls, .project_file_icons, .project_folder_icons, .tooltips, .search_case_sensitive, .search_whole_word, .agent_editor, .remove_trailing_whitespace_on_save, .ensure_final_newline_on_save => |b| .{ .bool = b },
            .terminal_dock => |mode| .{ .string = @tagName(mode) },
            .panel_layout => |mode| .{ .string = @tagName(mode) },
            .soft_wrap => |mode| .{ .string = @tagName(mode) },
            .format_on_save => |mode| .{ .string = @tagName(mode) },
            .autosave => |mode| .{ .string = @tagName(mode) },
            .cursor_shape => |shape| .{ .string = @tagName(shape) },
            .font_family => |font| .{ .string = try arena.dupe(u8, @tagName(font)) },
            .ui_font_family => |font| .{ .string = try arena.dupe(u8, @tagName(font)) },
            .theme, .icon_theme => |s| .{ .string = try arena.dupe(u8, s) },
        };
        try next.value.object.put(arena, key, value);
        try self.publish(scope, next);
    }

    pub fn clearProjectKey(self: *Store, key: []const u8) !void {
        if (!isProjectAllowedKey(key)) return error.DisallowedProjectSetting;
        if (!self.hasProjectOverride(key)) return;
        var next = try self.copyLayer(.project);
        errdefer next.deinit();
        if (next.value != .object) return error.InvalidSettings;
        _ = next.value.object.orderedRemove(key);
        try self.publish(.project, next);
    }

    fn copyLayer(self: *const Store, scope: Scope) !std.json.Parsed(std.json.Value) {
        const value = switch (scope) {
            .user => self.parsed.value,
            // Read the current project file before rewriting so newly edited
            // keys survive, and an invalid file remains available for repair.
            .project => if (try parseProject(self.allocator, self.io, self.project_path.?)) |parsed| return parsed else return parseUser(self.allocator, self.io, null),
        };
        const serialized = try std.json.Stringify.valueAlloc(self.allocator, value, .{});
        defer self.allocator.free(serialized);
        return std.json.parseFromSlice(std.json.Value, self.allocator, serialized, .{ .allocate = .alloc_always });
    }

    fn publish(self: *Store, scope: Scope, next: std.json.Parsed(std.json.Value)) !void {
        if (self.revision == std.math.maxInt(u64)) return error.SettingsRevisionExhausted;
        const ignored = switch (scope) {
            .user => blk: {
                try validate(next.value);
                break :blk 0;
            },
            .project => try validateProject(next.value),
        };
        const path = if (scope == .user) self.path else self.project_path;
        if (path) |target| try self.persistValue(scope, target, next.value);
        switch (scope) {
            .user => {
                self.parsed.deinit();
                self.parsed = next;
            },
            .project => self.replaceProject(.{ .parsed = next, .ignored = ignored }),
        }
        self.revision += 1;
    }

    fn persistValue(self: *Store, scope: Scope, path: []const u8, value: std.json.Value) !void {
        const output = try std.json.Stringify.valueAlloc(self.allocator, value, .{ .whitespace = .indent_2 });
        defer self.allocator.free(output);
        if (scope == .user) {
            const parent = std.fs.path.dirname(path) orelse ".";
            try std.Io.Dir.cwd().createDirPath(self.io, parent);
            return persist(.cwd(), self.io, path, output, true);
        }
        const dir = (try projectDirectory(self.io, path, true)) orelse return error.FileNotFound;
        defer dir.close(self.io);
        try persist(dir, self.io, std.fs.path.basename(path), output, true);
    }

    pub fn ensureFile(self: *Store) !void {
        try self.ensureScopeFile(.user);
    }

    pub fn ensureScopeFile(self: *Store, scope: Scope) !void {
        const path = (if (scope == .user) self.path else self.project_path) orelse return error.TemporarySettings;
        if (scope == .user) {
            _ = std.Io.Dir.cwd().statFile(self.io, path, .{}) catch |err| {
                if (err != error.FileNotFound) return err;
                try self.persistValue(.user, path, self.parsed.value);
            };
            return;
        }
        const dir = (try projectDirectory(self.io, path, true)) orelse return error.FileNotFound;
        defer dir.close(self.io);
        const name = std.fs.path.basename(path);
        const stat = try settingsStat(dir, self.io, name, false);
        if (stat != null) return;
        const parsed = self.project_parsed orelse return persist(dir, self.io, name, initial_json, false);
        const output = try std.json.Stringify.valueAlloc(self.allocator, parsed.value, .{ .whitespace = .indent_2 });
        defer self.allocator.free(output);
        try persist(dir, self.io, name, output, false);
    }
};

const ProjectLayer = struct {
    parsed: ?std.json.Parsed(std.json.Value) = null,
    ignored: usize = 0,
};

fn parseUser(a: std.mem.Allocator, io: std.Io, path: ?[]const u8) !std.json.Parsed(std.json.Value) {
    if (path) |target| if (try parseOptional(a, io, target)) |parsed| return parsed;
    return std.json.parseFromSlice(std.json.Value, a, initial_json, .{ .allocate = .alloc_always });
}

fn projectDirectory(io: std.Io, path: []const u8, create: bool) !?std.Io.Dir {
    const parent = std.fs.path.dirname(path).?;
    if (create) std.Io.Dir.cwd().createDir(io, parent, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    return std.Io.Dir.cwd().openDir(io, parent, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
}

fn settingsStat(dir: std.Io.Dir, io: std.Io, path: []const u8, follow_symlinks: bool) !?std.Io.File.Stat {
    const stat = dir.statFile(io, path, .{ .follow_symlinks = follow_symlinks }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    if (stat.kind != .file) return error.NotRegularFile;
    return stat;
}

fn parseProject(a: std.mem.Allocator, io: std.Io, path: []const u8) !?std.json.Parsed(std.json.Value) {
    const dir = (try projectDirectory(io, path, false)) orelse return null;
    defer dir.close(io);
    return parseFile(a, io, dir, std.fs.path.basename(path), false);
}

fn parseOptional(a: std.mem.Allocator, io: std.Io, path: []const u8) !?std.json.Parsed(std.json.Value) {
    return parseFile(a, io, .cwd(), path, true);
}

fn parseFile(a: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8, follow_symlinks: bool) !?std.json.Parsed(std.json.Value) {
    _ = (try settingsStat(dir, io, path, follow_symlinks)) orelse return null;
    const file = dir.openFile(io, path, .{ .follow_symlinks = follow_symlinks, .allow_directory = false }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(io);
    var reader = file.reader(io, &.{});
    const raw = reader.interface.allocRemaining(a, .limited(1024 * 1024)) catch |err| switch (err) {
        error.ReadFailed => return reader.err.?,
        else => return err,
    };
    defer a.free(raw);
    const stripped = try jsonc.strip(a, raw);
    defer a.free(stripped);
    return try std.json.parseFromSlice(std.json.Value, a, stripped, .{ .allocate = .alloc_always });
}

fn read(value: std.json.Value) Values {
    var result: Values = .{};
    if (value != .object) return result;
    inline for (.{ "font_size", "ui_font_size", "project_panel_width", "project_entry_spacing", "tooltip_delay" }) |key| if (value.object.get(key)) |v| {
        @field(result, key) = number(v) orelse @field(result, key);
    };
    if (value.object.get("font_family")) |v| {
        result.font_family = parseEnum(typography.CodeFont, v) orelse .lilex;
        if (v == .string and parseEnum(typography.CodeFont, v) == null) result.editor_font_name = typography.FontName.init(v.string) catch .{};
    }
    if (value.object.get("ui_font_family")) |v| {
        result.ui_font_family = parseEnum(typography.UiFont, v) orelse .plex;
        if (v == .string and parseEnum(typography.UiFont, v) == null) result.interface_font_name = typography.FontName.init(v.string) catch .{};
    }
    if (value.object.get("terminal_dock")) |v| result.terminal_dock = parseEnum(TerminalDock, v) orelse .bottom;
    if (value.object.get("panel_layout")) |v| result.panel_layout = parseEnum(PanelLayout, v) orelse .classic;
    readBufferFields(&result, value.object, .user);
    if (value.object.get("cursor_shape")) |v| result.cursor_shape = parseEnum(zircon_editor.cursor.Shape, v) orelse .bar;
    inline for (.{ "vim_mode", "cursor_blink", "smooth_cursor", "reduced_motion", "git_gutters", "git_inline_blame", "font_ligatures", "active_line", "project_file_icons", "project_folder_icons", "tooltips", "search_case_sensitive", "search_whole_word", "agent_editor" }) |key| if (value.object.get(key)) |v| {
        if (v == .bool) @field(result, key) = v.bool;
    };
    inline for (.{ "theme", "icon_theme" }) |key| if (value.object.get(key)) |v| {
        if (v == .string) @field(result, key) = v.string;
    };
    if (value.object.get("key_bindings")) |v| result.key_bindings = key_bindings_module.parse(v) catch unreachable;
    if (value.object.get("vim_bindings")) |bindings| result.vim_bindings = parseVimBindings(bindings) catch .{};
    return result;
}

fn number(value: std.json.Value) ?f32 {
    return switch (value) {
        .float => |n| if (std.math.isFinite(n) and @abs(n) < std.math.floatMax(f32)) @floatCast(n) else null,
        .integer => |n| @floatFromInt(n),
        else => null,
    };
}

fn parseVimBindings(value: std.json.Value) !zircon_editor.vim.Bindings {
    if (value != .object or value.object.count() > 64) return error.InvalidKeyBindings;
    var result: zircon_editor.vim.Bindings = .{};
    var entries = value.object.iterator();
    while (entries.next()) |entry| {
        if (entry.key_ptr.len != 1 or entry.key_ptr.*[0] < 32 or entry.key_ptr.*[0] >= 127 or entry.value_ptr.* != .string or entry.value_ptr.string.len != 1 or entry.value_ptr.string[0] < 32 or entry.value_ptr.string[0] >= 127) return error.InvalidKeyBindings;
        result.items[result.len] = .{ .from = entry.key_ptr.*[0], .to = entry.value_ptr.string[0] };
        result.len += 1;
    }
    return result;
}

fn validate(value: std.json.Value) !void {
    if (value == .object) {
        if (value.object.get("terminal_dock")) |v| if (parseEnum(TerminalDock, v) == null) return error.InvalidSettings;
        if (value.object.get("panel_layout")) |v| if (parseEnum(PanelLayout, v) == null) return error.InvalidSettings;
    }
    if (value == .object) if (value.object.get("vim_bindings")) |bindings| {
        _ = try parseVimBindings(bindings);
    };
    if (value != .object) return error.InvalidSettings;
    if (value.object.get("key_bindings")) |v| _ = try key_bindings_module.parse(v);
    if (value.object.get("schema_version")) |v| if (v != .integer or v.integer != 1) return error.UnsupportedSettingsVersion;
    if (value.object.get("font_size")) |v| {
        const n = number(v) orelse return error.InvalidSettings;
        if (n < 10 or n > 32) return error.InvalidSettings;
    }
    if (value.object.get("ui_font_size")) |v| {
        const n = number(v) orelse return error.InvalidSettings;
        if (n < 10 or n > 20) return error.InvalidSettings;
    }
    inline for (.{ .{ "project_panel_width", @as(f32, 120), @as(f32, 700) }, .{ "project_entry_spacing", @as(f32, 20), @as(f32, 36) }, .{ "tooltip_delay", @as(f32, 0), @as(f32, 2000) } }) |limit| if (value.object.get(limit[0])) |v| {
        const n = number(v) orelse return error.InvalidSettings;
        if (n < limit[1] or n > limit[2]) return error.InvalidSettings;
    };
    if (value.object.get("font_family")) |v| if (v == .string) {
        _ = try typography.FontName.init(v.string);
    } else return error.InvalidSettings;
    if (value.object.get("ui_font_family")) |v| if (v == .string) {
        _ = try typography.FontName.init(v.string);
    } else return error.InvalidSettings;
    if (value.object.get("cursor_shape")) |v| if (parseEnum(zircon_editor.cursor.Shape, v) == null) return error.InvalidSettings;
    inline for (.{ "vim_mode", "cursor_blink", "smooth_cursor", "reduced_motion", "git_gutters", "git_inline_blame", "font_ligatures", "active_line", "project_file_icons", "project_folder_icons", "tooltips", "search_case_sensitive", "search_whole_word", "agent_editor" }) |key| if (value.object.get(key)) |v| if (v != .bool) return error.InvalidSettings;
    inline for (.{ "theme", "icon_theme" }) |key| if (value.object.get(key)) |v| {
        if (v != .string or v.string.len == 0 or v.string.len > 256 or !std.unicode.utf8ValidateSlice(v.string)) return error.InvalidSettings;
    };
    try validateBufferFields(value.object, .user);
    _ = try validateLanguages(value.object, .user);
}

const project_buffer_keys = .{
    "tab_width",      "soft_wrap",                          "indent_guides",                "fold_controls", "line_numbers",
    "format_on_save", "remove_trailing_whitespace_on_save", "ensure_final_newline_on_save", "autosave",      "autosave_delay_ms",
};

pub fn isLanguageAllowedKey(key: []const u8, scope: Scope) bool {
    inline for (project_buffer_keys) |allowed| if (std.mem.eql(u8, allowed, key)) return true;
    return scope == .user and std.mem.eql(u8, key, "line_height");
}

pub fn isProjectAllowedKey(key: []const u8) bool {
    return isLanguageAllowedKey(key, .project) or std.mem.eql(u8, key, "schema_version") or std.mem.eql(u8, key, "languages");
}

pub fn isProjectAllowedPatch(patch: Patch) bool {
    return isLanguageAllowedKey(@tagName(patch), .project);
}

fn validateProject(value: std.json.Value) !usize {
    if (value != .object) return error.InvalidSettings;
    const obj = value.object;
    if (obj.get("schema_version")) |v| if (v != .integer or v.integer != 1) return error.UnsupportedSettingsVersion;
    try validateBufferFields(obj, .project);
    var ignored = try validateLanguages(obj, .project);
    for (obj.keys()) |key| if (!isProjectAllowedKey(key)) {
        ignored += 1;
    };
    return ignored;
}

fn validateLanguages(obj: std.json.ObjectMap, scope: Scope) !usize {
    const languages = obj.get("languages") orelse return 0;
    if (languages != .object or languages.object.count() > 128) return error.InvalidSettings;
    var ignored: usize = 0;
    var entries = languages.object.iterator();
    while (entries.next()) |entry| {
        const name = entry.key_ptr.*;
        const settings = entry.value_ptr.*;
        if (name.len == 0 or name.len > 64 or !std.unicode.utf8ValidateSlice(name) or settings != .object) return error.InvalidSettings;
        for (settings.object.keys()) |key| {
            if (isLanguageAllowedKey(key, scope)) continue;
            if (scope == .user) return error.InvalidSettings;
            ignored += 1;
        }
        try validateBufferFields(settings.object, scope);
    }
    return ignored;
}

fn validateBufferFields(obj: std.json.ObjectMap, scope: Scope) !void {
    inline for (project_buffer_keys ++ .{"line_height"}) |key| {
        if (scope == .user or !std.mem.eql(u8, key, "line_height")) if (obj.get(key)) |value| {
            const valid = switch (@FieldType(BufferSettings, key)) {
                bool => value == .bool,
                u8 => value == .integer and value.integer >= 1 and value.integer <= 16,
                u32 => value == .integer and value.integer >= 200 and value.integer <= 60_000,
                f32 => if (number(value)) |n| n >= 1 and n <= 2.4 else false,
                else => parseEnum(@FieldType(BufferSettings, key), value) != null,
            };
            if (!valid) return error.InvalidSettings;
        };
    }
}

fn readBufferFields(target: anytype, obj: std.json.ObjectMap, scope: Scope) void {
    // Both inputs were validated. Project values outside the allowlist are
    // retained in their source document but never copied into effective values.
    inline for (project_buffer_keys ++ .{"line_height"}) |key| {
        if (scope == .user or !std.mem.eql(u8, key, "line_height")) if (obj.get(key)) |value| {
            @field(target, key) = switch (@FieldType(BufferSettings, key)) {
                bool => value.bool,
                u8, u32 => @intCast(value.integer),
                f32 => number(value).?,
                else => parseEnum(@FieldType(BufferSettings, key), value).?,
            };
        };
    }
}

fn applyLanguageLayer(target: *BufferSettings, obj: std.json.ObjectMap, id: []const u8, name: []const u8, scope: Scope) void {
    const languages = obj.get("languages") orelse return;
    var entries = languages.object.iterator();
    while (entries.next()) |entry| {
        const key = entry.key_ptr.*;
        if (std.ascii.eqlIgnoreCase(key, id) or std.ascii.eqlIgnoreCase(key, name)) {
            readBufferFields(target, entry.value_ptr.object, scope);
        }
    }
}

fn persist(dir: std.Io.Dir, io: std.Io, path: []const u8, bytes: []const u8, replace: bool) !void {
    var atomic = try dir.createFileAtomic(io, path, .{ .replace = replace });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, bytes);
    try atomic.file.sync(io);
    if (replace) try atomic.replace(io) else try atomic.link(io);
}

fn parseEnum(comptime T: type, value: std.json.Value) ?T {
    if (value != .string) return null;
    inline for (std.meta.tags(T)) |tag| if (std.mem.eql(u8, value.string, @tagName(tag))) return tag;
    return null;
}
