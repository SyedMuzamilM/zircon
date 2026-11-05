//! One persisted settings identity shared by editor/settings windows. Candidate
//! validation and atomic disk publication precede the effective-state swap.
const std = @import("std");
pub const Values = struct {
    font_size: f32 = 14,
    tab_width: u8 = 4,
    reduced_motion: bool = false,
    line_numbers: bool = true,
    git_gutters: bool = true,
    theme: []const u8 = "zircon.dark",
    icon_theme: []const u8 = "zircon.default",
};
pub const Patch = union(enum) { font_size: f32, tab_width: u8, reduced_motion: bool, line_numbers: bool, git_gutters: bool, theme: []const u8, icon_theme: []const u8 };
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
        const key = @tagName(patch);
        const value: std.json.Value = switch (patch) {
            .font_size => |n| .{ .float = n },
            .tab_width => |n| .{ .integer = n },
            .reduced_motion, .line_numbers, .git_gutters => |b| .{ .bool = b },
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
};
fn read(value: std.json.Value) Values {
    var result: Values = .{};
    if (value != .object) return result;
    if (value.object.get("font_size")) |v| result.font_size = number(v) orelse result.font_size;
    if (value.object.get("tab_width")) |v| if (v == .integer and v.integer >= 1 and v.integer <= 16) {
        result.tab_width = @intCast(v.integer);
    };
    inline for (.{ "reduced_motion", "line_numbers", "git_gutters" }) |key| if (value.object.get(key)) |v| {
        if (v == .bool) @field(result, key) = v.bool;
    };
    inline for (.{ "theme", "icon_theme" }) |key| if (value.object.get(key)) |v| {
        if (v == .string) @field(result, key) = v.string;
    };
    return result;
}
fn number(value: std.json.Value) ?f32 {
    return switch (value) {
        .float => |n| if (std.math.isFinite(n) and @abs(n) < std.math.floatMax(f32)) @floatCast(n) else null,
        .integer => |n| @floatFromInt(n),
        else => null,
    };
}
fn validate(value: std.json.Value) !void {
    if (value != .object) return error.InvalidSettings;
    if (value.object.get("schema_version")) |v| if (v != .integer or v.integer != 1) return error.UnsupportedSettingsVersion;
    if (value.object.get("font_size")) |v| {
        const n = number(v) orelse return error.InvalidSettings;
        if (n < 10 or n > 32) return error.InvalidSettings;
    }
    if (value.object.get("tab_width")) |v| if (v != .integer or v.integer < 1 or v.integer > 16) return error.InvalidSettings;
    inline for (.{ "reduced_motion", "line_numbers", "git_gutters" }) |key| if (value.object.get(key)) |v| if (v != .bool) return error.InvalidSettings;
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
