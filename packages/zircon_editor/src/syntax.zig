//! Deterministic lexical highlighting. This is not a parser or semantic token
//! service. Cached line-start states handle multiline comments without scanning
//! earlier lines during paint. Oversized lines fall back to plain text.
const std = @import("std");
const text = @import("zircon_text");
const profile_module = @import("profile.zig");
pub const Language = enum { plain, zig, rust, json, markdown, custom };
pub const Kind = enum { plain, keyword, string, number, comment, punctuation, builtin };
pub const Span = struct { start: usize, end: usize, kind: Kind };
/// Enumerates adjacent, same-kind runs and plain gaps within a visible range.
/// Spans are ordered and nonoverlapping, as emitted by the lexers.
pub const Runs = struct {
    spans: []const Span,
    offset: usize,
    end: usize,

    pub fn init(spans: []const Span, start: usize, end: usize) Runs {
        var first: usize = 0;
        if (start > 0) {
            var limit = spans.len;
            while (first < limit) {
                const mid = first + (limit - first) / 2;
                if (spans[mid].end <= start) first = mid + 1 else limit = mid;
            }
        }
        return .{ .spans = spans[first..], .offset = start, .end = end };
    }

    pub fn next(self: *Runs) ?Span {
        if (self.offset >= self.end) return null;
        const start = self.offset;
        while (self.spans.len > 0 and self.spans[0].end <= start) self.spans = self.spans[1..];
        if (self.spans.len == 0 or self.spans[0].start > start) {
            self.offset = if (self.spans.len == 0) self.end else @min(self.end, self.spans[0].start);
            return .{ .start = start, .end = self.offset, .kind = .plain };
        }
        const first = self.spans[0];
        self.spans = self.spans[1..];
        self.offset = @min(self.end, first.end);
        while (self.offset < self.end and self.spans.len > 0) {
            const span = self.spans[0];
            if (span.start != self.offset or span.kind != first.kind) break;
            self.offset = @min(self.end, span.end);
            self.spans = self.spans[1..];
        }
        return .{ .start = start, .end = self.offset, .kind = first.kind };
    }
};
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
    return scan(a, bytes, language, initial, true);
}

fn scan(a: std.mem.Allocator, bytes: []const u8, language: Language, initial: State, comptime collect: bool) !Lexed {
    var spans: std.ArrayList(Span) = .empty;
    var state = initial;
    if (language == .plain) return .{ .spans = &.{}, .state = .{} };
    if (language == .markdown and std.mem.startsWith(u8, std.mem.trimStart(u8, bytes, " \t"), "#")) {
        if (collect) try spans.append(a, .{ .start = 0, .end = bytes.len, .kind = .keyword });
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
            if (collect) try spans.append(a, .{ .start = i, .end = i + 2, .kind = .comment });
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
            if (collect) kind = if (bytes[start] == '@') .builtin else if (keywords.has(bytes[start..i])) .keyword else .plain;
        } else {
            i += 1;
            if (collect and std.mem.indexOfScalar(u8, "{}[]().,:;=+-*/!<>?&|%", bytes[start]) != null) kind = .punctuation;
        }
        if (collect and kind != .plain) try spans.append(a, .{ .start = start, .end = i, .kind = kind });
    }
    return .{ .spans = spans.items, .state = state };
}
const keywords = std.StaticStringMap(void).initComptime(.{
    .{ "const", {} },     .{ "var", {} },            .{ "pub", {} },         .{ "fn", {} },        .{ "return", {} },  .{ "try", {} },
    .{ "catch", {} },     .{ "defer", {} },          .{ "errdefer", {} },    .{ "if", {} },        .{ "else", {} },    .{ "while", {} },
    .{ "for", {} },       .{ "switch", {} },         .{ "break", {} },       .{ "continue", {} },  .{ "struct", {} },  .{ "enum", {} },
    .{ "union", {} },     .{ "opaque", {} },         .{ "error", {} },       .{ "comptime", {} },  .{ "inline", {} },  .{ "extern", {} },
    .{ "export", {} },    .{ "usingnamespace", {} }, .{ "test", {} },        .{ "true", {} },      .{ "false", {} },   .{ "null", {} },
    .{ "undefined", {} }, .{ "async", {} },          .{ "await", {} },       .{ "let", {} },       .{ "mut", {} },     .{ "impl", {} },
    .{ "trait", {} },     .{ "use", {} },            .{ "mod", {} },         .{ "match", {} },     .{ "self", {} },    .{ "Self", {} },
    .{ "unsafe", {} },    .{ "loop", {} },           .{ "where", {} },       .{ "move", {} },      .{ "ref", {} },     .{ "static", {} },
    .{ "crate", {} },     .{ "super", {} },          .{ "as", {} },          .{ "in", {} },        .{ "is", {} },      .{ "and", {} },
    .{ "or", {} },        .{ "orelse", {} },         .{ "unreachable", {} }, .{ "nosuspend", {} }, .{ "suspend", {} }, .{ "anytype", {} },
    .{ "anyerror", {} },  .{ "type", {} },           .{ "void", {} },        .{ "bool", {} },      .{ "u8", {} },      .{ "usize", {} },
});

pub const Cache = struct {
    allocator: std.mem.Allocator,
    states: std.ArrayList(State) = .empty,
    revision: ?u64 = null,
    language: Language = .plain,
    profile: ?profile_module.Profile = null,
    profile_state_key: ?u64 = null,
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
    pub fn setProfile(self: *Cache, profile: ?profile_module.Profile) void {
        const key = if (profile) |value| profileStateKey(value) else null;
        if (self.profile_state_key != key) self.clear();
        self.profile_state_key = key;
        self.profile = profile;
    }

    fn profileStateKey(profile: profile_module.Profile) ?u64 {
        const block = profile.block_comment orelse return null;
        const hash = std.hash.Wyhash.hash;
        const open = hash(@intFromBool(block.nested), block.start);
        const close = hash(open, block.end);
        const strings = hash(close, profile.string_delimiters);
        return if (profile.line_comment) |line| hash(strings, line) else strings;
    }

    fn tracksState(self: *const Cache, language: Language) bool {
        return language == .rust or (language == .custom and self.profile != null and self.profile.?.block_comment != null);
    }

    pub fn refresh(self: *Cache, snapshot: text.Snapshot, language: Language) !void {
        try self.rebuild(snapshot, language, 0, null);
    }

    pub fn update(self: *Cache, before: text.Snapshot, snapshot: text.Snapshot, language: Language, change: *const text.Change) !void {
        if (!self.tracksState(language) or self.revision != before.revision() or self.language != language or self.states.items.len != before.lineCount() + 1 or change.mappings.len != 1) {
            return self.refresh(snapshot, language);
        }
        const edit = change.mappings[0];
        const row = (try before.pointAt(edit.range.start)).line;
        const old_tail = (try before.pointAt(edit.range.end)).line + 1;
        const new_tail = (try snapshot.pointAt(edit.range.start + edit.inserted)).line + 1;
        try self.rebuild(snapshot, language, row, .{ .old = old_tail, .new = new_tail });
    }

    const Tail = struct { old: usize, new: usize };

    fn rebuild(self: *Cache, snapshot: text.Snapshot, language: Language, first: usize, tail: ?Tail) !void {
        self.revision = null;
        if (self.tracksState(language)) {
            const line_count = snapshot.lineCount();
            const old_len = self.states.items.len;
            const new_len = line_count + 1;
            if (new_len > old_len) try self.states.resize(self.allocator, new_len);
            if (tail) |suffix| {
                // These rows follow the final edited line in both snapshots.
                const source = self.states.items[suffix.old..old_len];
                const destination = self.states.items[suffix.new..new_len];
                if (suffix.new > suffix.old) {
                    std.mem.copyBackwards(State, destination, source);
                } else if (suffix.new < suffix.old) {
                    std.mem.copyForwards(State, destination, source);
                }
            } else {
                self.states.items[0] = .{};
            }
            self.states.shrinkRetainingCapacity(new_len);
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            var lines = try snapshot.linesFrom(first);
            for (first..line_count) |row| {
                const info = lines.next().?;
                var next: State = .{};
                if (info.range.end - info.range.start <= 64 * 1024) {
                    const line = info.bytes orelse try snapshot.copy(arena.allocator(), info.range);
                    next = if (language == .custom)
                        try profile_module.endState(line, self.profile.?, self.states.items[row])
                    else
                        (try scan(arena.allocator(), line, language, self.states.items[row], false)).state;
                    if (info.bytes == null) _ = arena.reset(.retain_capacity);
                }
                if (tail != null and row + 1 >= tail.?.new and self.states.items[row + 1].comment_depth == next.comment_depth) break;
                self.states.items[row + 1] = next;
            }
        } else {
            self.states.clearRetainingCapacity();
        }
        self.language = language;
        self.revision = snapshot.revision();
    }

    pub fn state(self: *const Cache, snapshot: text.Snapshot, row: usize) ?State {
        if (self.revision != snapshot.revision() or row > snapshot.lineCount()) return null;
        return if (self.states.items.len == 0) .{} else self.states.items[row];
    }
};
