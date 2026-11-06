//! One persisted settings identity shared by editor/settings windows. Candidate
//! validation and atomic disk publication precede the effective-state swap.
const std = @import("std");
const typography = @import("zircon_ui").typography;
pub const Values = struct {
    key_bindings: @import("../key_bindings.zig").Overrides = .{},
    vim_mode: bool = false,
    vim_bindings: @import("zircon_editor").vim.Bindings = .{},
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
    theme: []const u8 = "zircon.dark",
    icon_theme: []const u8 = "zircon.default",
};
pub const Patch = union(enum) { editor_font_name: typography.FontName, interface_font_name: typography.FontName, vim_mode: bool, font_family: typography.CodeFont, ui_font_family: typography.UiFont, ui_font_size: f32, line_height: f32, font_ligatures: bool, font_size: f32, tab_width: u8, reduced_motion: bool, line_numbers: bool, git_gutters: bool, git_inline_blame: bool, theme: []const u8, icon_theme: []const u8 };
pub const Store = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    path: ?[]u8,
    parsed: std.json.Parsed(std.json.Value),
    revision: u64 = 0,
    pub fn init(a: std.mem.Allocator, io: std.Io, path: ?[]const u8) !Store {
        const owned = if (path) |p| try a.dupe(u8, p) else null;
        errdefer if (owned) |p| a.free(p);
        const bytes = if (path) |p| std.Io.Dir.cwd().readFileAlloc(io, p, a, .limited(1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        } else null;
        defer if (bytes) |value| a.free(value);
        var parsed = try std.json.parseFromSlice(std.json.Value, a, bytes orelse "{\"schema_version\":1}", .{ .allocate = .alloc_always });
        errdefer parsed.deinit();
        try validate(parsed.value);
        return .{ .allocator = a, .io = io, .path = owned, .parsed = parsed };
    }
    pub fn deinit(self: *Store) void {
        self.parsed.deinit();
        if (self.path) |path| self.allocator.free(path);
        self.* = undefined;
    }
    pub fn values(self: *const Store) Values {
        return read(self.parsed.value);
    }
    pub fn update(self: *Store, patch: Patch) !void {
        if (self.revision == std.math.maxInt(u64)) return error.SettingsRevisionExhausted;
        const serialized = try std.json.Stringify.valueAlloc(self.allocator, self.parsed.value, .{});
        defer self.allocator.free(serialized);
        var next = try std.json.parseFromSlice(std.json.Value, self.allocator, serialized, .{ .allocate = .alloc_always });
        errdefer next.deinit();
        const arena = next.arena.allocator();
        const key = switch (patch) {
            .editor_font_name => "font_family",
            .interface_font_name => "ui_font_family",
            else => @tagName(patch),
        };
        const value: std.json.Value = switch (patch) {
            .editor_font_name, .interface_font_name => |font| .{ .string = try arena.dupe(u8, font.slice()) },
            .font_size, .ui_font_size, .line_height => |n| .{ .float = n },
            .tab_width => |n| .{ .integer = n },
            .vim_mode, .reduced_motion, .line_numbers, .git_gutters, .git_inline_blame, .font_ligatures => |b| .{ .bool = b },
            .font_family => |font| .{ .string = try arena.dupe(u8, @tagName(font)) },
            .ui_font_family => |font| .{ .string = try arena.dupe(u8, @tagName(font)) },
            .theme, .icon_theme => |s| .{ .string = try arena.dupe(u8, s) },
        };
        try next.value.object.put(arena, key, value);
        try validate(next.value);
        const output = try std.json.Stringify.valueAlloc(self.allocator, next.value, .{ .whitespace = .indent_2 });
        defer self.allocator.free(output);
        if (self.path) |path| try persist(self.io, path, output);
        self.parsed.deinit();
        self.parsed = next;
        self.revision += 1;
    }
    pub fn ensureFile(self: *Store) !void {
        const path = self.path orelse return error.TemporarySettings;
        _ = std.Io.Dir.cwd().statFile(self.io, path, .{}) catch |err| {
            if (err != error.FileNotFound) return err;
            const bytes = try std.json.Stringify.valueAlloc(self.allocator, self.parsed.value, .{ .whitespace = .indent_2 });
            defer self.allocator.free(bytes);
            try persist(self.io, path, bytes);
        };
    }
};
fn read(value: std.json.Value) Values {
    var result: Values = .{};
    if (value != .object) return result;
    inline for (.{ "font_size", "ui_font_size", "line_height" }) |key| if (value.object.get(key)) |v| {
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
    if (value.object.get("tab_width")) |v| if (v == .integer and v.integer >= 1 and v.integer <= 16) {
        result.tab_width = @intCast(v.integer);
    };
    inline for (.{ "vim_mode", "reduced_motion", "line_numbers", "git_gutters", "git_inline_blame", "font_ligatures" }) |key| if (value.object.get(key)) |v| {
        if (v == .bool) @field(result, key) = v.bool;
    };
    inline for (.{ "theme", "icon_theme" }) |key| if (value.object.get(key)) |v| {
        if (v == .string) @field(result, key) = v.string;
    };
    if (value.object.get("key_bindings")) |v| result.key_bindings = @import("../key_bindings.zig").parse(v) catch unreachable;
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
fn parseVimBindings(value: std.json.Value) !@import("zircon_editor").vim.Bindings {
    if (value != .object or value.object.count() > 64) return error.InvalidKeyBindings;
    var result: @import("zircon_editor").vim.Bindings = .{};
    var entries = value.object.iterator();
    while (entries.next()) |entry| {
        if (entry.key_ptr.len != 1 or entry.key_ptr.*[0] < 32 or entry.key_ptr.*[0] >= 127 or entry.value_ptr.* != .string or entry.value_ptr.string.len != 1 or entry.value_ptr.string[0] < 32 or entry.value_ptr.string[0] >= 127) return error.InvalidKeyBindings;
        result.items[result.len] = .{ .from = entry.key_ptr.*[0], .to = entry.value_ptr.string[0] };
        result.len += 1;
    }
    return result;
}
fn validate(value: std.json.Value) !void {
    if (value == .object) if (value.object.get("vim_bindings")) |bindings| {
        _ = try parseVimBindings(bindings);
    };
    if (value != .object) return error.InvalidSettings;
    if (value.object.get("key_bindings")) |v| _ = try @import("../key_bindings.zig").parse(v);
    if (value.object.get("schema_version")) |v| if (v != .integer or v.integer != 1) return error.UnsupportedSettingsVersion;
    if (value.object.get("font_size")) |v| {
        const n = number(v) orelse return error.InvalidSettings;
        if (n < 10 or n > 32) return error.InvalidSettings;
    }
    if (value.object.get("ui_font_size")) |v| {
        const n = number(v) orelse return error.InvalidSettings;
        if (n < 10 or n > 20) return error.InvalidSettings;
    }
    if (value.object.get("line_height")) |v| {
        const n = number(v) orelse return error.InvalidSettings;
        if (n < 1 or n > 2.4) return error.InvalidSettings;
    }
    if (value.object.get("font_family")) |v| if (v == .string) {
        _ = try typography.FontName.init(v.string);
    } else return error.InvalidSettings;
    if (value.object.get("ui_font_family")) |v| if (v == .string) {
        _ = try typography.FontName.init(v.string);
    } else return error.InvalidSettings;
    if (value.object.get("tab_width")) |v| if (v != .integer or v.integer < 1 or v.integer > 16) return error.InvalidSettings;
    inline for (.{ "vim_mode", "reduced_motion", "line_numbers", "git_gutters", "git_inline_blame", "font_ligatures" }) |key| if (value.object.get(key)) |v| if (v != .bool) return error.InvalidSettings;
    inline for (.{ "theme", "icon_theme" }) |key| if (value.object.get(key)) |v| {
        if (v != .string or v.string.len == 0 or v.string.len > 256 or !std.unicode.utf8ValidateSlice(v.string)) return error.InvalidSettings;
    };
}
fn persist(io: std.Io, path: []const u8, bytes: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse ".";
    try std.Io.Dir.cwd().createDirPath(io, parent);
    var atomic = try std.Io.Dir.cwd().createFileAtomic(io, path, .{});
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, bytes);
    try atomic.file.sync(io);
    try atomic.replace(io);
}

fn parseEnum(comptime T: type, value: std.json.Value) ?T {
    if (value != .string) return null;
    inline for (std.meta.tags(T)) |tag| if (std.mem.eql(u8, value.string, @tagName(tag))) return tag;
    return null;
}
