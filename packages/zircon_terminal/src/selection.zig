//! Monotonic-line terminal selection and smart text extraction.

const std = @import("std");
const grid = @import("grid.zig");
pub const Mode = enum { char, word, line };

pub const Anchor = struct {
    line: u64,
    col: usize,

    pub fn lt(a: Anchor, b: Anchor) bool {
        return a.line < b.line or (a.line == b.line and a.col < b.col);
    }

    pub fn eql(a: Anchor, b: Anchor) bool {
        return a.line == b.line and a.col == b.col;
    }
};

pub const Selection = struct {
    anchor: Anchor = .{ .line = 0, .col = 0 },
    head: Anchor = .{ .line = 0, .col = 0 },
    mode: Mode = .char,
    active: bool = false,
    pivot_start: Anchor = .{ .line = 0, .col = 0 },
    pivot_end: Anchor = .{ .line = 0, .col = 0 },

    pub fn clear(self: *Selection) void {
        self.active = false;
    }

    pub fn isEmpty(self: Selection) bool {
        return !self.active or (self.mode == .char and self.anchor.eql(self.head));
    }

    pub fn ordered(self: Selection) struct { start: Anchor, end: Anchor } {
        if (self.head.lt(self.anchor)) return .{ .start = self.head, .end = self.anchor };
        return .{ .start = self.anchor, .end = self.head };
    }

    pub fn startAt(self: *Selection, screen: *const grid.Screen, abs_line: u64, col: usize, mode: Mode) void {
        self.mode = mode;
        self.active = true;
        switch (mode) {
            .char => {
                self.anchor = .{ .line = abs_line, .col = col };
                self.head = self.anchor;
            },
            .word => {
                const bounds = wordBounds(screen, abs_line, col);
                self.anchor = .{ .line = abs_line, .col = bounds.start };
                self.head = .{ .line = abs_line, .col = bounds.end };
            },
            .line => {
                const bounds = logicalLineBounds(screen, abs_line);
                self.anchor = .{ .line = bounds.first, .col = 0 };
                self.head = .{ .line = bounds.last, .col = colsAt(screen, bounds.last) };
            },
        }
        self.pivot_start = self.anchor;
        self.pivot_end = self.head;
    }

    pub fn extendTo(self: *Selection, screen: *const grid.Screen, abs_line: u64, col: usize) void {
        if (!self.active) return;
        const target: struct { start: Anchor, end: Anchor } = switch (self.mode) {
            .char => .{ .start = .{ .line = abs_line, .col = col }, .end = .{ .line = abs_line, .col = col } },
            .word => blk: {
                const bounds = wordBounds(screen, abs_line, col);
                break :blk .{ .start = .{ .line = abs_line, .col = bounds.start }, .end = .{ .line = abs_line, .col = bounds.end } };
            },
            .line => blk: {
                const bounds = logicalLineBounds(screen, abs_line);
                break :blk .{ .start = .{ .line = bounds.first, .col = 0 }, .end = .{ .line = bounds.last, .col = colsAt(screen, bounds.last) } };
            },
        };
        if (target.start.lt(self.pivot_start)) {
            self.anchor = self.pivot_end;
            self.head = target.start;
        } else {
            self.anchor = self.pivot_start;
            self.head = target.end;
        }
    }

    pub fn selectAll(self: *Selection, screen: *const grid.Screen) void {
        if (screen.len == 0) return;
        self.mode = .line;
        self.active = true;
        self.anchor = .{ .line = screen.evicted, .col = 0 };
        self.head = .{ .line = screen.absLineForLogical(screen.len - 1), .col = screen.cols };
        self.pivot_start = self.anchor;
        self.pivot_end = self.head;
    }

    /// Returns the half-open `[start_col, end_col)` selected range on `abs_line`.
    pub fn lineRange(self: Selection, abs_line: u64, cols: usize) ?struct { start: usize, end: usize } {
        if (self.isEmpty()) return null;
        const range = self.ordered();
        if (abs_line < range.start.line or abs_line > range.end.line) return null;
        const start = if (abs_line == range.start.line) @min(range.start.col, cols) else 0;
        const end = if (abs_line == range.end.line) @min(range.end.col, cols) else cols;
        if (start >= end) return null;
        return .{ .start = start, .end = end };
    }
};

fn colsAt(screen: *const grid.Screen, line: u64) usize {
    const logical = screen.logicalForAbsLine(line) orelse return screen.cols;
    return screen.rowConst(logical).cells.len;
}

fn isWordChar(cp: u21) bool {
    if (cp > 0x7f) return true;
    const b: u8 = @intCast(cp);
    return std.ascii.isAlphanumeric(b) or b == '_' or b == '-' or b == '.' or b == '/' or b == ':';
}

fn sameWordKind(cell: grid.Cell, code: u21) bool {
    if (isWordChar(code)) return cell.style.wide_trail or isWordChar(cell.code);
    return cell.code == code and !cell.style.wide_trail;
}

pub fn wordBounds(screen: *const grid.Screen, abs_line: u64, col: usize) struct { start: usize, end: usize } {
    const logical = screen.logicalForAbsLine(abs_line) orelse return .{ .start = col, .end = col };
    const cells = screen.rowConst(logical).cells;
    if (cells.len == 0) return .{ .start = 0, .end = 0 };
    var c = @min(col, cells.len - 1);
    if (cells[c].style.wide_trail) c -|= 1;
    const code = cells[c].code;
    var start = c;
    while (start > 0 and sameWordKind(cells[start - 1], code)) : (start -= 1) {}
    var end = c + 1;
    while (end < cells.len and sameWordKind(cells[end], code)) : (end += 1) {}
    return .{ .start = start, .end = end };
}

pub fn logicalLineBounds(screen: *const grid.Screen, abs_line: u64) struct { first: u64, last: u64 } {
    const logical = screen.logicalForAbsLine(abs_line) orelse return .{ .first = abs_line, .last = abs_line };
    var first = logical;
    while (first > 0 and screen.rowConst(first - 1).wrapped) : (first -= 1) {}
    var last = logical;
    while (last + 1 < screen.len and screen.rowConst(last).wrapped) : (last += 1) {}
    return .{ .first = screen.absLineForLogical(first), .last = screen.absLineForLogical(last) };
}

/// Extracts UTF-8 text for the selection: rejoins soft-wrapped rows without
/// artificial newlines and trims trailing blank padding on each logical line.
pub fn extractText(a: std.mem.Allocator, screen: *const grid.Screen, sel: Selection) ![]u8 {
    if (sel.isEmpty() or screen.len == 0) return a.alloc(u8, 0);
    const range = sel.ordered();
    const min_abs = screen.evicted;
    const max_abs = screen.evicted + @as(u64, @intCast(screen.len - 1));
    if (range.end.line < min_abs or range.start.line > max_abs) return a.alloc(u8, 0);

    const first_abs = @max(range.start.line, min_abs);
    const last_abs = @min(range.end.line, max_abs);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var line_buf: std.ArrayList(u8) = .empty;
    defer line_buf.deinit(a);

    var cur = first_abs;
    while (cur <= last_abs) : (cur += 1) {
        const logical = screen.logicalForAbsLine(cur).?;
        const row = screen.rowConst(logical);
        var start_col = if (cur == range.start.line) @min(range.start.col, row.cells.len) else 0;
        const end_col = if (cur == range.end.line) @min(range.end.col, row.cells.len) else row.cells.len;

        const effective_end = if (row.wrapped and row.wrap_padding and end_col == row.cells.len) end_col -| 1 else end_col;
        if (start_col < effective_end) {
            if (row.cells[start_col].style.wide_trail) start_col -|= 1;
            for (row.cells[start_col..effective_end]) |cell| {
                if (cell.style.wide_trail) continue;
                var enc: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(cell.code, &enc) catch 0;
                try line_buf.appendSlice(a, enc[0..len]);
            }
        }
        const continues = row.wrapped and cur < last_abs and end_col == row.cells.len;
        if (!continues) {
            // Trim trailing padding spaces when the selection hit the row's right margin.
            var trimmed = line_buf.items.len;
            if (end_col == row.cells.len) {
                while (trimmed > 0 and line_buf.items[trimmed - 1] == ' ') : (trimmed -= 1) {}
            }
            try out.appendSlice(a, line_buf.items[0..trimmed]);
            line_buf.clearRetainingCapacity();
            if (cur < last_abs) try out.append(a, '\n');
        }
    }
    return out.toOwnedSlice(a);
}
