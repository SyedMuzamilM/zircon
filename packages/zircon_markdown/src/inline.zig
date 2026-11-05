//! Inline parsing flattens nested emphasis into style flags while retaining
//! original source ranges. Unmatched delimiters remain literal text.
const std = @import("std");
const types = @import("types.zig");
const Flags = struct { strong: bool = false, emphasis: bool = false };
pub fn parse(a: std.mem.Allocator, source: []const u8, start: usize, end: usize) ![]const types.Inline {
    var spans: std.ArrayList(types.Inline) = .empty;
    try scan(a, source, start, end, .{}, 0, &spans);
    return spans.items;
}
fn emit(a: std.mem.Allocator, list: *std.ArrayList(types.Inline), source: []const u8, start: usize, end: usize, flags: Flags) !void {
    if (start == end) return;
    try list.append(a, .{ .source = .{ .start = start, .end = end }, .text = source[start..end], .strong = flags.strong, .emphasis = flags.emphasis });
}
fn scan(a: std.mem.Allocator, source: []const u8, begin: usize, end: usize, flags: Flags, depth: usize, out: *std.ArrayList(types.Inline)) anyerror!void {
    if (depth > 24) return emit(a, out, source, begin, end, flags);
    var i = begin;
    var plain = i;
    while (i < end) {
        if (source[i] == '\\' and i + 1 < end and std.ascii.isPunctuation(source[i + 1])) {
            try emit(a, out, source, plain, i, flags);
            try out.append(a, .{ .source = .{ .start = i, .end = i + 2 }, .text = source[i + 1 .. i + 2], .strong = flags.strong, .emphasis = flags.emphasis });
            i += 2;
            plain = i;
            continue;
        }
        if (source[i] == '`') {
            var n: usize = 1;
            while (i + n < end and source[i + n] == '`') : (n += 1) {}
            const close = findDelimiter(source, i + n, end, source[i .. i + n]);
            if (close) |last| {
                try emit(a, out, source, plain, i, flags);
                var code = source[i + n .. last];
                if (code.len >= 2 and code[0] == ' ' and code[code.len - 1] == ' ' and std.mem.trim(u8, code, " ").len > 0) code = code[1 .. code.len - 1];
                const normalized = try a.dupe(u8, code);
                for (normalized) |*byte| if (byte.* == '\n' or byte.* == '\r') {
                    byte.* = ' ';
                };
                try out.append(a, .{ .kind = .code, .source = .{ .start = i, .end = last + n }, .text = normalized, .strong = flags.strong, .emphasis = flags.emphasis });
                i = last + n;
                plain = i;
                continue;
            }
        }
        const image = source[i] == '!' and i + 1 < end and source[i + 1] == '[';
        const open = if (image) i + 1 else i;
        if (source[open] == '[') {
            if (std.mem.indexOfScalarPos(u8, source[0..end], open + 1, ']')) |label_end| {
                if (label_end + 1 < end and source[label_end + 1] == '(') {
                    if (targetEnd(source, label_end + 2, end)) |last| {
                        const raw = std.mem.trim(u8, source[label_end + 2 .. last], " \t\r\n");
                        const target = if (raw.len >= 2 and raw[0] == '<' and raw[raw.len - 1] == '>') raw[1 .. raw.len - 1] else raw;
                        if (target.len > 0) {
                            try emit(a, out, source, plain, i, flags);
                            try out.append(a, .{ .kind = if (image) .image else .link, .source = .{ .start = i, .end = last + 1 }, .text = source[open + 1 .. label_end], .target = target, .strong = flags.strong, .emphasis = flags.emphasis });
                            i = last + 1;
                            plain = i;
                            continue;
                        }
                    }
                }
            }
        }
        if (source[i] == '*' or source[i] == '_') {
            var count: usize = 1;
            if (i + 1 < end and source[i + 1] == source[i]) count = 2;
            const valid_start = i + count < end and !std.ascii.isWhitespace(source[i + count]) and !(source[i] == '_' and i > begin and std.ascii.isAlphanumeric(source[i - 1]));
            if (valid_start) if (findDelimiter(source, i + count, end, source[i .. i + count])) |last| {
                if (last > i + count and !std.ascii.isWhitespace(source[last - 1])) {
                    try emit(a, out, source, plain, i, flags);
                    var nested = flags;
                    if (count == 2) nested.strong = true else nested.emphasis = true;
                    try scan(a, source, i + count, last, nested, depth + 1, out);
                    i = last + count;
                    plain = i;
                    continue;
                }
            };
        }
        i += 1;
    }
    try emit(a, out, source, plain, end, flags);
}
fn findDelimiter(source: []const u8, start: usize, end: usize, delimiter: []const u8) ?usize {
    var cursor = start;
    while (std.mem.indexOfPos(u8, source[0..end], cursor, delimiter)) |at| {
        if (at == 0 or source[at - 1] != '\\') return at;
        cursor = at + delimiter.len;
    }
    return null;
}
fn targetEnd(source: []const u8, start: usize, end: usize) ?usize {
    var depth: usize = 0;
    var i = start;
    while (i < end) : (i += 1) {
        if (source[i] == '\\' and i + 1 < end) {
            i += 1;
            continue;
        }
        if (source[i] == '(') depth += 1;
        if (source[i] == ')') {
            if (depth == 0) return i;
            depth -= 1;
        }
    }
    return null;
}
