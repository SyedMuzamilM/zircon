//! A bounded Markdown block parser. Document owns one arena and a copied source;
//! all block/inline/table values remain valid until Document.deinit.
const std = @import("std");
const types = @import("types.zig");
const inline_parser = @import("inline.zig");
const Line = struct { start: usize, end: usize, after: usize };
pub const Document = struct {
    arena: std.heap.ArenaAllocator,
    source: []const u8,
    blocks: []const types.Block,
    pub fn deinit(self: *Document) void {
        self.arena.deinit();
        self.* = undefined;
    }
};
pub fn parse(a: std.mem.Allocator, bytes: []const u8) !Document {
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
    if (bytes.len > 16 * 1024 * 1024) return error.MarkdownTooLarge;
    var arena = std.heap.ArenaAllocator.init(a);
    errdefer arena.deinit();
    const al = arena.allocator();
    const source = try al.dupe(u8, bytes);
    var lines: std.ArrayList(Line) = .empty;
    var position: usize = 0;
    while (position < source.len) {
        const lf = std.mem.indexOfScalarPos(u8, source, position, '\n') orelse source.len;
        const end = if (lf > position and source[lf - 1] == '\r') lf - 1 else lf;
        try lines.append(al, .{ .start = position, .end = end, .after = @min(source.len, lf + 1) });
        position = @min(source.len, lf + 1);
    }
    var blocks: std.ArrayList(types.Block) = .empty;
    var i: usize = 0;
    while (i < lines.items.len) {
        const line = lines.items[i];
        const content = source[line.start..line.end];
        if (blank(content)) {
            i += 1;
            continue;
        }
        if (fence(content)) |opening| {
            const first = i;
            i += 1;
            const body_start = line.after;
            while (i < lines.items.len and !closes(source[lines.items[i].start..lines.items[i].end], opening)) : (i += 1) {}
            const body_end = if (i < lines.items.len) lines.items[i].start else source.len;
            const after = if (i < lines.items.len) lines.items[i].after else source.len;
            try blocks.append(al, .{ .kind = .code, .source = .{ .start = lines.items[first].start, .end = after }, .content = source[body_start..body_end], .info = opening.info });
            if (i < lines.items.len) i += 1;
            continue;
        }
        if (heading(content)) |h| {
            try blocks.append(al, try textBlock(al, source, .heading, line.start + h.start, line.start + h.end, .{ .start = line.start, .end = line.after }, h.level, false, 1));
            i += 1;
            continue;
        }
        if (i + 1 < lines.items.len) if (setext(source[lines.items[i + 1].start..lines.items[i + 1].end])) |level| {
            try blocks.append(al, try textBlock(al, source, .heading, line.start, line.end, .{ .start = line.start, .end = lines.items[i + 1].after }, level, false, 1));
            i += 2;
            continue;
        };
        if (rule(content)) {
            try blocks.append(al, .{ .kind = .rule, .source = .{ .start = line.start, .end = line.after } });
            i += 1;
            continue;
        }
        if (i + 1 < lines.items.len and std.mem.indexOfScalar(u8, content, '|') != null) {
            const delimiter_line = lines.items[i + 1];
            if (try alignments(al, source[delimiter_line.start..delimiter_line.end])) |alignment| {
                var rows: std.ArrayList(types.Row) = .empty;
                try rows.append(al, try tableRow(al, source, line));
                const first = i;
                i += 2;
                while (i < lines.items.len and !blank(source[lines.items[i].start..lines.items[i].end]) and std.mem.indexOfScalar(u8, source[lines.items[i].start..lines.items[i].end], '|') != null) : (i += 1) try rows.append(al, try tableRow(al, source, lines.items[i]));
                try blocks.append(al, .{ .kind = .table, .source = .{ .start = lines.items[first].start, .end = lines.items[i - 1].after }, .table = .{ .rows = rows.items, .alignments = alignment } });
                continue;
            }
        }
        if (listItem(content)) |item| {
            try blocks.append(al, try textBlock(al, source, .list_item, line.start + item.start, line.end, .{ .start = line.start, .end = line.after }, item.level, item.ordered, item.number));
            i += 1;
            continue;
        }
        const left = std.mem.trimStart(u8, content, " ");
        if (left.len > 0 and left[0] == '>') {
            var skip = content.len - left.len + 1;
            if (skip < content.len and content[skip] == ' ') skip += 1;
            try blocks.append(al, try textBlock(al, source, .quote, line.start + skip, line.end, .{ .start = line.start, .end = line.after }, 1, false, 1));
            i += 1;
            continue;
        }
        const start = i;
        i += 1;
        while (i < lines.items.len) : (i += 1) {
            const next = source[lines.items[i].start..lines.items[i].end];
            if (blank(next) or startsBlock(next)) break;
            if (i + 1 < lines.items.len and (setext(source[lines.items[i + 1].start..lines.items[i + 1].end]) != null or std.mem.indexOfScalar(u8, next, '|') != null)) break;
        }
        try blocks.append(al, try textBlock(al, source, .paragraph, lines.items[start].start, lines.items[i - 1].end, .{ .start = lines.items[start].start, .end = lines.items[i - 1].after }, 0, false, 1));
    }
    return .{ .arena = arena, .source = source, .blocks = blocks.items };
}
fn textBlock(a: std.mem.Allocator, source: []const u8, kind: @FieldType(types.Block, "kind"), start: usize, end: usize, range: types.Range, level: u8, ordered: bool, number: usize) !types.Block {
    return .{ .kind = kind, .source = range, .content = source[start..end], .inlines = try inline_parser.parse(a, source, start, end), .level = level, .ordered = ordered, .number = number };
}
fn blank(value: []const u8) bool {
    return std.mem.trim(u8, value, " \t\r").len == 0;
}
fn startsBlock(value: []const u8) bool {
    const left = std.mem.trimStart(u8, value, " ");
    return heading(value) != null or fence(value) != null or rule(value) or listItem(value) != null or (left.len > 0 and left[0] == '>');
}
const Fence = struct { char: u8, count: usize, info: []const u8 };
fn fence(value: []const u8) ?Fence {
    const left = std.mem.trimStart(u8, value, " ");
    if (value.len - left.len > 3 or left.len < 3 or (left[0] != '`' and left[0] != '~')) return null;
    var count: usize = 1;
    while (count < left.len and left[count] == left[0]) : (count += 1) {}
    if (count < 3) return null;
    return .{ .char = left[0], .count = count, .info = std.mem.trim(u8, left[count..], " \t") };
}
fn closes(value: []const u8, opening: Fence) bool {
    const found = fence(value) orelse return false;
    return found.char == opening.char and found.count >= opening.count and found.info.len == 0;
}
const Heading = struct { start: usize, end: usize, level: u8 };
fn heading(value: []const u8) ?Heading {
    const left = std.mem.trimStart(u8, value, " ");
    if (value.len - left.len > 3 or left.len == 0 or left[0] != '#') return null;
    var count: usize = 0;
    while (count < left.len and left[count] == '#') : (count += 1) {}
    if (count > 6 or (count < left.len and left[count] != ' ' and left[count] != '\t')) return null;
    const start = value.len - left.len + count;
    var content_end = value.len;
    while (content_end > start and (value[content_end - 1] == ' ' or value[content_end - 1] == '\t')) content_end -= 1;
    var hashes = content_end;
    while (hashes > start and value[hashes - 1] == '#') hashes -= 1;
    if (hashes < content_end and hashes > start and (value[hashes - 1] == ' ' or value[hashes - 1] == '\t')) content_end = hashes - 1;
    var content_start = start;
    while (content_start < content_end and (value[content_start] == ' ' or value[content_start] == '\t')) content_start += 1;
    return .{ .start = content_start, .end = content_end, .level = @intCast(count) };
}
fn setext(value: []const u8) ?u8 {
    const trimmed = std.mem.trim(u8, value, " \t");
    if (trimmed.len == 0 or (trimmed[0] != '=' and trimmed[0] != '-')) return null;
    for (trimmed) |byte| if (byte != trimmed[0]) return null;
    return if (trimmed[0] == '=') 1 else 2;
}
fn rule(value: []const u8) bool {
    var marker: ?u8 = null;
    var count: usize = 0;
    for (value) |byte| {
        if (byte == ' ' or byte == '\t') continue;
        if (byte != '-' and byte != '*' and byte != '_') return false;
        if (marker) |m| {
            if (m != byte) return false;
        } else marker = byte;
        count += 1;
    }
    return count >= 3;
}
const ListItem = struct { start: usize, level: u8, ordered: bool = false, number: usize = 1 };
fn listItem(value: []const u8) ?ListItem {
    const left = std.mem.trimStart(u8, value, " ");
    const indentation = value.len - left.len;
    if (left.len < 2) return null;
    if ((left[0] == '-' or left[0] == '*' or left[0] == '+') and (left[1] == ' ' or left[1] == '\t')) return .{ .start = indentation + 2, .level = @intCast(@min(32, indentation / 2)) };
    var digits: usize = 0;
    while (digits < left.len and std.ascii.isDigit(left[digits])) : (digits += 1) {}
    if (digits == 0 or digits > 9 or digits + 1 >= left.len or (left[digits] != '.' and left[digits] != ')') or left[digits + 1] != ' ') return null;
    return .{ .start = indentation + digits + 2, .level = @intCast(@min(32, indentation / 2)), .ordered = true, .number = std.fmt.parseInt(usize, left[0..digits], 10) catch return null };
}
fn cells(a: std.mem.Allocator, value: []const u8, base: usize) ![]const types.Range {
    var result: std.ArrayList(types.Range) = .empty;
    var start: usize = 0;
    var end = value.len;
    while (start < end and (value[start] == ' ' or value[start] == '\t')) : (start += 1) {}
    while (end > start and (value[end - 1] == ' ' or value[end - 1] == '\t')) : (end -= 1) {}
    if (start < end and value[start] == '|') start += 1;
    if (end > start and value[end - 1] == '|' and (end < 2 or value[end - 2] != '\\')) end -= 1;
    var cursor = start;
    var code: bool = false;
    for (value[start..end], start..) |byte, i| {
        if (byte == '`' and (i == 0 or value[i - 1] != '\\')) code = !code;
        if (byte == '|' and !code and (i == 0 or value[i - 1] != '\\')) {
            const raw = value[cursor..i];
            const trimmed = std.mem.trim(u8, raw, " \t");
            const offset = cursor + raw.len - std.mem.trimStart(u8, raw, " \t").len;
            try result.append(a, .{ .start = base + offset, .end = base + offset + trimmed.len });
            cursor = i + 1;
        }
    }
    const raw = value[cursor..end];
    const trimmed = std.mem.trim(u8, raw, " \t");
    const offset = cursor + raw.len - std.mem.trimStart(u8, raw, " \t").len;
    try result.append(a, .{ .start = base + offset, .end = base + offset + trimmed.len });
    return result.items;
}
fn alignments(a: std.mem.Allocator, value: []const u8) !?[]const types.Alignment {
    const ranges = try cells(a, value, 0);
    if (ranges.len == 0) return null;
    const result = try a.alloc(types.Alignment, ranges.len);
    for (ranges, 0..) |range, i| {
        const cell = value[range.start..range.end];
        const body = std.mem.trim(u8, cell, ":");
        if (body.len < 3) return null;
        for (body) |byte| if (byte != '-') return null;
        result[i] = if (cell[0] == ':' and cell[cell.len - 1] == ':') .center else if (cell[cell.len - 1] == ':') .end else .start;
    }
    return result;
}
fn tableRow(a: std.mem.Allocator, source: []const u8, line: Line) !types.Row {
    const ranges = try cells(a, source[line.start..line.end], line.start);
    const output = try a.alloc(types.Cell, ranges.len);
    for (ranges, 0..) |range, i| output[i] = .{ .source = range, .content = try inline_parser.parse(a, source, range.start, range.end) };
    return .{ .source = .{ .start = line.start, .end = line.after }, .cells = output };
}
