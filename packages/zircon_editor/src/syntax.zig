//! Deterministic lexical highlighting. This is not a parser or semantic token
//! service. Cached line-start states handle multiline comments without scanning
//! earlier lines during paint. Oversized lines fall back to plain text.
const std = @import("std");
const text = @import("zircon_text");
pub const Language = enum { plain, zig, rust, json, markdown };
pub const Kind = enum { plain, keyword, string, number, comment, punctuation, builtin };
pub const Span = struct { start: usize, end: usize, kind: Kind };
pub const State = struct { comment_depth: usize = 0 };
pub const Lexed = struct { spans: []const Span, state: State };
pub fn languageForPath(path: []const u8) Language {
    const ext = std.fs.path.extension(path);
    if (std.mem.eql(u8, ext, ".zig")) return .zig;
    if (std.mem.eql(u8, ext, ".rs")) return .rust;
    if (std.mem.eql(u8, ext, ".json")) return .json;
    if (std.mem.eql(u8, ext, ".md")) return .markdown;
    return .plain;
}
pub fn lex(a: std.mem.Allocator, bytes: []const u8, language: Language, initial: State) !Lexed {
    var spans: std.ArrayList(Span) = .empty;
    var state = initial;
    if (language == .plain) return .{ .spans = &.{}, .state = .{} };
    if (language == .markdown and std.mem.startsWith(u8, std.mem.trimStart(u8, bytes, " \t"), "#")) {
        try spans.append(a, .{ .start = 0, .end = bytes.len, .kind = .keyword });
        return .{ .spans = spans.items, .state = state };
    }
    var i: usize = 0;
    while (i < bytes.len) {
        const start = i;
        var kind: Kind = .plain;
        if (state.comment_depth > 0) {
            while (i < bytes.len) {
                if (i + 1 < bytes.len and bytes[i] == '*' and bytes[i + 1] == '/') {
                    state.comment_depth -= 1;
                    i += 2;
                    if (state.comment_depth == 0) break;
                } else if (language == .rust and i + 1 < bytes.len and bytes[i] == '/' and bytes[i + 1] == '*') {
                    state.comment_depth += 1;
                    i += 2;
                } else i += 1;
            }
            kind = .comment;
        } else if ((language == .zig or language == .rust) and i + 1 < bytes.len and bytes[i] == '/' and bytes[i + 1] == '/') {
            i = bytes.len;
            kind = .comment;
        } else if (language == .rust and i + 1 < bytes.len and bytes[i] == '/' and bytes[i + 1] == '*') {
            state.comment_depth = 1;
            try spans.append(a, .{ .start = i, .end = i + 2, .kind = .comment });
            i += 2;
            continue;
        } else if (language == .zig and i + 1 < bytes.len and bytes[i] == '\\' and bytes[i + 1] == '\\') {
            i = bytes.len;
            kind = .string;
        } else if (bytes[i] == '"' or (language == .markdown and bytes[i] == '`') or ((language == .zig or language == .rust) and bytes[i] == '\'')) {
            const quote = bytes[i];
            i += 1;
            while (i < bytes.len) {
                const value = bytes[i];
                i += 1;
                if (value == '\\' and i < bytes.len) i += 1 else if (value == quote) break;
            }
            kind = .string;
        } else if (std.ascii.isDigit(bytes[i])) {
            i += 1;
            while (i < bytes.len and (std.ascii.isAlphanumeric(bytes[i]) or bytes[i] == '.' or bytes[i] == '_')) : (i += 1) {}
            kind = .number;
        } else if (std.ascii.isAlphabetic(bytes[i]) or bytes[i] == '_' or bytes[i] == '@') {
            i += 1;
            while (i < bytes.len and (std.ascii.isAlphanumeric(bytes[i]) or bytes[i] == '_')) : (i += 1) {}
            const word = bytes[start..i];
            kind = if (bytes[start] == '@') .builtin else if (keyword(word)) .keyword else .plain;
        } else {
            i += 1;
            if (std.mem.indexOfScalar(u8, "{}[]().,:;=+-*/!<>?&|%", bytes[start]) != null) kind = .punctuation;
        }
        if (kind != .plain) try spans.append(a, .{ .start = start, .end = i, .kind = kind });
    }
    return .{ .spans = spans.items, .state = state };
}
fn keyword(word: []const u8) bool {
    const words = " const var pub fn return try catch defer errdefer if else while for switch break continue struct enum union opaque error comptime inline extern export usingnamespace test true false null undefined async await let mut impl trait use mod match self Self unsafe loop where move ref static crate super as in is and or orelse unreachable nosuspend suspend anytype anyerror type void bool u8 usize ";
    var iterator = std.mem.tokenizeScalar(u8, words, ' ');
    while (iterator.next()) |item| if (std.mem.eql(u8, item, word)) return true;
    return false;
}
pub const Cache = struct {
    allocator: std.mem.Allocator,
    states: std.ArrayList(State) = .empty,
    revision: ?u64 = null,
    language: Language = .plain,
    pub fn init(a: std.mem.Allocator) Cache {
        return .{ .allocator = a };
    }
    pub fn deinit(self: *Cache) void {
        self.states.deinit(self.allocator);
    }
    pub fn clear(self: *Cache) void {
        self.states.clearRetainingCapacity();
        self.revision = null;
    }
    pub fn refresh(self: *Cache, snapshot: text.Snapshot, language: Language, first_row: usize) !void {
        const old_len = self.states.items.len;
        const can_converge = self.revision != null and self.language == language and old_len == snapshot.lineCount() + 1;
        var row = if (self.revision != null and self.language == language) @min(first_row, old_len) else 0;
        try self.states.resize(self.allocator, snapshot.lineCount() + 1);
        if (row == 0) self.states.items[0] = .{};
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        while (row < snapshot.lineCount()) : (row += 1) {
            const range = try snapshot.lineRange(row);
            var next: State = .{};
            if (range.end - range.start <= 64 * 1024) {
                const line = try snapshot.copy(arena.allocator(), range);
                next = (try lex(arena.allocator(), line, language, self.states.items[row])).state;
            }
            const converged = can_converge and row + 1 < old_len and std.meta.eql(self.states.items[row + 1], next);
            self.states.items[row + 1] = next;
            _ = arena.reset(.retain_capacity);
            if (converged and old_len == snapshot.lineCount() + 1 and row >= first_row) break;
        }
        self.language = language;
        self.revision = snapshot.revision();
    }
    pub fn state(self: *const Cache, snapshot: text.Snapshot, row: usize) ?State {
        if (self.revision != snapshot.revision() or row >= self.states.items.len) return null;
        return self.states.items[row];
    }
};
