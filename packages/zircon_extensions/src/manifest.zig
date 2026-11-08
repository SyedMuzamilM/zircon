//! Strict schema-one manifests. Parsing copies JSON strings into the snapshot
//! arena; referenced PNG assets are loaded once and survive uninstall/reload.
const std = @import("std");
const fs = @import("filesystem.zig");
const m = @import("model.zig");
pub const max_json_bytes = 16 * 1024 * 1024;
pub const RawColors = struct {
    document: []const u8 = "#171b22",
    chrome: []const u8 = "#202630",
    sidebar: []const u8 = "#1c222b",
    panel: []const u8 = "#252d39",
    line: []const u8 = "#303a48",
    text: []const u8 = "#d9e1ed",
    muted: []const u8 = "#8996a9",
    accent: []const u8 = "#8abaff",
    selected: []const u8 = "#2d4261",
    warning: []const u8 = "#e7bc80",
    primary: []const u8 = "#365b93",
};
pub const RawSyntax = struct { plain: []const u8 = "#d9e1ed", keyword: []const u8 = "#c792ea", string: []const u8 = "#b4d28b", number: []const u8 = "#e5b37c", comment: []const u8 = "#758399", punctuation: []const u8 = "#a9bed6", builtin: []const u8 = "#79c5cb" };
const RawTheme = struct { id: []const u8, name: []const u8, colors: RawColors = .{}, syntax: RawSyntax = .{} };
const RawIcon = struct { symbol: ?[]const u8 = null, png: ?[]const u8 = null };
const RawMapping = struct { key: []const u8, icon: RawIcon };
const RawIcons = struct { id: []const u8, name: []const u8, files: []const RawMapping = &.{}, extensions: []const RawMapping = &.{}, folders: []const RawMapping = &.{}, stems: []const RawMapping = &.{}, default_file: RawIcon = .{ .symbol = "·" }, default_folder: RawIcon = .{ .symbol = "▸" } };
const RawLanguage = struct { lsp_id: ?[]const u8 = null, grammar: ?m.Grammar = null, id: []const u8, name: []const u8, extensions: []const []const u8 = &.{}, filenames: []const []const u8 = &.{}, keywords: []const []const u8 = &.{}, line_comment: ?[]const u8 = null, block_comment: ?m.BlockComment = null, string_delimiters: []const u8 = "\"'" };
const RawServer = struct { zed_wasm: ?[]const u8 = null, zed_server: ?[]const u8 = null, id: []const u8, languages: []const []const u8, command: []const u8, args: []const []const u8 = &.{} };
const Raw = struct {
    unsupported_features: []const []const u8 = &.{},
    schema_version: u32,
    id: []const u8,
    name: []const u8,
    version: []const u8,
    description: []const u8 = "",
    contributes: struct { themes: []const RawTheme = &.{}, icon_themes: []const RawIcons = &.{}, languages: []const RawLanguage = &.{}, language_servers: []const RawServer = &.{} } = .{},
};
pub fn validId(id: []const u8) bool {
    if (id.len == 0 or id.len > 128 or id[0] == '.' or id[id.len - 1] == '.') return false;
    if (std.mem.indexOf(u8, id, "..") != null) return false;
    for (id) |byte| if (!(std.ascii.isLower(byte) or std.ascii.isDigit(byte) or byte == '.' or byte == '_' or byte == '-')) return false;
    return true;
}
fn label(value: []const u8, max: usize) !void {
    if (value.len == 0 or value.len > max or !std.unicode.utf8ValidateSlice(value) or std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidManifest;
}
pub fn load(a: std.mem.Allocator, io: std.Io, directory: []const u8, enabled: bool) !m.Extension {
    try fs.validateBundle(a, io, directory);
    const path = try std.fs.path.join(a, &.{ directory, "extension.json" });
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(max_json_bytes)) catch |err| return if (err == error.StreamTooLong) error.ManifestTooLarge else err;
    const raw = try std.json.parseFromSliceLeaky(Raw, a, bytes, .{ .allocate = .alloc_always });
    if (raw.schema_version != 1) return error.UnsupportedSchemaVersion;
    if (!validId(raw.id)) return error.InvalidExtensionId;
    try label(raw.name, 256);
    try label(raw.version, 64);
    if (raw.description.len > 4096 or !std.unicode.utf8ValidateSlice(raw.description)) return error.InvalidManifest;
    if (raw.unsupported_features.len > 32) return error.InvalidManifest;
    for (raw.unsupported_features) |name| try label(name, 128);
    const count = raw.contributes.themes.len + raw.contributes.icon_themes.len + raw.contributes.languages.len + raw.contributes.language_servers.len;
    if (count == 0 or count > 256) return error.InvalidContributionCount;
    const themes = try a.alloc(m.Theme, raw.contributes.themes.len);
    for (raw.contributes.themes, 0..) |theme, i| {
        if (!validId(theme.id)) return error.InvalidContributionId;
        try label(theme.name, 256);
        var colors: m.Colors = undefined;
        inline for (@typeInfo(RawColors).@"struct".field_names) |field| @field(colors, field) = try m.Color.parse(@field(theme.colors, field));
        var syntax: m.SyntaxColors = undefined;
        inline for (@typeInfo(RawSyntax).@"struct".field_names) |field| @field(syntax, field) = try m.Color.parse(@field(theme.syntax, field));
        themes[i] = .{ .id = theme.id, .name = theme.name, .colors = colors, .syntax = syntax };
    }
    var icon_cache: std.StringHashMapUnmanaged(m.Icon) = .empty;
    const icons = try a.alloc(m.IconTheme, raw.contributes.icon_themes.len);
    for (raw.contributes.icon_themes, 0..) |theme, i| {
        if (!validId(theme.id)) return error.InvalidContributionId;
        try label(theme.name, 256);
        icons[i] = .{ .id = theme.id, .name = theme.name, .files = try mappings(a, io, directory, &icon_cache, theme.files), .extensions = try mappings(a, io, directory, &icon_cache, theme.extensions), .folders = try mappings(a, io, directory, &icon_cache, theme.folders), .stems = try mappings(a, io, directory, &icon_cache, theme.stems), .default_file = try icon(a, io, directory, &icon_cache, theme.default_file), .default_folder = try icon(a, io, directory, &icon_cache, theme.default_folder) };
    }
    const languages = try a.alloc(m.Language, raw.contributes.languages.len);
    for (raw.contributes.languages, 0..) |language, i| {
        if (!validId(language.id)) return error.InvalidContributionId;
        try label(language.name, 256);
        if (language.extensions.len + language.filenames.len == 0 or language.keywords.len > 4096) return error.InvalidLanguage;
        for (language.extensions) |extension| {
            try label(extension, 64);
            if (std.mem.indexOfAny(u8, extension, "/\\") != null) return error.InvalidLanguage;
        }
        for (language.filenames) |filename| {
            try label(filename, 256);
            if (std.mem.indexOfAny(u8, filename, "/\\") != null) return error.InvalidLanguage;
        }
        for (language.keywords) |keyword| try label(keyword, 128);
        if (language.line_comment) |comment| try label(comment, 16);
        if (language.block_comment) |comment| {
            try label(comment.start, 16);
            try label(comment.end, 16);
        }
        if (language.string_delimiters.len > 8) return error.InvalidLanguage;
        for (language.string_delimiters) |delimiter| if (delimiter != '\'' and delimiter != '"' and delimiter != '`') return error.InvalidLanguage;
        if (language.lsp_id) |id| try label(id, 128);
        const grammar: ?m.Grammar = if (language.grammar) |g| blk: {
            if (!validId(g.name)) return error.InvalidLanguage;
            break :blk .{ .builtin = g.builtin, .name = g.name, .wasm = if (g.builtin) "@builtin" else try assetPath(a, io, directory, g.wasm), .highlights = if (g.builtin) "" else try assetPath(a, io, directory, g.highlights) };
        } else null;
        languages[i] = .{ .lsp_id = language.lsp_id, .grammar = grammar, .id = language.id, .name = language.name, .extensions = language.extensions, .filenames = language.filenames, .keywords = language.keywords, .line_comment = language.line_comment, .block_comment = language.block_comment, .string_delimiters = language.string_delimiters };
    }
    const servers = try a.alloc(m.Server, raw.contributes.language_servers.len);
    for (raw.contributes.language_servers, 0..) |server, i| {
        if (!validId(server.id) or server.languages.len == 0 or server.languages.len > 128 or server.args.len > 128) return error.InvalidLanguageServer;
        try label(server.command, 4096);
        for (server.languages) |language| if (!validId(language)) return error.InvalidLanguageServer;
        for (server.args) |arg| if (arg.len > 4096 or !std.unicode.utf8ValidateSlice(arg) or std.mem.indexOfScalar(u8, arg, 0) != null) return error.InvalidLanguageServer;
        if (server.zed_server) |name| try label(name, 128);
        if (std.mem.eql(u8, server.command, "@zircon-builtin") and server.zed_server == null) return error.InvalidLanguageServer;
        if (!std.mem.eql(u8, server.command, "@zircon-builtin") and ((server.zed_wasm == null) != (server.zed_server == null))) return error.InvalidLanguageServer;
        servers[i] = .{ .zed_server = server.zed_server, .zed_wasm = if (server.zed_wasm) |wasm_path| try assetPath(a, io, directory, wasm_path) else null, .id = server.id, .languages = server.languages, .command = server.command, .args = server.args };
    }
    return .{ .unsupported_features = raw.unsupported_features, .id = raw.id, .name = raw.name, .version = raw.version, .description = raw.description, .enabled = enabled, .themes = themes, .icon_themes = icons, .languages = languages, .language_servers = servers };
}
fn mappings(a: std.mem.Allocator, io: std.Io, directory: []const u8, cache: *std.StringHashMapUnmanaged(m.Icon), raw: []const RawMapping) ![]m.IconMapping {
    if (raw.len > 4096) return error.InvalidIconTheme;
    const values = try a.alloc(m.IconMapping, raw.len);
    for (raw, 0..) |mapping, i| {
        try label(mapping.key, 256);
        for (raw[0..i]) |previous| if (std.mem.eql(u8, mapping.key, previous.key)) return error.DuplicateIconMapping;
        values[i] = .{ .key = mapping.key, .icon = try icon(a, io, directory, cache, mapping.icon) };
    }
    return values;
}
fn icon(a: std.mem.Allocator, io: std.Io, directory: []const u8, cache: *std.StringHashMapUnmanaged(m.Icon), raw: RawIcon) !m.Icon {
    if ((raw.symbol == null) == (raw.png == null)) return error.InvalidIcon;
    if (raw.symbol) |symbol| {
        try label(symbol, 64);
        return .{ .symbol = symbol };
    }
    const relative = raw.png.?;
    if (cache.get(relative)) |cached| return cached;
    try fs.validateRelative(relative);
    const path = try std.fs.path.join(a, &.{ directory, relative });
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(8 * 1024 * 1024)) catch |err| return if (err == error.StreamTooLong) error.AssetTooLarge else err;
    if (bytes.len < 33 or !std.mem.eql(u8, bytes[0..8], "\x89PNG\r\n\x1a\n") or
        std.mem.readInt(u32, bytes[8..12], .big) != 13 or !std.mem.eql(u8, bytes[12..16], "IHDR")) return error.InvalidPngAsset;
    const width = std.mem.readInt(u32, bytes[16..20], .big);
    const height = std.mem.readInt(u32, bytes[20..24], .big);
    if (width == 0 or height == 0 or width > 8192 or height > 8192 or @as(u64, width) * height > 16 * 1024 * 1024) return error.InvalidPngAsset;
    const result: m.Icon = .{ .png = .{ .path = relative, .bytes = bytes } };
    try cache.put(a, relative, result);
    return result;
}
pub fn validateUnique(extensions: []const m.Extension) !void {
    for (extensions, 0..) |extension, i| {
        for (extensions[0..i]) |other| if (std.mem.eql(u8, extension.id, other.id)) return error.DuplicateExtension;
        inline for (.{ "themes", "icon_themes", "languages", "language_servers" }) |field| {
            for (@field(extension, field), 0..) |contribution, j| {
                for (@field(extension, field)[0..j]) |previous| if (std.mem.eql(u8, contribution.id, previous.id)) return error.DuplicateContribution;
                for (extensions[0..i]) |other| for (@field(other, field)) |previous| if (std.mem.eql(u8, contribution.id, previous.id)) return error.DuplicateContribution;
            }
        }
    }
}

fn assetPath(a: std.mem.Allocator, io: std.Io, directory: []const u8, relative: []const u8) ![]const u8 {
    try fs.validateRelative(relative);
    const path = try std.fs.path.join(a, &.{ directory, relative });
    const stat = try std.Io.Dir.cwd().statFile(io, path, .{});
    if (stat.kind != .file or stat.size > 64 * 1024 * 1024) return error.InvalidManifest;
    return path;
}
