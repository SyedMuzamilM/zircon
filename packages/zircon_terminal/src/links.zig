//! Logical-line hyperlink & compiler file:line:col detector for terminal cells.

const std = @import("std");
const grid = @import("grid.zig");
const selection = @import("selection.zig");
pub const Kind = enum { url, file };

pub const Link = struct {
    kind: Kind,
    /// Target URL or raw file path (without :line:col suffix). Owned by caller's allocator.
    target: []u8,
    /// 1-based line and column when parsed from a compiler diagnostic path.
    line: ?usize = null,
    column: ?usize = null,
    /// Absolute screen coordinates for hover underline rendering.
    start: selection.Anchor,
    end: selection.Anchor,

    pub fn deinit(self: *Link, a: std.mem.Allocator) void {
        a.free(self.target);
        self.* = undefined;
    }

    pub fn contains(self: Link, abs_line: u64, col: usize) bool {
        const pos: selection.Anchor = .{ .line = abs_line, .col = col };
        return !pos.lt(self.start) and pos.lt(self.end);
    }

    pub fn lineRange(self: Link, abs_line: u64, cols: usize) ?struct { start: usize, end: usize } {
        if (abs_line < self.start.line or abs_line > self.end.line) return null;
        const s = if (abs_line == self.start.line) @min(self.start.col, cols) else 0;
        const e = if (abs_line == self.end.line) @min(self.end.col, cols) else cols;
        if (s >= e) return null;
        return .{ .start = s, .end = e };
    }
};

const CellPos = struct { abs_line: u64, col: usize, width: usize };

/// Detects a URL or file[:line[:col]] under `(abs_line, col)`.
pub fn detectAt(a: std.mem.Allocator, screen: *const grid.Screen, abs_line: u64, col: usize) !?Link {
    if (screen.logicalForAbsLine(abs_line) == null) return null;
    const bounds = selection.logicalLineBounds(screen, abs_line);
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(a);
    var pos_map: std.ArrayList(CellPos) = .empty;
    defer pos_map.deinit(a);

    var target_byte: ?usize = null;
    var cur = bounds.first;
    while (cur <= bounds.last) : (cur += 1) {
        const logical = screen.logicalForAbsLine(cur) orelse return null;
        const row = screen.rowConst(logical);
        const end = row.cells.len - @intFromBool(row.wrapped and row.wrap_padding);
        for (row.cells[0..end], 0..) |cell, c| {
            if (cell.style.wide_trail) continue;
            const width: usize = if (cell.style.wide_lead) 2 else 1;
            if (cur == abs_line and col >= c and col < c + width) target_byte = bytes.items.len;
            if (bytes.items.len >= 64 * 1024) return null;
            var enc: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(cell.code, &enc) catch 0;
            try bytes.appendSlice(a, enc[0..len]);
            for (0..len) |_| try pos_map.append(a, .{ .abs_line = cur, .col = c, .width = width });
        }
    }
    const at = target_byte orelse return null;
    const text = bytes.items;
    if (at >= text.len) return null;
    if (pythonLocation(text, at)) |found| {
        const last = pos_map.items[found.end - 1];
        return .{
            .kind = .file,
            .target = try a.dupe(u8, found.path),
            .line = found.line,
            .start = anchorOf(pos_map.items[found.start]),
            .end = .{ .line = last.abs_line, .col = last.col + last.width },
        };
    }
    if (std.ascii.isWhitespace(text[at])) return null;

    // Expand to whitespace / common quote / bracket delimiters.
    var tok_start = at;
    while (tok_start > 0 and !isDelimiter(text[tok_start - 1])) : (tok_start -= 1) {}
    var tok_end = at + 1;
    while (tok_end < text.len and !isDelimiter(text[tok_end])) : (tok_end += 1) {}

    // Trim leading/trailing punctuation wrappers like (path:10), "url", 'path'.
    while (tok_start < tok_end and isLeadingTrim(text[tok_start])) : (tok_start += 1) {}
    while (tok_end > tok_start and isTrailingTrim(text[tok_end - 1])) : (tok_end -= 1) {}
    if (tok_start >= tok_end or at < tok_start or at >= tok_end) return null;

    const token = text[tok_start..tok_end];
    const start_anchor = anchorOf(pos_map.items[tok_start]);
    const last_cell = pos_map.items[tok_end - 1];
    const end_anchor: selection.Anchor = .{ .line = last_cell.abs_line, .col = last_cell.col + last_cell.width };

    if (std.mem.startsWith(u8, token, "https://") or std.mem.startsWith(u8, token, "http://")) {
        const scheme = std.mem.indexOf(u8, token, "://").?;
        const host = token[scheme + 3 ..];
        if (token.len > 8192 or host.len == 0 or std.mem.indexOfScalar(u8, "/?#", host[0]) != null) return null;
        return .{
            .kind = .url,
            .target = try a.dupe(u8, token),
            .start = start_anchor,
            .end = end_anchor,
        };
    }

    const parsed = parseFileLocation(token) orelse return null;
    const target = if (std.mem.startsWith(u8, parsed.path, "file://"))
        (try decodeFileUri(a, parsed.path)) orelse return null
    else
        try a.dupe(u8, parsed.path);
    return .{
        .kind = .file,
        .target = target,
        .line = parsed.line,
        .column = parsed.column,
        .start = start_anchor,
        .end = end_anchor,
    };
}

fn anchorOf(p: CellPos) selection.Anchor {
    return .{ .line = p.abs_line, .col = p.col };
}

fn isDelimiter(b: u8) bool {
    return std.ascii.isWhitespace(b) or b == '"' or b == '\'' or b == '`' or b == '<' or b == '>' or b == '{' or b == '}';
}

fn isLeadingTrim(b: u8) bool {
    return b == '(' or b == '[' or b == ',' or b == ';';
}

fn isTrailingTrim(b: u8) bool {
    return b == ')' or b == ',' or b == ';' or b == '.' or b == ':';
}

const FileLocation = struct {
    path: []const u8,
    line: ?usize = null,
    column: ?usize = null,
};

fn parseFileLocation(raw: []const u8) ?FileLocation {
    var slice = raw;
    var line: ?usize = null;
    var column: ?usize = null;

    // Strip up to two trailing :number components (path:line:col or path:line).
    if (std.mem.lastIndexOfScalar(u8, slice, ':')) |c2| {
        if (std.fmt.parseInt(usize, slice[c2 + 1 ..], 10)) |n2| {
            const before2 = slice[0..c2];
            if (std.mem.lastIndexOfScalar(u8, before2, ':')) |c1| {
                if (std.fmt.parseInt(usize, before2[c1 + 1 ..], 10)) |n1| {
                    line = n1;
                    column = n2;
                    slice = before2[0..c1];
                } else |_| {
                    line = n2;
                    slice = before2;
                }
            } else {
                line = n2;
                slice = before2;
            }
        } else |_| {}
    }

    if (slice.len == 0 or slice.len > 1024) return null;
    // Heuristic: must contain a path separator or a known extension dot (and not be a bare number/flag).
    if (slice[0] == '-' or (std.mem.indexOf(u8, slice, "://") != null and !std.mem.startsWith(u8, slice, "file://"))) return null;
    if (line == 0 or column == 0) return null;
    const has_slash = std.mem.indexOfScalar(u8, slice, '/') != null;
    const has_ext = if (std.mem.lastIndexOfScalar(u8, slice, '.')) |dot|
        dot > 0 and dot + 1 < slice.len and (slice.len - dot - 1) <= 10 and isAsciiAlphaNum(slice[dot + 1 ..])
    else
        false;
    if (!has_slash and !has_ext) return null;
    return .{ .path = slice, .line = line, .column = column };
}

fn pythonLocation(text: []const u8, at: usize) ?struct { path: []const u8, line: usize, start: usize, end: usize } {
    const opening = std.mem.indexOf(u8, text, "File \"") orelse return null;
    const start = opening + "File \"".len;
    const quote = std.mem.indexOfScalarPos(u8, text, start, '"') orelse return null;
    const suffix = "\", line ";
    if (!std.mem.startsWith(u8, text[quote..], suffix)) return null;
    const number_start = quote + suffix.len;
    var end = number_start;
    while (end < text.len and std.ascii.isDigit(text[end])) : (end += 1) {}
    const line = std.fmt.parseInt(usize, text[number_start..end], 10) catch return null;
    if (line == 0 or at < start or at >= end or quote == start or text[start] == '<') return null;
    return .{ .path = text[start..quote], .line = line, .start = start, .end = end };
}

fn decodeFileUri(a: std.mem.Allocator, uri: []const u8) !?[]u8 {
    var encoded = uri["file://".len..];
    if (std.mem.startsWith(u8, encoded, "localhost/")) encoded = encoded["localhost".len..];
    if (encoded.len == 0 or encoded[0] != '/') return null;
    var path: std.ArrayList(u8) = .empty;
    defer path.deinit(a);
    var i: usize = 0;
    while (i < encoded.len) : (i += 1) {
        const raw = encoded[i];
        if (raw == '?' or raw == '#') return null;
        const byte = if (raw == '%') blk: {
            if (i + 2 >= encoded.len) return null;
            const value = std.fmt.parseInt(u8, encoded[i + 1 .. i + 3], 16) catch return null;
            i += 2;
            break :blk value;
        } else raw;
        if (byte == 0) return null;
        try path.append(a, byte);
    }
    if (!std.unicode.utf8ValidateSlice(path.items)) return null;
    return try path.toOwnedSlice(a);
}

fn isAsciiAlphaNum(bytes: []const u8) bool {
    for (bytes) |b| if (!std.ascii.isAlphanumeric(b)) return false;
    return bytes.len > 0;
}
