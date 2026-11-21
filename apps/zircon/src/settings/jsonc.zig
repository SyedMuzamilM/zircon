//! Replace comments and trailing commas with whitespace so JSON token boundaries
//! and diagnostic line positions survive preprocessing.

const std = @import("std");
pub fn strip(a: std.mem.Allocator, raw: []const u8) ![]u8 {
    const input = if (std.mem.startsWith(u8, raw, "\xef\xbb\xbf")) raw[3..] else raw;
    const out = try a.dupe(u8, input);
    errdefer a.free(out);

    var i: usize = 0;
    var previous: u8 = 0;
    var depth: usize = 0;
    var trailing_comma: ?usize = null;
    while (i < input.len) {
        const c = input[i];
        if (c == '/' and i + 1 < input.len) switch (input[i + 1]) {
            '/' => {
                const start = i;
                i += 2;
                while (i < input.len and input[i] != '\n' and input[i] != '\r') : (i += 1) {}
                @memset(out[start..i], ' ');
                continue;
            },
            '*' => {
                out[i..][0..2].* = "  ".*;
                i += 2;
                while (i + 1 < input.len and !(input[i] == '*' and input[i + 1] == '/')) : (i += 1) {
                    if (input[i] != '\n' and input[i] != '\r') out[i] = ' ';
                }
                if (i + 1 >= input.len) return error.UnterminatedComment;
                out[i..][0..2].* = "  ".*;
                i += 2;
                continue;
            },
            else => {},
        };
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
            i += 1;
            continue;
        }
        if (c == '{' or c == '[') {
            depth += 1;
            // Settings are serialized again when a preference changes.
            if (depth > 256) return error.SettingsTooDeep;
        } else if (c == '}' or c == ']') {
            depth -|= 1;
            if (trailing_comma) |comma| out[comma] = ' ';
        }
        trailing_comma = if (c == ',' and previous != 0 and previous != '[' and previous != '{' and previous != ',') i else null;
        previous = c;
        i += 1;
        if (c == '"') {
            while (i < input.len) {
                const ch = input[i];
                i += 1;
                if (ch == '"') break;
                if (ch == '\\' and i < input.len) i += 1;
            }
        }
    }
    return out;
}
