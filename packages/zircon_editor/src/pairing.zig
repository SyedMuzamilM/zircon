//! Typed delimiters retain their generated closer until it is consumed or edited.
const std = @import("std");
const text = @import("zircon_text");
const model = @import("editor.zig");
const profile = @import("profile.zig");
const syntax = @import("syntax.zig");
const Pair = struct { open: usize, close: usize, opening: u8, closing: u8 };
pub const State = struct {
    items: std.ArrayList(Pair) = .empty,
    pub fn deinit(self: *State, a: std.mem.Allocator) void {
        self.items.deinit(a);
    }
    pub fn map(self: *State, change: *const text.Change) void {
        var kept: usize = 0;
        for (self.items.items) |item| {
            var removed = false;
            for (change.mappings) |edit| if ((edit.range.start <= item.open and edit.range.end > item.open) or (edit.range.start <= item.close and edit.range.end > item.close)) {
                removed = true;
                break;
            };
            if (removed) continue;
            self.items.items[kept] = .{ .open = change.map(item.open, .after), .close = change.map(item.close, .after), .opening = item.opening, .closing = item.closing };
            kept += 1;
        }
        self.items.shrinkRetainingCapacity(kept);
    }
    fn atCloser(self: *const State, snapshot: text.Snapshot, at: usize, byte: u8) !?Pair {
        if (byte == '"' or byte == '\'' or byte == '`') {
            var before = at;
            var escapes: usize = 0;
            while (before > 0 and try snapshot.byteAt(before - 1) == '\\') : (before -= 1) escapes += 1;
            if (escapes % 2 != 0) return null;
        }
        for (self.items.items) |item| if (item.close == at and item.closing == byte and item.close < snapshot.byteLen() and item.open < item.close and try snapshot.byteAt(item.open) == item.opening and try snapshot.byteAt(item.close) == byte) return item;
        return null;
    }
};

fn closer(byte: u8) ?u8 {
    return switch (byte) {
        '(' => ')',
        '[' => ']',
        '{' => '}',
        '"', '\'', '`' => byte,
        else => null,
    };
}

fn allowed(self: *model.Editor, snapshot: text.Snapshot, at: usize, byte: u8, a: std.mem.Allocator) !bool {
    if (byte == '`' and self.language != .markdown and !(self.language_profile != null and std.mem.indexOfScalar(u8, self.language_profile.?.string_delimiters, byte) != null)) return false;
    if (byte == '\'' and self.language == .json) return false;
    if (at < snapshot.byteLen()) {
        const next = try snapshot.byteAt(at);
        if (!std.ascii.isWhitespace(next) and std.mem.indexOfScalar(u8, ")]},;:", next) == null) return false;
    }
    if (byte == '"' or byte == '\'' or byte == '`') {
        if (at > 0) {
            const previous = try snapshot.byteAt(at - 1);
            if (previous == '\\' or previous == '_' or std.ascii.isAlphanumeric(previous) or previous >= 0x80) return false;
        }
    }
    const row = (try snapshot.pointAt(at)).line;
    const range = try snapshot.lineRange(row);
    if (range.end - range.start > 64 * 1024) return false;
    const bytes = try snapshot.copy(a, range);
    const column = at - range.start;
    const initial: syntax.State = self.syntax_cache.state(snapshot, row) orelse .{};
    const lexed = if (self.language_profile) |value| try profile.lex(a, bytes, value, initial) else try syntax.lex(a, bytes, self.language, initial);
    for (lexed.spans) |span| {
        if (span.start >= column or span.end < column) continue;
        if (span.kind == .comment) return false;
        if (span.kind == .string) {
            if (column < span.end) return false;
            const token = bytes[span.start..span.end];
            if (token.len < 2 or token[0] != token[token.len - 1] or token[0] == '\\') return false;
            var escapes: usize = 0;
            var end = token.len - 1;
            while (end > 0 and token[end - 1] == '\\') : (end -= 1) escapes += 1;
            if (escapes % 2 != 0) return false;
        }
    }
    return true;
}

pub fn typeText(self: *model.Editor, document: *text.Document, bytes: []const u8) !?model.Outcome {
    if (!self.auto_close_pairs or bytes.len != 1 or std.mem.indexOfScalar(u8, "()[]{}\"'`", bytes[0]) == null or self.marked != null) return null;
    self.selections.normalize();
    var snapshot = document.snapshot();
    defer snapshot.deinit();
    self.syntax_cache.profile = self.language_profile;
    if (self.language != .plain and self.syntax_cache.revision != snapshot.revision()) try self.syntax_cache.refresh(snapshot, self.language, 0);
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const selections = self.selections.items.items;
    const edits = try a.alloc(text.Edit, selections.len);
    const modes = try a.alloc(enum { literal, paired, skipped, surrounded }, selections.len);
    var special = false;
    for (selections, edits, modes) |item, *edit, *mode| {
        edit.* = .{ .range = item.range(), .text = bytes };
        mode.* = .literal;
        if (item.empty() and (self.edit_scope == null or item.head < self.edit_scope.?.end) and try self.pairs.atCloser(snapshot, item.head, bytes[0]) != null) {
            edit.text = "";
            mode.* = .skipped;
            special = true;
        } else if (closer(bytes[0])) |closing| {
            if (!item.empty()) {
                const selected = try snapshot.copy(a, item.range());
                edit.text = try std.mem.concat(a, u8, &.{ bytes, selected, &.{closing} });
                mode.* = .surrounded;
                special = true;
            } else if (try allowed(self, snapshot, item.head, bytes[0], a)) {
                edit.text = try a.dupe(u8, &.{ bytes[0], closing });
                mode.* = .paired;
                special = true;
            }
        }
    }
    if (!special) return null;
    try self.pairs.items.ensureUnusedCapacity(self.allocator, selections.len);
    if (self.typing_group == 0) self.typing_group = try model.Editor.freshGroup();
    var prepared = try self.prepareEdits(document, edits, self.typing_group, .preserve);
    defer prepared.deinit();
    for (selections, edits, modes, prepared.selections) |item, edit, mode, *after| {
        const start = prepared.text_edit.change.map(edit.range.start, .before);
        after.* = switch (mode) {
            .literal => .{ .anchor = start + edit.text.len, .head = start + edit.text.len },
            .paired => .{ .anchor = start + 1, .head = start + 1 },
            .skipped => .{ .anchor = start + 1, .head = start + 1 },
            .surrounded => .{ .anchor = start + 1 + item.anchor - edit.range.start, .head = start + 1 + item.head - edit.range.start },
        };
    }
    const outcome = try prepared.commit();
    // A closer-only input changes the selection without creating an undo state.
    if (outcome.change == null) {
        self.selections.items.clearRetainingCapacity();
        self.selections.items.appendSliceAssumeCapacity(prepared.selections);
        self.typing_group = 0;
    }
    for (edits, modes) |edit, mode| if (mode == .paired or mode == .surrounded) {
        const start = if (outcome.change) |change| change.map(edit.range.start, .before) else edit.range.start;
        self.pairs.items.appendAssumeCapacity(.{ .open = start, .close = start + edit.text.len - 1, .opening = bytes[0], .closing = closer(bytes[0]).? });
    };
    var current = document.snapshot();
    defer current.deinit();
    self.reveal(current);
    return outcome;
}

pub fn pairedBackspaceEnd(self: *const model.Editor, snapshot: text.Snapshot, caret: usize) !?usize {
    if (self.pairs.items.items.len == 0 or caret == snapshot.byteLen()) return null;
    const pair = try self.pairs.atCloser(snapshot, caret, try snapshot.byteAt(caret)) orelse return null;
    if (pair.open + 1 != caret) return null;
    return try snapshot.nextGraphemeBoundary(caret);
}
