//! Immutable patch projection built once in the Git worker. View state owns only
//! collapsed path identities; font and viewport changes do not rebuild row maps.
const std = @import("std");
const git = @import("zircon_git");
pub const file_height: f32 = 46;
pub const context_height: f32 = 26;
pub const Mode = enum { unified, split };
pub const State = struct {
    mode: Mode = .unified,
    collapsed: std.StringHashMapUnmanaged(void) = .empty,
    active_hunk: ?usize = null,
    hover_file: ?usize = null,
    pub fn deinit(self: *State, a: std.mem.Allocator) void {
        var keys = self.collapsed.keyIterator();
        while (keys.next()) |key| a.free(key.*);
        self.collapsed.deinit(a);
    }
    pub fn toggle(self: *State, a: std.mem.Allocator, path: []const u8) !void {
        if (self.collapsed.fetchRemove(path)) |entry| a.free(entry.key) else {
            const owned = try a.dupe(u8, path);
            errdefer a.free(owned);
            try self.collapsed.put(a, owned, {});
        }
    }
    pub fn expandAll(self: *State, a: std.mem.Allocator) void {
        var keys = self.collapsed.keyIterator();
        while (keys.next()) |key| a.free(key.*);
        self.collapsed.clearRetainingCapacity();
    }
};
pub const Code = struct { hunk: usize, old: ?usize = null, new: ?usize = null };
pub const Row = struct {
    code_before: usize,
    headers_before: usize,
    kind: union(enum) { hunk: usize, code: Code },
    pub fn top(self: Row, line_height: f32) f32 {
        return @as(f32, @floatFromInt(self.code_before)) * line_height + @as(f32, @floatFromInt(self.headers_before)) * context_height;
    }
    pub fn height(self: Row, line_height: f32) f32 {
        return if (self.kind == .hunk) context_height else line_height;
    }
};
pub const File = struct {
    path: []const u8,
    first_hunk: usize,
    end_hunk: usize,
    added: usize = 0,
    deleted: usize = 0,
    unified: []const Row,
    split: []const Row,
    pub fn rows(self: File, mode: Mode) []const Row {
        return if (mode == .unified) self.unified else self.split;
    }
    pub fn height(self: File, state: *const State, line_height: f32) f32 {
        if (state.collapsed.contains(self.path)) return file_height;
        const items = self.rows(state.mode);
        const last = items[items.len - 1];
        return file_height + last.top(line_height) + last.height(line_height);
    }
};
pub const Projection = struct {
    arena: std.heap.ArenaAllocator,
    files: []const File,
    pub fn init(a: std.mem.Allocator, diff: git.Diff) !Projection {
        var arena = std.heap.ArenaAllocator.init(a);
        errdefer arena.deinit();
        const aa = arena.allocator();
        var files: std.ArrayList(File) = .empty;
        var first: usize = 0;
        while (first < diff.hunks.len) {
            var end = first + 1;
            while (end < diff.hunks.len and std.mem.eql(u8, diff.hunks[first].path, diff.hunks[end].path)) : (end += 1) {}
            var file: File = .{ .path = diff.hunks[first].path, .first_hunk = first, .end_hunk = end, .unified = &.{}, .split = &.{} };
            for (diff.hunks[first..end]) |hunk| for (hunk.lines) |line| {
                file.added += @intFromBool(line.kind == .addition);
                file.deleted += @intFromBool(line.kind == .deletion);
            };
            file.unified = try project(aa, diff, first, end, .unified);
            file.split = try project(aa, diff, first, end, .split);
            try files.append(aa, file);
            first = end;
        }
        return .{ .arena = arena, .files = files.items };
    }
    pub fn deinit(self: *Projection) void {
        self.arena.deinit();
    }
    pub fn contentHeight(self: Projection, state: *const State, line_height: f32) f32 {
        var total: f32 = 0;
        for (self.files) |file| total += file.height(state, line_height);
        return total;
    }
    pub fn fileOffset(self: Projection, state: *const State, path: []const u8, line_height: f32) ?f32 {
        var top: f32 = 0;
        for (self.files) |file| {
            if (std.mem.eql(u8, file.path, path)) return top;
            top += file.height(state, line_height);
        }
        return null;
    }
    pub const Hit = struct { path: []const u8, source_row: usize, top: f32 };
    pub fn hit(self: Projection, diff: git.Diff, state: *const State, line_height: f32, y: f32) ?Hit {
        var file_top: f32 = 0;
        for (self.files) |file| {
            const height = file.height(state, line_height);
            defer file_top += height;
            if (y < file_top or y >= file_top + height or state.collapsed.contains(file.path)) continue;
            const local = y - file_top - file_height;
            if (local < 0) return null;
            const rows = file.rows(state.mode);
            const index = visibleStart(rows, line_height, local);
            if (index >= rows.len or rows[index].kind != .code) return null;
            const code = rows[index].kind.code;
            const at = code.new orelse return null;
            const line = diff.hunks[code.hunk].lines[at].new_line orelse return null;
            return .{ .path = file.path, .source_row = line -| 1, .top = file_top + file_height + rows[index].top(line_height) };
        }
        return null;
    }
    /// Adjacent editable row in display order, skipping removed lines, folded
    /// files and undisplayed source gaps.
    pub fn adjacent(self: Projection, diff: git.Diff, state: *const State, path: []const u8, source_row: usize, forward: bool) ?Hit {
        var previous: ?Hit = null;
        var found = false;
        for (self.files) |file| {
            if (state.collapsed.contains(file.path)) continue;
            for (file.rows(state.mode)) |row| {
                if (row.kind != .code) continue;
                const code = row.kind.code;
                const at = code.new orelse continue;
                const number = diff.hunks[code.hunk].lines[at].new_line orelse continue;
                const hit_value: Hit = .{ .path = file.path, .source_row = number -| 1, .top = 0 };
                if (found) return hit_value;
                if (std.mem.eql(u8, path, file.path) and source_row == number -| 1) {
                    if (!forward) return previous;
                    found = true;
                }
                previous = hit_value;
            }
        }
        return null;
    }
    pub fn sourceOffset(self: Projection, diff: git.Diff, state: *const State, path: []const u8, source_row: usize, line_height: f32) ?f32 {
        var top: f32 = 0;
        for (self.files) |file| {
            defer top += file.height(state, line_height);
            if (!std.mem.eql(u8, file.path, path) or state.collapsed.contains(file.path)) continue;
            for (file.rows(state.mode)) |row| if (row.kind == .code) {
                const code = row.kind.code;
                const at = code.new orelse continue;
                const number = diff.hunks[code.hunk].lines[at].new_line orelse continue;
                if (number -| 1 == source_row) return top + file_height + row.top(line_height);
            };
        }
        return null;
    }
    pub fn hunkOffset(self: Projection, state: *const State, hunk: usize, line_height: f32) ?f32 {
        var top: f32 = 0;
        for (self.files) |file| {
            if (hunk >= file.first_hunk and hunk < file.end_hunk) {
                if (state.collapsed.contains(file.path)) return top;
                for (file.rows(state.mode)) |row| if (row.kind == .hunk and row.kind.hunk == hunk) return top + file_height + row.top(line_height);
                return null;
            }
            top += file.height(state, line_height);
        }
        return null;
    }
};
/// First intersecting row, including a partially visible row above the viewport.
pub fn visibleStart(rows: []const Row, line_height: f32, top: f32) usize {
    var lo: usize = 0;
    var hi = rows.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (rows[mid].top(line_height) + rows[mid].height(line_height) <= top) lo = mid + 1 else hi = mid;
    }
    return lo;
}
fn project(a: std.mem.Allocator, diff: git.Diff, first: usize, end: usize, mode: Mode) ![]const Row {
    var rows: std.ArrayList(Row) = .empty;
    var codes: usize = 0;
    var headers: usize = 0;
    for (first..end) |hunk_index| {
        try rows.append(a, .{ .code_before = codes, .headers_before = headers, .kind = .{ .hunk = hunk_index } });
        headers += 1;
        const lines = diff.hunks[hunk_index].lines;
        var i: usize = 0;
        while (i < lines.len) {
            if (mode == .split and lines[i].kind == .deletion) {
                var deletion_end = i;
                while (deletion_end < lines.len and lines[deletion_end].kind == .deletion) : (deletion_end += 1) {}
                var addition_end = deletion_end;
                while (addition_end < lines.len and lines[addition_end].kind == .addition) : (addition_end += 1) {}
                const deletions = deletion_end - i;
                const additions = addition_end - deletion_end;
                for (0..@max(deletions, additions)) |n| {
                    try rows.append(a, .{ .code_before = codes, .headers_before = headers, .kind = .{ .code = .{ .hunk = hunk_index, .old = if (n < deletions) i + n else null, .new = if (n < additions) deletion_end + n else null } } });
                    codes += 1;
                }
                i = addition_end;
                continue;
            }
            const line = lines[i];
            try rows.append(a, .{ .code_before = codes, .headers_before = headers, .kind = .{ .code = .{ .hunk = hunk_index, .old = if (line.kind == .context or line.kind == .deletion) i else null, .new = if (line.kind != .deletion) i else null } } });
            codes += 1;
            i += 1;
        }
    }
    return rows.items;
}
