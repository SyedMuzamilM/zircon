//! O(1) circular-buffer terminal grid with monotonic line IDs, packed style
//! attributes, 256-color/truecolor support, and scroll-region operations.

const std = @import("std");
pub const Color = union(enum) {
    default,
    indexed: u8,
    rgb: u24,

    pub fn eql(a: Color, b: Color) bool {
        return std.meta.eql(a, b);
    }

    pub fn resolve(self: Color, palette: [16]u24, fallback: u24) u24 {
        return switch (self) {
            .default => fallback,
            .rgb => |v| v,
            .indexed => |idx| resolveIndexed(idx, palette),
        };
    }
};

pub fn resolveIndexed(idx: u8, palette: [16]u24) u24 {
    if (idx < 16) return palette[idx];
    if (idx < 232) {
        const n = idx - 16;
        const r_i = n / 36;
        const g_i = (n % 36) / 6;
        const b_i = n % 6;
        const levels = [6]u8{ 0, 95, 135, 175, 215, 255 };
        return (@as(u24, levels[r_i]) << 16) | (@as(u24, levels[g_i]) << 8) | levels[b_i];
    }
    const gray: u8 = @intCast(8 + (@as(u16, idx - 232) * 10));
    return (@as(u24, gray) << 16) | (@as(u24, gray) << 8) | gray;
}

pub const Style = packed struct(u8) {
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    strikethrough: bool = false,
    inverse: bool = false,
    wide_lead: bool = false,
    wide_trail: bool = false,

    pub fn visualEql(a: Style, b: Style) bool {
        return a.bold == b.bold and
            a.dim == b.dim and
            a.italic == b.italic and
            a.underline == b.underline and
            a.strikethrough == b.strikethrough and
            a.inverse == b.inverse;
    }
};

pub const Cell = struct {
    code: u21 = ' ',
    fg: Color = .default,
    bg: Color = .default,
    style: Style = .{},

    pub const blank: Cell = .{};
};

pub const Row = struct {
    cells: []Cell = &.{},
    /// True when this row soft-wrapped onto the following row.
    wrapped: bool = false,
    /// A wide character at the right edge can leave one unused column.
    wrap_padding: bool = false,

    pub fn erase(self: *Row, start: usize, end: usize, blank: Cell) void {
        if (start >= end) return;
        const first = if (self.cells[start].style.wide_trail) start -| 1 else start;
        const last = if (end < self.cells.len and self.cells[end].style.wide_trail) end + 1 else end;
        @memset(self.cells[first..last], blank);
    }

    pub fn repairWide(self: *Row, blank: Cell) void {
        for (self.cells, 0..) |*cell, i| {
            if ((cell.style.wide_trail and (i == 0 or !self.cells[i - 1].style.wide_lead)) or
                (cell.style.wide_lead and (i + 1 == self.cells.len or !self.cells[i + 1].style.wide_trail)))
            {
                cell.* = blank;
            }
        }
    }
};

pub const Screen = struct {
    cols: usize,
    rows: usize,
    capacity: usize,
    history_limit: usize,
    ring: []Row,
    head: usize = 0,
    len: usize = 0,
    /// Total rows evicted from the front of the ring; gives every line a stable ID.
    evicted: u64 = 0,
    scroll_top: usize = 0,
    scroll_bottom: usize = 0,

    pub fn init(a: std.mem.Allocator, cols: usize, rows: usize, max_history: usize) !Screen {
        const c = @max(1, cols);
        const r = @max(1, rows);
        const cap = @max(r, max_history);
        const ring = try a.alloc(Row, cap);
        @memset(ring, .{});
        var s: Screen = .{
            .cols = c,
            .rows = r,
            .capacity = cap,
            .history_limit = max_history,
            .ring = ring,
            .scroll_top = 0,
            .scroll_bottom = r - 1,
        };
        errdefer s.deinit(a);
        for (0..r) |_| try s.pushBlankRow(a);
        return s;
    }

    pub fn deinit(self: *Screen, a: std.mem.Allocator) void {
        for (self.ring) |row| if (row.cells.len > 0) a.free(row.cells);
        a.free(self.ring);
        self.* = undefined;
    }

    /// Logical index `0..self.len` (oldest to newest).
    pub fn rowPtr(self: *Screen, logical: usize) *Row {
        std.debug.assert(logical < self.len);
        return &self.ring[(self.head + logical) % self.capacity];
    }

    pub fn rowConst(self: *const Screen, logical: usize) *const Row {
        std.debug.assert(logical < self.len);
        return &self.ring[(self.head + logical) % self.capacity];
    }

    /// Viewport row `0..self.rows` relative to the live bottom screen.
    pub fn viewBase(self: *const Screen) usize {
        return self.len -| self.rows;
    }

    pub fn viewRow(self: *Screen, y: usize) *Row {
        const idx = self.viewBase() + @min(y, self.rows - 1);
        return self.rowPtr(idx);
    }

    pub fn absLineForLogical(self: *const Screen, logical: usize) u64 {
        return self.evicted + @as(u64, @intCast(logical));
    }

    pub fn logicalForAbsLine(self: *const Screen, abs_line: u64) ?usize {
        if (abs_line < self.evicted) return null;
        const rel = abs_line - self.evicted;
        if (rel >= self.len) return null;
        return @intCast(rel);
    }

    pub fn pushBlankRow(self: *Screen, a: std.mem.Allocator) !void {
        if (self.len < self.capacity) {
            const slot = (self.head + self.len) % self.capacity;
            if (self.ring[slot].cells.len != self.cols) {
                const cells = try a.alloc(Cell, self.cols);
                a.free(self.ring[slot].cells);
                self.ring[slot].cells = cells;
            }
            @memset(self.ring[slot].cells, Cell.blank);
            self.ring[slot].wrapped = false;
            self.ring[slot].wrap_padding = false;
            self.len += 1;
            return;
        }
        // Evict oldest row and reuse its cell slice in O(1).
        const reuse = &self.ring[self.head];
        if (reuse.cells.len != self.cols) {
            const cells = try a.alloc(Cell, self.cols);
            a.free(reuse.cells);
            reuse.cells = cells;
        }
        @memset(reuse.cells, Cell.blank);
        reuse.wrapped = false;
        reuse.wrap_padding = false;
        self.head = (self.head + 1) % self.capacity;
        self.evicted += 1;
    }

    /// Scrolls the active scroll region `[scroll_top..=scroll_bottom]` up by `count` rows.
    /// When the region covers the full viewport, top rows roll cleanly into scrollback.
    pub fn scrollUp(self: *Screen, a: std.mem.Allocator, count: usize, clear_cell: Cell) !void {
        const n = @min(count, self.scroll_bottom - self.scroll_top + 1);
        if (n == 0) return;
        if (self.scroll_top == 0 and self.scroll_bottom == self.rows - 1) {
            for (0..n) |_| {
                try self.pushBlankRow(a);
                if (!std.meta.eql(clear_cell, Cell.blank)) {
                    @memset(self.viewRow(self.rows - 1).cells, clear_cell);
                }
            }
            return;
        }
        const base = self.viewBase();
        var r = self.scroll_top;
        while (r + n <= self.scroll_bottom) : (r += 1) {
            const dst = self.rowPtr(base + r);
            const src = self.rowPtr(base + r + n);
            @memcpy(dst.cells, src.cells);
            dst.wrapped = src.wrapped;
            dst.wrap_padding = src.wrap_padding;
        }
        while (r <= self.scroll_bottom) : (r += 1) {
            const dst = self.rowPtr(base + r);
            @memset(dst.cells, clear_cell);
            dst.wrapped = false;
            dst.wrap_padding = false;
        }
    }

    /// Scrolls the active scroll region `[scroll_top..=scroll_bottom]` down by `count` rows.
    pub fn scrollDown(self: *Screen, count: usize, clear_cell: Cell) void {
        const n = @min(count, self.scroll_bottom - self.scroll_top + 1);
        if (n == 0) return;
        const base = self.viewBase();
        var r = self.scroll_bottom;
        while (r >= self.scroll_top + n) : (r -= 1) {
            const dst = self.rowPtr(base + r);
            const src = self.rowPtr(base + r - n);
            @memcpy(dst.cells, src.cells);
            dst.wrapped = src.wrapped;
            dst.wrap_padding = src.wrap_padding;
            if (r == self.scroll_top + n) break;
        }
        for (self.scroll_top..self.scroll_top + n) |row_idx| {
            const dst = self.rowPtr(base + row_idx);
            @memset(dst.cells, clear_cell);
            dst.wrapped = false;
            dst.wrap_padding = false;
        }
    }

    pub fn insertLines(self: *Screen, at_y: usize, count: usize, clear_cell: Cell) void {
        if (at_y < self.scroll_top or at_y > self.scroll_bottom) return;
        const saved_top = self.scroll_top;
        self.scroll_top = at_y;
        self.scrollDown(count, clear_cell);
        self.scroll_top = saved_top;
    }

    pub fn deleteLines(self: *Screen, a: std.mem.Allocator, at_y: usize, count: usize, clear_cell: Cell) !void {
        if (at_y < self.scroll_top or at_y > self.scroll_bottom) return;
        const n = @min(count, self.scroll_bottom - at_y + 1);
        const base = self.viewBase();
        var r = at_y;
        while (r + n <= self.scroll_bottom) : (r += 1) {
            const dst = self.rowPtr(base + r);
            const src = self.rowPtr(base + r + n);
            @memcpy(dst.cells, src.cells);
            dst.wrapped = src.wrapped;
            dst.wrap_padding = src.wrap_padding;
        }
        while (r <= self.scroll_bottom) : (r += 1) {
            const dst = self.rowPtr(base + r);
            @memset(dst.cells, clear_cell);
            dst.wrapped = false;
            dst.wrap_padding = false;
        }
        _ = a;
    }

    pub fn clearAll(self: *Screen, clear_scrollback: bool) void {
        const base = self.viewBase();
        for (base..self.len) |i| {
            const row = self.rowPtr(i);
            @memset(row.cells, Cell.blank);
            row.wrapped = false;
            row.wrap_padding = false;
        }
        if (clear_scrollback) {
            self.head = (self.head + base) % self.capacity;
            self.evicted += self.len;
            self.len = self.rows;
        }
    }

    /// Keeps the cursor's source row visible. Historical rows retain their
    /// original column count so narrowing the dock cannot truncate copied text.
    pub fn resize(self: *Screen, a: std.mem.Allocator, cols: usize, rows: usize, cursor_row: usize) !usize {
        if (cols == self.cols and rows == self.rows) return cursor_row;
        const cursor = self.viewBase() + cursor_row;
        const trim = @min(self.rows -| rows, self.len -| (cursor + rows));
        const retained_end = self.len - trim;
        const capacity = @max(rows, self.history_limit);
        const first = retained_end -| capacity;
        const retained = retained_end - first;
        const len = @max(retained, rows);
        const new_base = len - rows;

        const ring = try a.alloc(Row, capacity);
        errdefer a.free(ring);
        @memset(ring, .{});
        var prepared: usize = 0;
        errdefer for (ring[0..prepared], 0..) |row, i| {
            if (i >= retained or row.cells.ptr != self.rowConst(first + i).cells.ptr) a.free(row.cells);
        };
        while (prepared < len) : (prepared += 1) {
            const source: Row = if (prepared < retained) self.rowConst(first + prepared).* else .{};
            if (prepared < new_base or source.cells.len == cols) {
                ring[prepared] = source;
                continue;
            }
            const cells = try a.alloc(Cell, cols);
            @memset(cells, Cell.blank);
            const copied = @min(cols, source.cells.len);
            @memcpy(cells[0..copied], source.cells[0..copied]);
            if (cells[cols - 1].style.wide_lead) cells[cols - 1] = Cell.blank;
            ring[prepared] = .{ .cells = cells, .wrapped = source.wrapped, .wrap_padding = source.wrap_padding and cols == source.cells.len };
        }
        for (0..self.capacity) |i| {
            const source = self.ring[(self.head + i) % self.capacity];
            if (i < first or i >= retained_end or source.cells.ptr != ring[i - first].cells.ptr) {
                a.free(source.cells);
            }
        }
        a.free(self.ring);
        self.* = .{
            .cols = cols,
            .rows = rows,
            .capacity = capacity,
            .history_limit = self.history_limit,
            .ring = ring,
            .len = len,
            .evicted = self.evicted + if (trim != 0) self.len else first,
            .scroll_bottom = rows - 1,
        };
        return @min(rows - 1, (cursor -| first) -| new_base);
    }
};
