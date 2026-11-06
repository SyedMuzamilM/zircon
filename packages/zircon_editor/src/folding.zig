//! Indentation folding. Regions and collapsed byte ranges are revision-bound.
const std = @import("std");
const text = @import("zircon_text");
pub const Region = struct { start: usize, end: usize, body: usize, line: usize, last: usize };
pub const State = struct {
    regions: std.ArrayList(Region) = .empty,
    collapsed: std.ArrayList(text.Range) = .empty,
    revision: ?u64 = null,
    state_id: u64 = 0,
    tabs: usize = 4,
    pub fn deinit(self: *State, a: std.mem.Allocator) void {
        self.regions.deinit(a);
        self.collapsed.deinit(a);
    }
    pub fn noteChange(self: *State, change: *const text.Change) void {
        for (self.collapsed.items) |*range| {
            range.start = change.map(range.start, .after);
            range.end = change.map(range.end, .after);
        }
        self.revision = null;
    }
    pub fn ensure(self: *State, a: std.mem.Allocator, snapshot: text.Snapshot, tabs: usize) !void {
        if (self.revision == snapshot.revision() and self.state_id == snapshot.stateId() and self.tabs == tabs) return;
        var regions: std.ArrayList(Region) = .empty;
        errdefer regions.deinit(a);
        if (snapshot.byteLen() <= 8 * 1024 * 1024) {
            const source = try snapshot.copy(a, .{ .start = 0, .end = snapshot.byteLen() });
            defer a.free(source);
            const Line = struct { start: usize, end: usize, row: usize, indent: usize, closer: bool };
            var lines: std.ArrayList(Line) = .empty;
            defer lines.deinit(a);
            var at: usize = 0;
            var row: usize = 0;
            var iterator = std.mem.splitScalar(u8, source, '\n');
            while (iterator.next()) |raw| {
                const line = std.mem.trimEnd(u8, raw, "\r");
                var leading: usize = 0;
                var indent: usize = 0;
                while (leading < line.len and (line[leading] == ' ' or line[leading] == '\t')) : (leading += 1) indent += if (line[leading] == '\t') tabs - indent % tabs else 1;
                if (leading < line.len) try lines.append(a, .{ .start = at, .end = at + line.len, .row = row, .indent = indent, .closer = std.mem.indexOfScalar(u8, "}])", line[leading]) != null });
                at += raw.len + 1;
                row += 1;
            }
            var stack: std.ArrayList(usize) = .empty;
            defer stack.deinit(a);
            for (lines.items, 0..) |line, i| {
                while (stack.items.len > 0 and line.indent <= lines.items[stack.items[stack.items.len - 1]].indent) {
                    const header = lines.items[stack.pop().?];
                    const end = if (line.closer and line.indent == header.indent) line else lines.items[i - 1];
                    if (end.row > header.row) try regions.append(a, .{ .start = header.start, .end = end.end, .body = header.end + 1, .line = header.row, .last = end.row });
                }
                if (i + 1 < lines.items.len and lines.items[i + 1].indent > line.indent) try stack.append(a, i);
            }
            while (stack.pop()) |i| {
                const header = lines.items[i];
                const end = lines.items[lines.items.len - 1];
                if (end.row > header.row) try regions.append(a, .{ .start = header.start, .end = end.end, .body = header.end + 1, .line = header.row, .last = end.row });
            }
            const Order = struct {
                fn less(_: void, left: Region, right: Region) bool {
                    return left.line < right.line;
                }
            };
            std.mem.sort(Region, regions.items, {}, Order.less);
        }
        self.regions.deinit(a);
        self.regions = regions;
        var count: usize = 0;
        for (self.collapsed.items) |fold| if (self.atStart(fold.start)) |candidate| {
            self.collapsed.items[count] = .{ .start = candidate.start, .end = candidate.end };
            count += 1;
        };
        self.collapsed.items.len = count;
        self.revision = snapshot.revision();
        self.state_id = snapshot.stateId();
        self.tabs = tabs;
    }
    pub fn region(self: *const State, line: usize) ?Region {
        var lo: usize = 0;
        var hi = self.regions.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.regions.items[mid].line < line) lo = mid + 1 else hi = mid;
        }
        return if (lo < self.regions.items.len and self.regions.items[lo].line == line) self.regions.items[lo] else null;
    }
    pub fn isCollapsed(self: *const State, start: usize) bool {
        for (self.collapsed.items) |range| if (range.start == start) return true;
        return false;
    }
    fn atStart(self: *const State, start: usize) ?Region {
        var lo: usize = 0;
        var hi = self.regions.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.regions.items[mid].start < start) lo = mid + 1 else hi = mid;
        }
        return if (lo < self.regions.items.len and self.regions.items[lo].start == start) self.regions.items[lo] else null;
    }
    pub fn hidden(self: *const State, offset: usize) bool {
        for (self.collapsed.items) |range| if (offset > range.start and offset <= range.end) return true;
        return false;
    }
    pub fn reveal(self: *State, offset: usize) bool {
        var changed = false;
        var i: usize = 0;
        while (i < self.collapsed.items.len) {
            const range = self.collapsed.items[i];
            const body = if (self.atStart(range.start)) |candidate| candidate.body else range.start + 1;
            if (offset >= body and offset <= range.end) {
                _ = self.collapsed.orderedRemove(i);
                changed = true;
            } else i += 1;
        }
        return changed;
    }
    pub fn toggle(self: *State, a: std.mem.Allocator, line: usize) !bool {
        const r = self.region(line) orelse return false;
        for (self.collapsed.items, 0..) |fold, i| if (fold.start == r.start) {
            _ = self.collapsed.orderedRemove(i);
            return true;
        };
        if (self.collapsed.items.len >= 1024) return error.TooManyFolds;
        try self.collapsed.append(a, .{ .start = r.start, .end = r.end });
        const Order = struct {
            fn less(_: void, left: text.Range, right: text.Range) bool {
                return left.start < right.start;
            }
        };
        std.mem.sort(text.Range, self.collapsed.items, {}, Order.less);
        return true;
    }
};
