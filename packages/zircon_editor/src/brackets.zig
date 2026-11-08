//! Find the innermost enclosing pair in a bounded lexical window around a caret.
const std = @import("std");
const text = @import("zircon_text");
const editor = @import("editor.zig");
const profile = @import("profile.zig");
const syntax = @import("syntax.zig");
const Editor = editor.Editor;
const scan_limit = 128 * 1024;

pub const Scope = struct { open: usize, close: usize, first_row: usize, last_row: usize, indent: usize };
const Result = struct { pair: ?Scope = null, guide: ?Scope = null };
const Opening = struct { byte: u8, offset: usize, row: usize, indent: usize };
pub const Cache = struct {
    revision: ?u64 = null,
    cursor: usize = 0,
    scope: ?Scope = null,
    guide: ?Scope = null,
    language: syntax.Language = .plain,
    tab_width: usize = 0,

    pub fn get(self: *Cache, state: *const Editor, snapshot: text.Snapshot, a: std.mem.Allocator) !?Scope {
        const cursor = state.primary().head;
        if (self.revision == snapshot.revision() and self.cursor == cursor and self.language == state.language and self.tab_width == state.tab_width) return self.scope;
        const result = try find(state, snapshot, cursor, a);
        self.scope = result.pair;
        self.guide = result.guide;
        self.language = state.language;
        self.tab_width = state.tab_width;
        self.cursor = cursor;
        self.revision = snapshot.revision();
        return self.scope;
    }
};

fn find(state: *const Editor, snapshot: text.Snapshot, cursor: usize, a: std.mem.Allocator) !Result {
    var stack: [1024]Opening = undefined;
    var depth: usize = 0;
    var result: Result = .{};
    const begin = cursor -| (scan_limit / 2);
    var row = (try snapshot.pointAt(begin)).line;
    if (begin > try snapshot.lineStart(row)) row += 1;
    const end = @min(snapshot.byteLen(), cursor +| (scan_limit / 2));
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    while (row < snapshot.lineCount()) : (row += 1) {
        const range = try snapshot.lineRange(row);
        if (range.start > end) break;
        if (range.end - range.start > 64 * 1024) {
            depth = 0;
            continue;
        }
        const initial = state.syntax_cache.state(snapshot, row) orelse if (state.language == .plain) syntax.State{} else return .{};
        const bytes = try snapshot.copy(scratch, range);
        const lexed = if (state.language_profile) |value| try profile.lex(scratch, bytes, value, initial) else try syntax.lex(scratch, bytes, state.language, initial);
        var indent: usize = 0;
        for (bytes) |byte| {
            if (byte == ' ') indent += 1 else if (byte == '\t') indent += state.tab_width - indent % state.tab_width else break;
        }
        var span_index: usize = 0;
        var column: usize = 0;
        while (column < bytes.len and range.start + column <= end) : (column += 1) {
            while (span_index < lexed.spans.len and lexed.spans[span_index].end <= column) span_index += 1;
            if (span_index < lexed.spans.len) {
                const span = lexed.spans[span_index];
                if (span.start <= column and (span.kind == .string or span.kind == .comment)) {
                    column = span.end - 1;
                    continue;
                }
            }
            const byte = bytes[column];
            const offset = range.start + column;
            if (std.mem.indexOfScalar(u8, "([{", byte) != null) {
                if (depth == stack.len) return .{};
                stack[depth] = .{ .byte = byte, .offset = offset, .row = row, .indent = indent };
                depth += 1;
            } else if (std.mem.indexOfScalar(u8, ")]}", byte)) |closing| {
                if (depth == 0) continue;
                const opening = stack[depth - 1];
                if (opening.byte != "([{"[closing]) {
                    depth = 0;
                    continue;
                }
                depth -= 1;
                if (opening.offset <= cursor and cursor <= offset + 1) {
                    const scope: Scope = .{ .open = opening.offset, .close = offset, .first_row = opening.row, .last_row = row, .indent = opening.indent };
                    if (result.pair == null or opening.offset > result.pair.?.open) result.pair = scope;
                    if (opening.row < row and (result.guide == null or opening.offset > result.guide.?.open)) result.guide = scope;
                }
            }
        }
        _ = arena.reset(.retain_capacity);
    }
    return result;
}
