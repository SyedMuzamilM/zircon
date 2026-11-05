//! Immutable contribution values. Strings and image bytes belong to a retained
//! registry Snapshot, so consumers must keep that snapshot while borrowing them.
const std = @import("std");
pub const Color = struct {
    rgba: u32,
    pub fn parse(bytes: []const u8) !Color {
        if (bytes.len != 7 and bytes.len != 9) return error.InvalidColor;
        if (bytes[0] != '#') return error.InvalidColor;
        const rgb = std.fmt.parseInt(u32, bytes[1..], 16) catch return error.InvalidColor;
        return .{ .rgba = if (bytes.len == 7) (rgb << 8) | 255 else rgb };
    }
};
pub const Colors = struct { document: Color, chrome: Color, sidebar: Color, panel: Color, line: Color, text: Color, muted: Color, accent: Color, selected: Color, warning: Color, primary: Color };
pub const SyntaxColors = struct { plain: Color, keyword: Color, string: Color, number: Color, comment: Color, punctuation: Color, builtin: Color };
pub const Theme = struct { id: []const u8, name: []const u8, colors: Colors, syntax: SyntaxColors };
pub const Asset = struct { path: []const u8, bytes: []const u8 };
pub const Icon = union(enum) { symbol: []const u8, png: Asset };
pub const IconMapping = struct { key: []const u8, icon: Icon };
pub const IconTheme = struct {
    id: []const u8,
    name: []const u8,
    files: []const IconMapping,
    extensions: []const IconMapping,
    folders: []const IconMapping,
    default_file: Icon,
    default_folder: Icon,
    pub fn resolve(theme: *const IconTheme, path: []const u8, directory: bool) Icon {
        const name = std.fs.path.basename(path);
        for (if (directory) theme.folders else theme.files) |mapping| if (std.mem.eql(u8, mapping.key, name)) return mapping.icon;
        if (!directory) {
            const extension = std.mem.trimStart(u8, std.fs.path.extension(name), ".");
            for (theme.extensions) |mapping| if (std.ascii.eqlIgnoreCase(std.mem.trimStart(u8, mapping.key, "."), extension)) return mapping.icon;
        }
        return if (directory) theme.default_folder else theme.default_file;
    }
};
pub const BlockComment = struct { start: []const u8, end: []const u8, nested: bool = false };
pub const Language = struct {
    id: []const u8,
    name: []const u8,
    extensions: []const []const u8,
    filenames: []const []const u8,
    keywords: []const []const u8,
    line_comment: ?[]const u8,
    block_comment: ?BlockComment,
    string_delimiters: []const u8,
    pub fn matches(language: *const Language, path: []const u8) bool {
        const name = std.fs.path.basename(path);
        for (language.filenames) |filename| if (std.mem.eql(u8, filename, name)) return true;
        const extension = std.mem.trimStart(u8, std.fs.path.extension(name), ".");
        for (language.extensions) |candidate| if (std.ascii.eqlIgnoreCase(extension, std.mem.trimStart(u8, candidate, "."))) return true;
        return false;
    }
};
pub const Server = struct { id: []const u8, languages: []const []const u8, command: []const u8, args: []const []const u8 };
pub const Extension = struct {
    id: []const u8,
    name: []const u8,
    version: []const u8,
    description: []const u8,
    enabled: bool,
    themes: []const Theme,
    icon_themes: []const IconTheme,
    languages: []const Language,
    language_servers: []const Server,
};
