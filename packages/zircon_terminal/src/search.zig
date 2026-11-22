//! Literal scrollback search across Screen logical lines with per-row highlight spans.

const std = @import("std");
const grid = @import("grid.zig");
pub const Span = struct {
    abs_line: u64,
    start_col: usize,
    end_col: usize,
    match_index: u32,
};

pub const Match = struct {
    abs_line: u64,
    col: usize,
};

pub const Results = struct {
    matches: std.ArrayList(Match) = .empty,
    spans: std.ArrayList(Span) = .empty,
    active: usize = 0,
    truncated: bool = false,

    pub fn deinit(self: *Results, a: std.mem.Allocator) void {
        self.matches.deinit(a);
        self.spans.deinit(a);
        self.* = .{};
    }

    pub fn clear(self: *Results) void {
        self.matches.clearRetainingCapacity();
        self.spans.clearRetainingCapacity();
        self.active = 0;
        self.truncated = false;
    }

    pub fn count(self: *const Results) usize {
        return self.matches.items.len;
    }

    pub fn current(self: *const Results) ?Match {
        if (self.matches.items.len == 0) return null;
        return self.matches.items[@min(self.active, self.matches.items.len - 1)];
    }

    pub fn step(self: *Results, forward: bool) ?Match {
        const n = self.matches.items.len;
        if (n == 0) return null;
        self.active = if (forward) (self.active + 1) % n else (self.active + n - 1) % n;
        return self.matches.items[self.active];
    }

    /// Returns the slice of highlight spans on `abs_line` via binary search.
    pub fn spansOnLine(self: *const Results, abs_line: u64) []const Span {
        const items = self.spans.items;
        const lo = firstSpanOnLine(items, abs_line);
        var end = lo;
        while (end < items.len and items[end].abs_line == abs_line) : (end += 1) {}
        return items[lo..end];
    }
};

pub fn firstSpanOnLine(items: []const Span, abs_line: u64) usize {
    var lo: usize = 0;
    var hi: usize = items.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (items[mid].abs_line < abs_line) lo = mid + 1 else hi = mid;
    }
    return lo;
}

const CellPos = struct { abs_line: u64, col: usize, width: usize };

pub fn findAll(a: std.mem.Allocator, screen: *const grid.Screen, query: []const u8, case_sensitive: bool, out: *Results) !void {
    out.clear();
    if (query.len == 0 or screen.len == 0) return;
    // A failure table and a sliding cell window keep memory proportional to
    // the query even when a single logical line spans the entire history.
    const needle = if (case_sensitive) query else try lowerAscii(a, query);
    defer if (!case_sensitive) a.free(needle);
    const prefix = try a.alloc(usize, needle.len);
    defer a.free(prefix);
    prefix[0] = 0;
    for (1..needle.len) |i| prefix[i] = advance(needle, prefix, prefix[i - 1], needle[i]);
    const positions = try a.alloc(CellPos, needle.len);
    defer a.free(positions);

    defer if (out.matches.items.len > 0) {
        out.active = out.matches.items.len - 1;
    };
    var matched: usize = 0;
    var next: usize = 0;
    for (0..screen.len) |logical| {
        const row = screen.rowConst(logical);
        const abs_line = screen.absLineForLogical(logical);
        var end_col = row.cells.len - @intFromBool(row.wrapped and row.wrap_padding);
        if (!row.wrapped) {
            while (end_col > 0 and row.cells[end_col - 1].code == ' ' and !row.cells[end_col - 1].style.wide_trail) : (end_col -= 1) {}
        }
        for (row.cells[0..end_col], 0..) |cell, col| {
            if (cell.style.wide_trail) continue;
            var encoded: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(cell.code, &encoded) catch continue;
            for (encoded[0..len]) |byte| {
                positions[next] = .{ .abs_line = abs_line, .col = col, .width = if (cell.style.wide_lead) 2 else 1 };
                next = (next + 1) % positions.len;
                matched = advance(needle, prefix, matched, if (case_sensitive) byte else std.ascii.toLower(byte));
                if (matched == needle.len) {
                    if (out.matches.items.len == 50_000) {
                        out.truncated = true;
                        return;
                    }
                    try recordMatch(a, out, positions, next);
                    matched = 0;
                }
            }
        }
        if (!row.wrapped) matched = 0;
    }
}

fn advance(needle: []const u8, prefix: []const usize, current: usize, byte: u8) usize {
    var matched = current;
    while (matched != 0 and needle[matched] != byte) matched = prefix[matched - 1];
    return matched + @intFromBool(needle[matched] == byte);
}

fn recordMatch(a: std.mem.Allocator, out: *Results, positions: []const CellPos, first: usize) !void {
    const start = positions[first];
    const index: u32 = @intCast(out.matches.items.len);
    try out.matches.append(a, .{ .abs_line = start.abs_line, .col = start.col });
    var span: Span = .{ .abs_line = start.abs_line, .start_col = start.col, .end_col = start.col + start.width, .match_index = index };
    for (1..positions.len) |i| {
        const point = positions[(first + i) % positions.len];
        if (point.abs_line != span.abs_line) {
            try out.spans.append(a, span);
            span.abs_line = point.abs_line;
            span.start_col = point.col;
        }
        span.end_col = point.col + point.width;
    }
    try out.spans.append(a, span);
}

fn lowerAscii(a: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const copy = try a.alloc(u8, bytes.len);
    for (bytes, copy) |byte, *target| target.* = std.ascii.toLower(byte);
    return copy;
}
