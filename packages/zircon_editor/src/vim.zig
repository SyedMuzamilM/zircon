//! Modal commands use the same document transactions and undo history as typing.
//! Command text is consumed before the native insertion path, including unknown keys.
const std = @import("std");
const text = @import("zircon_text");
const ui = @import("zircon_ui");
const Editor = @import("editor.zig").Editor;
const Outcome = @import("editor.zig").Outcome;
pub const Mode = enum { normal, insert, visual, visual_line, visual_block };
const Operator = enum { delete, change, yank, indent, outdent };
pub const Remap = struct { from: u8, to: u8 };
pub const Bindings = struct {
    items: [64]Remap = undefined,
    len: usize = 0,
    pub fn resolve(self: Bindings, key: u8) u8 {
        for (self.items[0..self.len]) |binding| if (binding.from == key) return binding.to;
        return key;
    }
};
pub const State = struct {
    enabled: bool = false,
    mode: Mode = .normal,
    cursor: usize = 0,
    anchor: usize = 0,
    count: usize = 0,
    operator_count: usize = 1,
    operator: ?Operator = null,
    prefix: u8 = 0,
    find: u8 = 0,
    object: u8 = 0,
    register: []u8 = &.{},
    linewise: bool = false,
    blockwise: bool = false,
    bindings: Bindings = .{},
    recording: @import("vim_repeat.zig").Recording = .{},
    search_backward: bool = false,
    pub fn deinit(self: *State, a: std.mem.Allocator) void {
        a.free(self.register);
        self.recording.deinit(a);
    }
    pub fn label(self: State) []const u8 {
        return switch (self.mode) {
            .normal => "NORMAL",
            .insert => "INSERT",
            .visual => "VISUAL",
            .visual_line => "VISUAL LINE",
            .visual_block => "VISUAL BLOCK",
        };
    }
    pub fn visual(self: State) bool {
        return self.mode == .visual or self.mode == .visual_line or self.mode == .visual_block;
    }
    pub fn reset(self: *State) void {
        self.count = 0;
        self.operator_count = 1;
        self.operator = null;
        self.prefix = 0;
        self.find = 0;
        self.object = 0;
    }
};
pub fn enable(self: *Editor, enabled: bool) void {
    if (self.vim.enabled == enabled) return;
    self.vim.recording.active = false;
    self.vim.recording.len = 0;
    self.vim.enabled = enabled;
    self.vim.mode = .normal;
    self.vim.cursor = self.primary().head;
    self.vim.anchor = self.vim.cursor;
    self.vim.reset();
    self.typing_group = 0;
}
fn normalPosition(s: text.Snapshot, at: usize) !usize {
    const range = try s.lineRange((try s.pointAt(@min(at, s.byteLen()))).line);
    return if (at >= range.end and range.end > range.start) try s.previousBoundary(range.end) else @min(at, range.end);
}
fn select(self: *Editor, s: text.Snapshot, event: *ui.Event(ui.Input)) !void {
    const v = &self.vim;
    v.cursor = try normalPosition(s, v.cursor);
    if (!v.visual()) {
        self.selections.single(.{ .anchor = v.cursor, .head = v.cursor });
    } else if (v.mode == .visual_line) {
        const first = (try s.pointAt(@min(v.anchor, v.cursor))).line;
        const last = (try s.pointAt(@max(v.anchor, v.cursor))).line;
        self.selections.single(.{ .anchor = try s.lineStart(first), .head = (try s.lineRangeIncludingEnding(last)).end });
    } else if (v.mode == .visual_block) {
        try @import("vim_geometry.zig").block(self, s, event);
    } else {
        self.selections.single(.{ .anchor = @min(v.anchor, v.cursor), .head = try s.nextBoundary(@max(v.anchor, v.cursor)) });
    }
    self.reveal(s);
}
fn column(s: text.Snapshot, range: text.Range, col: usize) !usize {
    var at = @min(range.end, range.start +| col);
    while (!s.isBoundary(at)) at = try s.previousBoundary(at);
    return at;
}
fn enterNormal(self: *Editor, document: *text.Document, from_insert: bool, event: *ui.Event(ui.Input)) !Outcome {
    const v = &self.vim;
    var s = document.snapshot();
    defer s.deinit();
    v.cursor = if (v.visual()) v.cursor else self.primary().head;
    if (from_insert) {
        const range = try s.lineRange((try s.pointAt(v.cursor)).line);
        if (v.cursor > range.start) v.cursor = try s.previousBoundary(v.cursor);
    }
    try @import("vim_repeat.zig").finish(self, s);
    self.preferred_x = null;
    v.mode = .normal;
    v.reset();
    self.typing_group = 0;
    self.marked = null;
    self.composition_group = 0;
    self.composition_changed = false;
    document.breakHistoryGroup();
    try select(self, s, event);
    return .{ .handled = true };
}
pub fn handle(self: *Editor, document: *text.Document, e: *ui.Event(ui.Input)) !?Outcome {
    if (!self.vim.enabled) return null;
    const v = &self.vim;
    if (e.data == .key_down) {
        const k = e.data.key_down;
        if (k.key == .escape or (k.modifiers.control and (k.key == .c or k.key == .left_bracket))) {
            e.preventDefault();
            return try enterNormal(self, document, v.mode == .insert, e);
        }
        if (v.mode == .insert) return null;
        if (k.modifiers.command) return null;
        if (k.modifiers.control) {
            e.preventDefault();
            if (k.key == .v) {
                v.mode = if (v.mode == .visual_block) .normal else .visual_block;
                v.anchor = v.cursor;
                self.preferred_x = null;
                var s = document.snapshot();
                defer s.deinit();
                try select(self, s, e);
            } else if (k.key == .r) {
                return try history(self, document, .redo, e);
            } else if (k.key == .d or k.key == .u or k.key == .f or k.key == .b) {
                const down = k.key == .d or k.key == .f;
                const half = k.key == .d or k.key == .u;
                const rows: usize = @max(1, @as(usize, @intFromFloat(self.last_viewport.height / self.line_height / (if (half) @as(f32, 2) else 1))));
                v.count = rows;
                return try dispatch(self, document, if (down) 'j' else 'k', e);
            }
            return .{ .handled = true };
        }
        const ch: ?u8 = switch (k.key) {
            .left, .backspace => 'h',
            .right, .space => 'l',
            .up => 'k',
            .down => 'j',
            .enter => '+',
            .home => '0',
            .end => '$',
            .delete => 'x',
            else => null,
        };
        if (ch) |c| {
            e.preventDefault();
            return try dispatch(self, document, c, e);
        }
        // Printable keys arrive once as committed text from the platform layout.
        return .{};
    }
    if (v.mode == .insert) return null;
    const bytes: []const u8 = switch (e.data) {
        .text => |b| b,
        .edit => |edit| edit.text,
        .unmark => {
            e.preventDefault();
            return .{ .handled = true };
        },
        else => return null,
    };
    e.preventDefault();
    // A native composition or paste must never become a batch of normal commands.
    if (bytes.len != 1 or bytes[0] >= 0x80) return .{ .handled = true };
    return try dispatch(self, document, v.bindings.resolve(bytes[0]), e);
}
fn dispatch(self: *Editor, doc: *text.Document, key: u8, event: *ui.Event(ui.Input)) !Outcome {
    const recording = &self.vim.recording;
    if (key == '.' and self.vim.find == 0 and self.vim.object == 0 and self.vim.operator == null) return replay(self, doc, event);
    const was_visual = self.vim.visual();
    recording.append(key);
    var result = try token(self, doc, key, event);
    errdefer if (result.change) |*change| change.deinit();
    if (self.vim.mode == .insert) {
        recording.start = self.primary().head;
        recording.end = recording.start;
        recording.active = !was_visual;
        recording.changed = result.change != null;
    } else if (result.change != null) {
        // Recording is optional after a committed edit. Allocation failure must
        // still return its Change so peer panes and previews receive the edit.
        if (!was_visual) recording.remember(self.allocator, "") catch {
            self.allocator.free(recording.last_keys);
            recording.last_keys = &.{};
        };
        recording.len = 0;
    } else if (self.vim.operator == null and self.vim.prefix == 0 and self.vim.find == 0 and self.vim.object == 0 and self.vim.count == 0) recording.len = 0;
    return result;
}
fn replay(self: *Editor, doc: *text.Document, event: *ui.Event(ui.Input)) !Outcome {
    const recording = &self.vim.recording;
    if (recording.last_keys.len == 0 or self.vim.visual()) return .{ .handled = true };
    const count = self.vim.count;
    self.vim.reset();
    recording.len = 0;
    recording.replaying = true;
    defer recording.replaying = false;
    var result: Outcome = .{ .handled = true };
    errdefer if (result.change) |*change| change.deinit();
    var keys = recording.last_keys;
    if (count > 0) {
        while (keys.len > 0 and std.ascii.isDigit(keys[0])) keys = keys[1..];
        var buffer: [24]u8 = undefined;
        const digits = try std.fmt.bufPrint(&buffer, "{d}", .{count});
        for (digits) |digit| _ = try token(self, doc, digit, event);
    }
    for (keys) |key| {
        const next = try token(self, doc, key, event);
        if (next.change != null) {
            std.debug.assert(result.change == null);
            result = next;
        }
    }
    if (self.vim.mode == .insert and result.change == null) result = try self.insert(doc, recording.inserted);
    if (self.vim.mode == .insert) {
        self.vim.mode = .normal;
        self.vim.cursor = self.primary().head;
        var s = doc.snapshot();
        defer s.deinit();
        if (recording.inserted.len > 0 and self.vim.cursor > 0) self.vim.cursor = try s.previousBoundary(self.vim.cursor);
        try select(self, s, event);
    }
    self.vim.reset();
    self.typing_group = 0;
    doc.breakHistoryGroup();
    return result;
}
fn history(self: *Editor, doc: *text.Document, command: @import("commands.zig").Command, event: *ui.Event(ui.Input)) !Outcome {
    const result = try self.execute(doc, command);
    self.preferred_x = null;
    self.vim.cursor = self.primary().range().start;
    self.vim.mode = .normal;
    self.vim.reset();
    var s = doc.snapshot();
    defer s.deinit();
    try select(self, s, event);
    return result;
}
fn class(s: text.Snapshot, at: usize, big: bool) !u2 {
    const b = try s.byteAt(at);
    return if (std.ascii.isWhitespace(b)) 0 else if (big or std.ascii.isAlphanumeric(b) or b == '_' or b >= 128) 1 else 2;
}
fn word(s: text.Snapshot, from: usize, key: u8) !usize {
    var at = from;
    const big = std.ascii.isUpper(key);
    if (key == 'b' or key == 'B') {
        if (at > 0) at = try s.previousBoundary(at);
        while (at > 0 and try class(s, at, big) == 0) at = try s.previousBoundary(at);
        if (at == s.byteLen()) return at;
        const kind = try class(s, at, big);
        while (at > 0) {
            const previous = try s.previousBoundary(at);
            if (try class(s, previous, big) != kind) break;
            at = previous;
        }
    } else if (key == 'e' or key == 'E') {
        if (at < s.byteLen()) at = try s.nextBoundary(at);
        while (at < s.byteLen() and try class(s, at, big) == 0) at = try s.nextBoundary(at);
        if (at == s.byteLen()) return at;
        const kind = try class(s, at, big);
        while (at < s.byteLen()) {
            const next = try s.nextBoundary(at);
            if (next == s.byteLen() or try class(s, next, big) != kind) break;
            at = next;
        }
    } else {
        if (at < s.byteLen()) {
            const kind = try class(s, at, big);
            while (at < s.byteLen() and try class(s, at, big) == kind) at = try s.nextBoundary(at);
        }
        while (at < s.byteLen() and try class(s, at, big) == 0) at = try s.nextBoundary(at);
    }
    return at;
}
fn motion(self: *Editor, s: text.Snapshot, key: u8, count: usize, event: *ui.Event(ui.Input)) !?usize {
    var at = self.vim.cursor;
    const point = try s.pointAt(at);
    const range = try s.lineRange(point.line);
    switch (key) {
        'h' => {
            for (0..count) |_| {
                if (at == range.start) break;
                at = try s.previousBoundary(at);
            }
        },
        'l' => {
            for (0..count) |_| {
                if (at >= range.end) break;
                at = try s.nextBoundary(at);
            }
        },
        'j', 'k' => {
            const row = if (key == 'j') @min(s.lineCount() - 1, point.line +| count) else point.line -| count;
            return try @import("vim_geometry.zig").vertical(self, s, at, row, event);
        },
        '+', '-' => {
            const row = if (key == '+') @min(s.lineCount() - 1, point.line +| count) else point.line -| count;
            const target = try s.lineRange(row);
            at = target.start;
            while (at < target.end and ((try s.byteAt(at)) == ' ' or (try s.byteAt(at)) == '\t')) at += 1;
        },
        'H', 'M', 'L' => {
            const first = self.rowAt(self.scroll.offset, s.revision());
            const rows: usize = @max(1, @as(usize, @intFromFloat(self.last_viewport.height / self.line_height)));
            const row = if (key == 'H') first +| (count - 1) else if (key == 'L') first +| (rows -| count) else first +| (rows / 2);
            at = try s.lineStart(@min(s.lineCount() - 1, row));
        },
        '{', '}' => {
            var row = point.line;
            for (0..count) |_| {
                if (key == '{') {
                    if (row == 0) break;
                    row -= 1;
                } else {
                    if (row + 1 >= s.lineCount()) break;
                    row += 1;
                }
                while (row > 0 and row + 1 < s.lineCount() and ((try s.lineRange(row)).start == (try s.lineRange(row)).end)) row = if (key == '{') row - 1 else row + 1;
                while (row > 0 and row + 1 < s.lineCount() and !((try s.lineRange(row)).start == (try s.lineRange(row)).end)) row = if (key == '{') row - 1 else row + 1;
            }
            at = try s.lineStart(row);
        },
        'w', 'W', 'b', 'B', 'e', 'E' => {
            for (0..count) |_| {
                const next = try word(s, at, key);
                if (at == next) break;
                at = next;
            }
        },
        '0' => at = range.start,
        '^', '_' => {
            at = range.start;
            while (at < range.end and ((try s.byteAt(at)) == ' ' or (try s.byteAt(at)) == '\t')) at += 1;
        },
        '$' => at = if (range.end > range.start) try s.previousBoundary(range.end) else range.end,
        'G' => at = try s.lineStart(if (self.vim.count == 0 and self.vim.operator_count == 1) s.lineCount() - 1 else @min(s.lineCount() - 1, count - 1)),
        '%' => {
            if (at == s.byteLen()) return at;
            const byte = try s.byteAt(at);
            const pairs = "()[]{}";
            const index = std.mem.indexOfScalar(u8, pairs, byte) orelse return at;
            const forward = index % 2 == 0;
            const other = pairs[if (forward) index + 1 else index - 1];
            var depth: usize = 1;
            while (true) {
                if ((forward and at == s.byteLen()) or (!forward and at == 0)) break;
                at = if (forward) try s.nextBoundary(at) else try s.previousBoundary(at);
                if (at == s.byteLen()) break;
                const b = try s.byteAt(at);
                if (b == byte) depth += 1 else if (b == other) depth -= 1;
                if (depth == 0) return at;
            }
            return self.vim.cursor;
        },
        else => return null,
    }
    self.preferred_x = null;
    return at;
}
fn saveRegister(self: *Editor, s: text.Snapshot, linewise: bool, event: *ui.Event(ui.Input)) !void {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(self.allocator);
    for (self.selections.items.items, 0..) |item, i| {
        if (i > 0) try bytes.append(self.allocator, '\n');
        const copy = try s.copy(self.allocator, item.range());
        defer self.allocator.free(copy);
        try bytes.appendSlice(self.allocator, copy);
    }
    if (linewise and (bytes.items.len == 0 or bytes.items[bytes.items.len - 1] != '\n')) try bytes.append(self.allocator, '\n');
    const owned = try bytes.toOwnedSlice(self.allocator);
    self.allocator.free(self.vim.register);
    self.vim.register = owned;
    self.vim.linewise = linewise;
    self.vim.blockwise = self.vim.mode == .visual_block;
    if (event._surface != null) try event.writeClipboard(owned);
}
fn operate(self: *Editor, doc: *text.Document, op: Operator, linewise: bool, event: *ui.Event(ui.Input)) !Outcome {
    const start = self.primary().range().start;
    var s = doc.snapshot();
    defer s.deinit();
    if (op == .delete or op == .change or op == .yank) try saveRegister(self, s, linewise, event);
    self.vim.reset();
    self.typing_group = 0;
    if (op == .yank) {
        self.vim.mode = .normal;
        self.vim.cursor = start;
        try select(self, s, event);
        return .{ .handled = true };
    }
    if (linewise and self.selections.items.items.len == 1) {
        var range = self.primary().range();
        if (op == .change) {
            const last = (try s.pointAt(if (range.end > range.start) try s.previousBoundary(range.end) else range.end)).line;
            range.end = (try s.lineRange(last)).end;
        } else if (op == .delete and range.end == s.byteLen() and range.end > 0 and (range.start == range.end or try s.byteAt(range.end - 1) != '\n') and range.start > 0) {
            range.start = (try s.lineRange((try s.pointAt(range.start)).line - 1)).end;
        }
        self.selections.single(.{ .anchor = range.start, .head = range.end });
    }
    const result = try self.execute(doc, switch (op) {
        .indent => .indent,
        .outdent => .outdent,
        else => .{ .insert = if (op == .change and self.vim.recording.replaying) self.vim.recording.inserted else "" },
    });
    if (op != .change) self.typing_group = 0;
    self.vim.mode = if (op == .change) .insert else .normal;
    self.vim.cursor = self.primary().head;
    if (self.vim.mode == .normal) {
        var after = doc.snapshot();
        defer after.deinit();
        try select(self, after, event);
    }
    return result;
}
fn token(self: *Editor, doc: *text.Document, key: u8, event: *ui.Event(ui.Input)) !Outcome {
    const v = &self.vim;
    var s = doc.snapshot();
    defer s.deinit();
    if (!v.visual()) v.cursor = try normalPosition(s, self.primary().head);
    if (key >= '0' and key <= '9' and (key != '0' or v.count > 0) and v.find == 0) {
        v.count = @min(100000, v.count *| 10 +| (key - '0'));
        return .{ .handled = true };
    }
    const count = @min(100000, @max(1, v.count) *| v.operator_count);
    const old = v.cursor;
    if (v.find != 0) {
        const find = v.find;
        v.find = 0;
        if (find == 'r') {
            var end = old;
            const line = try s.lineRange((try s.pointAt(old)).line);
            var bytes: std.ArrayList(u8) = .empty;
            defer bytes.deinit(self.allocator);
            for (0..count) |_| {
                if (end >= line.end) break;
                end = try s.nextBoundary(end);
                try bytes.append(self.allocator, key);
            }
            self.typing_group = 0;
            var result = try self.applyEdits(doc, &.{.{ .range = .{ .start = old, .end = end }, .text = bytes.items }}, 0);
            errdefer if (result.change) |*c| c.deinit();
            v.cursor = old;
            v.reset();
            var after = doc.snapshot();
            defer after.deinit();
            try select(self, after, event);
            return result;
        }
        const line = try s.lineRange((try s.pointAt(old)).line);
        const forward = find == 'f' or find == 't';
        var at = old;
        var found: usize = 0;
        while (found < count) {
            if ((forward and at >= line.end) or (!forward and at <= line.start)) break;
            at = if (forward) try s.nextBoundary(at) else try s.previousBoundary(at);
            if (at < line.end and try s.byteAt(at) == key) found += 1;
        }
        if (found != count) {
            v.reset();
            return .{ .handled = true };
        }
        if (find == 't') at = try s.previousBoundary(at) else if (find == 'T') at = try s.nextBoundary(at);
        return try finishMotion(self, doc, s, at, true, false, event);
    }
    if (v.object != 0) {
        const around = v.object == 'a';
        v.object = 0;
        if (key == 'w' or key == 'W') {
            var left = old;
            var right = old;
            if (old < s.byteLen()) {
                const kind = try class(s, old, key == 'W');
                while (left > 0) {
                    const prev = try s.previousBoundary(left);
                    if (try class(s, prev, key == 'W') != kind) break;
                    left = prev;
                }
                while (right < s.byteLen() and try class(s, right, key == 'W') == kind) right = try s.nextBoundary(right);
                if (around) while (right < s.byteLen() and try class(s, right, key == 'W') == 0) {
                    right = try s.nextBoundary(right);
                };
            }
            self.selections.single(.{ .anchor = left, .head = right });
            if (v.operator) |operation| return try operate(self, doc, operation, false, event);
            v.mode = .visual;
            v.anchor = left;
            v.cursor = if (right > left) try s.previousBoundary(right) else left;
            v.reset();
            return .{ .handled = true };
        }
        v.reset();
        return .{ .handled = true };
    }
    if (v.prefix != 0) {
        const prefix = v.prefix;
        v.prefix = 0;
        if (prefix == 'g' and key == 'c') {
            if (v.visual()) return try comment(self, doc, event);
            v.prefix = 'C';
            return .{ .handled = true };
        }
        if (prefix == 'C') {
            const row = (try s.pointAt(old)).line;
            const target = if (key == 'c') @min(s.lineCount() - 1, row +| (count - 1)) else if (try motion(self, s, key, count, event)) |at| (try s.pointAt(at)).line else {
                v.reset();
                return .{ .handled = true };
            };
            self.selections.single(.{ .anchor = try s.lineStart(@min(row, target)), .head = (try s.lineRangeIncludingEnding(@max(row, target))).end });
            return try comment(self, doc, event);
        }
        if (prefix == 'g' and key == 'g') {
            self.preferred_x = null;
            return try finishMotion(self, doc, s, try s.lineStart(@min(s.lineCount() - 1, count - 1)), false, true, event);
        }
        if (prefix == 'z') {
            const top = self.rowY((try s.pointAt(old)).line, s.revision());
            if (key == 'z' or key == 't' or key == 'b') self.scroll.offset = @max(0, top - (if (key == 'z') self.last_viewport.height / 2 else if (key == 'b') self.last_viewport.height - self.line_height else @as(f32, 0)));
        }
        v.reset();
        return .{ .handled = true };
    }
    if ((v.operator != null or v.visual()) and (key == 'i' or key == 'a')) {
        v.object = key;
        return .{ .handled = true };
    }
    const op: ?Operator = switch (key) {
        'd' => .delete,
        'c' => .change,
        'y' => .yank,
        '>' => .indent,
        '<' => .outdent,
        else => null,
    };
    if (op) |operation| {
        if (v.visual()) return try operate(self, doc, operation, v.mode == .visual_line, event);
        if (v.operator == operation) {
            const first = (try s.pointAt(old)).line;
            const last = @min(s.lineCount() - 1, first +| (count - 1));
            self.selections.single(.{ .anchor = try s.lineStart(first), .head = (try s.lineRangeIncludingEnding(last)).end });
            return try operate(self, doc, operation, true, event);
        }
        v.operator = operation;
        v.operator_count = @max(1, v.count);
        v.count = 0;
        return .{ .handled = true };
    }
    if (key == 'g' or key == 'z') {
        v.prefix = key;
        return .{ .handled = true };
    }
    if (key == 'f' or key == 'F' or key == 't' or key == 'T' or key == 'r') {
        v.find = key;
        return .{ .handled = true };
    }
    if (v.operator == .change and (key == 'w' or key == 'W') and old < s.byteLen() and try class(s, old, key == 'W') != 0) {
        var at = old;
        for (0..count) |i| {
            if (i > 0) at = try word(s, at, key);
            if (at >= s.byteLen()) break;
            const kind = try class(s, at, key == 'W');
            while (at < s.byteLen()) {
                const next = try s.nextBoundary(at);
                if (next == s.byteLen() or try class(s, next, key == 'W') != kind) break;
                at = next;
            }
        }
        return try finishMotion(self, doc, s, at, true, false, event);
    }
    if (try motion(self, s, key, count, event)) |at| {
        const inclusive = key == 'e' or key == 'E' or key == '$' or key == '%';
        return try finishMotion(self, doc, s, at, inclusive, key == 'j' or key == 'k' or key == 'G' or key == '+' or key == '-' or key == 'H' or key == 'M' or key == 'L', event);
    }
    if (v.operator != null) {
        v.reset();
        return .{ .handled = true };
    }
    switch (key) {
        '/', '?' => {
            v.search_backward = key == '?';
            v.reset();
            return .{ .handled = true, .request_find = true };
        },
        'n', 'N', '*', '#' => {
            if (key == '*' or key == '#') {
                const range = try @import("navigation.zig").wordRange(s, old);
                const query = try s.copy(self.allocator, range);
                defer self.allocator.free(query);
                v.search_backward = key == '#';
                _ = try self.findNext(doc, query, v.search_backward);
            } else if (self.search_query.len > 0) {
                for (0..count) |_| _ = try self.findNext(doc, self.search_query, if (key == 'N') !v.search_backward else v.search_backward);
            }
        },
        'v', 'V' => {
            const mode: Mode = if (key == 'V') .visual_line else .visual;
            if (v.mode == mode) return try enterNormal(self, doc, false, event);
            if (!v.visual()) v.anchor = old;
            v.mode = mode;
            try select(self, s, event);
        },
        'i', 'a', 'I', 'A' => {
            if (v.mode == .visual_block and (key == 'I' or key == 'A')) {
                for (self.selections.items.items) |*item| {
                    const position = if (key == 'I') item.range().start else item.range().end;
                    item.* = .{ .anchor = position, .head = position };
                }
                v.mode = .insert;
                self.typing_group = 0;
                v.reset();
                return .{ .handled = true };
            }
            var at = old;
            const range = try s.lineRange((try s.pointAt(old)).line);
            if (key == 'a' and at < range.end) at = try s.nextBoundary(at);
            if (key == 'I') at = (try motion(self, s, '^', 1, event)).?;
            if (key == 'A') at = range.end;
            self.selections.single(.{ .anchor = at, .head = at });
            v.mode = .insert;
            self.typing_group = 0;
        },
        'o', 'O' => {
            const row = (try s.pointAt(old)).line;
            const range = try s.lineRange(row);
            const at = if (key == 'o') range.end else range.start;
            var indent_end = range.start;
            while (indent_end < range.end and ((try s.byteAt(indent_end)) == ' ' or (try s.byteAt(indent_end)) == '\t')) indent_end += 1;
            const indent = try s.copy(self.allocator, .{ .start = range.start, .end = indent_end });
            defer self.allocator.free(indent);
            const payload = if (v.recording.replaying) v.recording.inserted else "";
            const bytes = try std.mem.concat(self.allocator, u8, if (key == 'o') &.{ "\n", indent, payload } else &.{ indent, payload, "\n" });
            defer self.allocator.free(bytes);
            self.typing_group = try Editor.freshGroup();
            const result = try self.applyEdits(doc, &.{.{ .range = .{ .start = at, .end = at }, .text = bytes }}, self.typing_group);
            if (key == 'O') self.selections.single(.{ .anchor = at + indent.len + payload.len, .head = at + indent.len + payload.len });
            v.mode = .insert;
            return result;
        },
        'x', 'X', 's', 'D', 'C', 'S' => {
            if (!v.visual()) {
                const line = try s.lineRange((try s.pointAt(old)).line);
                var start = old;
                var end = old;
                if (key == 'D' or key == 'C') end = line.end else if (key == 'S') {
                    start = line.start;
                    end = line.end;
                } else for (0..count) |_| {
                    if (key == 'X') {
                        if (start > line.start) start = try s.previousBoundary(start);
                    } else if (end < line.end) end = try s.nextBoundary(end);
                }
                self.selections.single(.{ .anchor = start, .head = end });
            }
            return try operate(self, doc, if (key == 's' or key == 'C' or key == 'S') .change else .delete, false, event);
        },
        'u' => return try history(self, doc, .undo, event),
        'p', 'P' => {
            if (v.blockwise and v.register.len > 0) {
                const start = if (v.visual()) self.primary().range().start else old;
                const result = try @import("vim_paste.zig").block(self, doc, key == 'P', count, event);
                v.mode = .normal;
                v.cursor = start;
                v.reset();
                var after = doc.snapshot();
                defer after.deinit();
                try select(self, after, event);
                return result;
            }
            if (v.register.len == 0) return .{ .handled = true };
            const line = try s.lineRangeIncludingEnding((try s.pointAt(old)).line);
            const at = if (v.linewise) (if (key == 'p') line.end else line.start) else if (key == 'p' and old < (try s.lineRange((try s.pointAt(old)).line)).end) try s.nextBoundary(old) else old;
            var bytes: std.ArrayList(u8) = .empty;
            defer bytes.deinit(self.allocator);
            if (v.linewise and key == 'p' and at == s.byteLen() and at > 0 and try s.byteAt(at - 1) != '\n') try bytes.append(self.allocator, '\n');
            for (0..count) |_| try bytes.appendSlice(self.allocator, v.register);
            self.typing_group = 0;
            const result = try self.applyEdits(doc, &.{.{ .range = if (v.visual()) self.primary().range() else .{ .start = at, .end = at }, .text = bytes.items }}, 0);
            v.mode = .normal;
            v.cursor = at;
            v.reset();
            var after = doc.snapshot();
            defer after.deinit();
            try select(self, after, event);
            return result;
        },
        'J' => {
            const row = (try s.pointAt(old)).line;
            if (row + 1 < s.lineCount()) {
                const line = try s.lineRange(row);
                const next = try s.lineRange(row + 1);
                var end = next.start;
                while (end < next.end and ((try s.byteAt(end)) == ' ' or (try s.byteAt(end)) == '\t')) end += 1;
                self.typing_group = 0;
                const result = try self.applyEdits(doc, &.{.{ .range = .{ .start = line.end, .end = end }, .text = " " }}, 0);
                v.cursor = line.end;
                var after = doc.snapshot();
                defer after.deinit();
                try select(self, after, event);
                return result;
            }
        },
        else => {},
    }
    v.reset();
    return .{ .handled = true };
}
fn finishMotion(self: *Editor, doc: *text.Document, s: text.Snapshot, at: usize, inclusive: bool, linewise: bool, event: *ui.Event(ui.Input)) !Outcome {
    const v = &self.vim;
    if (v.operator) |op| {
        const start = @min(v.cursor, at);
        var end = @max(v.cursor, at);
        if (linewise) {
            self.selections.single(.{ .anchor = try s.lineStart((try s.pointAt(start)).line), .head = (try s.lineRangeIncludingEnding((try s.pointAt(end)).line)).end });
        } else {
            if (inclusive) end = try s.nextBoundary(end);
            self.selections.single(.{ .anchor = start, .head = end });
        }
        return try operate(self, doc, op, linewise, event);
    }
    v.cursor = at;
    v.reset();
    try select(self, s, event);
    self.typing_group = 0;
    return .{ .handled = true };
}

pub fn synchronize(self: *Editor, s: text.Snapshot) void {
    const v = &self.vim;
    if (!v.enabled) return;
    v.cursor = @min(v.cursor, s.byteLen());
    v.anchor = @min(v.anchor, s.byteLen());
    while (!s.isBoundary(v.cursor)) v.cursor -= 1;
    while (!s.isBoundary(v.anchor)) v.anchor -= 1;
}

fn comment(self: *Editor, doc: *text.Document, event: *ui.Event(ui.Input)) !Outcome {
    const result = try self.execute(doc, .toggle_comment);
    self.vim.mode = .normal;
    self.vim.reset();
    var after = doc.snapshot();
    defer after.deinit();
    try select(self, after, event);
    return result;
}
