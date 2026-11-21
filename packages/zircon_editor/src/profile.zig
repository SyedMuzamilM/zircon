//! Declarative lexical profiles supplied by the host's installed contributions.
//! Profiles are immutable; callers keep their generation alive. Frame copies
//! own every string, so registry activation cannot invalidate a committed UI.
const std = @import("std");
const syntax = @import("syntax.zig");
pub const Block = struct { start: []const u8, end: []const u8, nested: bool = false };
pub const Profile = struct {
    keywords: []const []const u8,
    line_comment: ?[]const u8 = null,
    block_comment: ?Block = null,
    string_delimiters: []const u8 = "\"'",
    pub fn copy(value: Profile, a: std.mem.Allocator) !Profile {
        const keywords = try a.alloc([]const u8, value.keywords.len);
        for (value.keywords, 0..) |keyword, i| keywords[i] = try a.dupe(u8, keyword);
        return .{ .keywords = keywords, .line_comment = if (value.line_comment) |s| try a.dupe(u8, s) else null, .block_comment = if (value.block_comment) |b| .{ .start = try a.dupe(u8, b.start), .end = try a.dupe(u8, b.end), .nested = b.nested } else null, .string_delimiters = try a.dupe(u8, value.string_delimiters) };
    }
};
pub fn lex(a: std.mem.Allocator, bytes: []const u8, profile: Profile, initial: syntax.State) !syntax.Lexed {
    return scan(a, bytes, profile, initial, true);
}

pub fn endState(bytes: []const u8, profile: Profile, initial: syntax.State) !syntax.State {
    return (try scan(std.heap.page_allocator, bytes, profile, initial, false)).state;
}

fn scan(a: std.mem.Allocator, bytes: []const u8, profile: Profile, initial: syntax.State, comptime collect: bool) !syntax.Lexed {
    var state = initial;
    var spans: std.ArrayList(syntax.Span) = .empty;
    var i: usize = 0;
    while (i < bytes.len) {
        const start = i;
        var kind: syntax.Kind = .plain;
        if (state.comment_depth > 0) {
            kind = .comment;
            while (i < bytes.len) {
                if (profile.block_comment) |block| {
                    if (std.mem.startsWith(u8, bytes[i..], block.end)) {
                        state.comment_depth -= 1;
                        i += block.end.len;
                        if (state.comment_depth == 0) break;
                        continue;
                    }
                    if (block.nested and std.mem.startsWith(u8, bytes[i..], block.start)) {
                        state.comment_depth += 1;
                        i += block.start.len;
                        continue;
                    }
                }
                i += 1;
            }
        } else if (profile.line_comment != null and std.mem.startsWith(u8, bytes[i..], profile.line_comment.?)) {
            kind = .comment;
            i = bytes.len;
        } else if (profile.block_comment != null and std.mem.startsWith(u8, bytes[i..], profile.block_comment.?.start)) {
            kind = .comment;
            state.comment_depth = 1;
            i += profile.block_comment.?.start.len;
        } else if (std.mem.indexOfScalar(u8, profile.string_delimiters, bytes[i]) != null) {
            kind = .string;
            const quote = bytes[i];
            i += 1;
            while (i < bytes.len) {
                if (bytes[i] == '\\') {
                    i = @min(bytes.len, i + 2);
                    continue;
                }
                if (bytes[i] == quote) {
                    i += 1;
                    break;
                }
                i += 1;
            }
        } else if (std.ascii.isDigit(bytes[i])) {
            kind = .number;
            i += 1;
            while (i < bytes.len and (std.ascii.isAlphanumeric(bytes[i]) or bytes[i] == '.' or bytes[i] == '_')) : (i += 1) {}
        } else if (std.ascii.isAlphabetic(bytes[i]) or bytes[i] == '_') {
            i += 1;
            while (i < bytes.len and (std.ascii.isAlphanumeric(bytes[i]) or bytes[i] == '_')) : (i += 1) {}
            if (collect) for (profile.keywords) |word| if (std.mem.eql(u8, bytes[start..i], word)) {
                kind = .keyword;
                break;
            };
        } else {
            i += 1;
            while (i < bytes.len and bytes[i] & 0xc0 == 0x80) : (i += 1) {}
            if (collect and !std.ascii.isWhitespace(bytes[start])) kind = .punctuation;
        }
        if (collect and kind != .plain) try spans.append(a, .{ .start = start, .end = i, .kind = kind });
    }
    return .{ .spans = spans.items, .state = state };
}
