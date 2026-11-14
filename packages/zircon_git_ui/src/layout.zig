//! Immutable patch projection built once in the Git worker. View state owns only
//! collapsed path identities; font and viewport changes do not rebuild row maps.
const std = @import("std");
const editor = @import("zircon_editor");
const git = @import("zircon_git");
const ui = @import("zircon_ui");
pub const file_height: f32 = 46;
pub const context_height: f32 = 26;
pub const Mode = enum { unified, split };
pub const Direction = enum { up, down };
pub const ContextAmount = struct { above: usize = 0, below: usize = 0 };
pub const State = struct {
    context: std.StringHashMapUnmanaged(ContextAmount) = .empty,
    mode: Mode = .unified,
    collapsed: std.StringHashMapUnmanaged(void) = .empty,
    active_hunk: ?usize = null,
    hover_file: ?usize = null,
    pub fn deinit(self: *State, a: std.mem.Allocator) void {
        var context_keys = self.context.keyIterator();
        while (context_keys.next()) |key| a.free(key.*);
        self.context.deinit(a);
        var keys = self.collapsed.keyIterator();
        while (keys.next()) |key| a.free(key.*);
        self.collapsed.deinit(a);
    }
    pub fn expandContext(self: *State, a: std.mem.Allocator, hunk: git.Hunk, direction: Direction) !void {
        const key = try contextKey(a, hunk);
        const entry = self.context.getOrPut(a, key) catch |err| {
            a.free(key);
            return err;
        };
        if (entry.found_existing) a.free(key) else entry.value_ptr.* = .{};
        if (direction == .up) entry.value_ptr.above +|= 5 else entry.value_ptr.below +|= 5;
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
pub fn contextKey(a: std.mem.Allocator, hunk: git.Hunk) ![]u8 {
    return std.fmt.allocPrint(a, "{s}\x00{d}", .{ hunk.path, if (hunk.original) |original| original.old_start else hunk.old_start });
}
pub fn hunkStart(hunk: git.Hunk) usize {
    return if (hunk.new_count == 0) hunk.new_start else hunk.new_start -| 1;
}
pub const Code = struct { hunk: usize, old: ?usize = null, new: ?usize = null };
pub const Visual = struct {
    before: usize,
    lines: usize = 1,
    old: []const editor.wrap.Row = &.{},
    new: []const editor.wrap.Row = &.{},
};
const Geometry = struct {
    arena: std.heap.ArenaAllocator,
    width: f32 = -1,
    font: f32 = 0,
    tabs: usize = 0,
    mode: Mode = .unified,
    wrapping: bool = false,
    numbers: bool = true,
};
pub const Row = struct {
    direction: Direction = .up,
    visual: ?*Visual = null,
    code_before: usize,
    headers_before: usize,
    kind: union(enum) { hunk: usize, code: Code },
    pub fn top(self: Row, line_height: f32) f32 {
        return @as(f32, @floatFromInt(if (self.visual) |v| v.before else self.code_before)) * line_height + @as(f32, @floatFromInt(self.headers_before)) * context_height;
    }
    pub fn height(self: Row, line_height: f32) f32 {
        return if (self.kind == .hunk) context_height else line_height * @as(f32, @floatFromInt(if (self.visual) |v| v.lines else 1));
    }
};
pub const File = struct {
    arena: std.heap.ArenaAllocator,
    geometry: *Geometry,
    path: []const u8,
    first_hunk: usize,
    end_hunk: usize,
    max_line: usize = 1,
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
    files: []File,
    pub fn init(a: std.mem.Allocator, diff: git.Diff) !Projection {
        var arena = std.heap.ArenaAllocator.init(a);
        errdefer arena.deinit();
        const aa = arena.allocator();
        var files: std.ArrayList(File) = .empty;
        errdefer for (files.items) |*file| deinitFile(file);
        var first: usize = 0;
        while (first < diff.hunks.len) {
            var end = first + 1;
            while (end < diff.hunks.len and std.mem.eql(u8, diff.hunks[first].path, diff.hunks[end].path)) : (end += 1) {}
            var file = try projectFile(a, diff, first, end);
            errdefer deinitFile(&file);
            try files.append(aa, file);
            first = end;
        }
        return .{ .arena = arena, .files = files.items };
    }
    pub fn deinit(self: *Projection) void {
        for (self.files) |*file| deinitFile(file);
        self.arena.deinit();
    }
    pub fn ensureLayout(self: Projection, diff: git.Diff, state: *const State, width: f32, font: f32, tabs: usize, wrapping: bool, numbers: bool, metrics: ui.layout.Measurer) !bool {
        var changed = false;
        for (self.files) |file| {
            const cache = file.geometry;
            if (cache.width == width and cache.font == font and cache.tabs == tabs and cache.mode == state.mode and cache.wrapping == wrapping and cache.numbers == numbers) continue;
            var next = std.heap.ArenaAllocator.init(cache.arena.child_allocator);
            errdefer next.deinit();
            const aa = next.allocator();
            const Update = struct { target: *Visual, value: Visual };
            var updates: std.ArrayList(Update) = .empty;
            var before: usize = 0;
            const gutter = if (numbers) editor.gutterWidth(file.max_line, font) else 20;
            const available = (if (state.mode == .split) @max(1, (width - 1) / 2) else width) - gutter - 12;
            for (file.rows(state.mode)) |row| {
                var visual: Visual = .{ .before = before };
                if (row.kind != .code) {
                    try updates.append(aa, .{ .target = row.visual.?, .value = visual });
                    continue;
                }
                const code = row.kind.code;
                if (code.old) |at| visual.old = try pieces(aa, diff.hunks[code.hunk].lines[at].text, available, font, tabs, wrapping, metrics);
                if (code.new) |at| visual.new = try pieces(aa, diff.hunks[code.hunk].lines[at].text, available, font, tabs, wrapping, metrics);
                visual.lines = @max(1, @max(visual.old.len, visual.new.len));
                before += visual.lines;
                try updates.append(aa, .{ .target = row.visual.?, .value = visual });
            }
            for (updates.items) |update| update.target.* = update.value;
            cache.arena.deinit();
            cache.* = .{ .arena = next, .width = width, .font = font, .tabs = tabs, .mode = state.mode, .wrapping = wrapping, .numbers = numbers };
            changed = true;
        }
        return changed;
    }
    /// Only the selected file loses its layout cache during context expansion.
    pub fn updateFile(self: *Projection, diff: git.Diff, path: []const u8) !void {
        for (self.files) |*file| if (std.mem.eql(u8, file.path, path)) {
            const next = try projectFile(self.arena.child_allocator, diff, file.first_hunk, file.end_hunk);
            deinitFile(file);
            file.* = next;
            return;
        };
    }
    /// A background diff does not invalidate geometry for unchanged files.
    pub fn reuseLayouts(self: *Projection, previous: *Projection, diff: git.Diff, old_diff: git.Diff) void {
        for (self.files) |*file| for (previous.files) |*old| {
            if (!std.mem.eql(u8, file.path, old.path) or file.end_hunk - file.first_hunk != old.end_hunk - old.first_hunk) continue;
            const same = for (diff.hunks[file.first_hunk..file.end_hunk], old_diff.hunks[old.first_hunk..old.end_hunk]) |left, right| {
                if (left.old_start != right.old_start or left.new_start != right.new_start or left.old_count != right.old_count or left.new_count != right.new_count or left.lines.len != right.lines.len) break false;
                const same_lines = for (left.lines, right.lines) |x, y| {
                    if (x.kind != y.kind or x.old_line != y.old_line or x.new_line != y.new_line or !std.mem.eql(u8, x.text, y.text)) break false;
                } else true;
                if (!same_lines) break false;
            } else true;
            if (!same) break;
            const path = file.path;
            const first = file.first_hunk;
            const count = file.end_hunk - first;
            std.mem.swap(File, file, old);
            const previous_first = file.first_hunk;
            for ([_][]const Row{ file.unified, file.split }) |rows| for (@constCast(rows)) |*row| switch (row.kind) {
                .hunk => |*index| index.* = first + index.* - previous_first,
                .code => |*code| code.hunk = first + code.hunk - previous_first,
            };
            file.path = path;
            file.first_hunk = first;
            file.end_hunk = first + count;
            break;
        };
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
                for (file.rows(state.mode)) |row| {
                    const matches = switch (row.kind) {
                        .hunk => |index| index == hunk and row.direction == .up,
                        .code => |code| code.hunk == hunk,
                    };
                    if (matches) return top + file_height + row.top(line_height);
                }
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
fn deinitFile(file: *File) void {
    file.geometry.arena.deinit();
    file.arena.deinit();
}
fn projectFile(a: std.mem.Allocator, diff: git.Diff, first: usize, end: usize) !File {
    var arena = std.heap.ArenaAllocator.init(a);
    errdefer arena.deinit();
    const aa = arena.allocator();
    const geometry = try aa.create(Geometry);
    geometry.* = .{ .arena = .init(a) };
    var file: File = .{ .arena = arena, .geometry = geometry, .path = diff.hunks[first].path, .first_hunk = first, .end_hunk = end, .unified = &.{}, .split = &.{} };
    for (diff.hunks[first..end]) |hunk| for (hunk.lines) |line| {
        file.max_line = @max(file.max_line, @max(line.old_line orelse 0, line.new_line orelse 0));
        file.added += @intFromBool(line.kind == .addition);
        file.deleted += @intFromBool(line.kind == .deletion);
    };
    for (diff.context_sources) |source| if (std.mem.eql(u8, source.path, file.path)) {
        file.max_line = @max(file.max_line, source.lines.len + 1);
    };
    file.unified = try project(aa, diff, first, end, .unified);
    file.split = try project(aa, diff, first, end, .split);
    file.arena = arena;
    return file;
}
fn project(a: std.mem.Allocator, diff: git.Diff, first: usize, end: usize, mode: Mode) ![]const Row {
    var rows: std.ArrayList(Row) = .empty;
    var codes: usize = 0;
    var headers: usize = 0;
    for (first..end) |hunk_index| {
        const hunk = diff.hunks[hunk_index];
        const previous_end = if (hunk_index > first) hunkStart(diff.hunks[hunk_index - 1]) + diff.hunks[hunk_index - 1].new_count else 0;
        if (hunk_index == first or hunkStart(hunk) > previous_end) {
            try rows.append(a, .{ .code_before = codes, .headers_before = headers, .kind = .{ .hunk = hunk_index }, .direction = .up });
            headers += 1;
        }
        const lines = diff.hunks[hunk_index].lines;
        var i: usize = 0;
        while (i < lines.len) {
            if (lines[i].kind == .metadata and std.mem.indexOf(u8, lines[i].text, "No newline") != null) {
                i += 1;
                continue;
            }
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
        const limit = if (hunk_index + 1 < end) hunkStart(diff.hunks[hunk_index + 1]) else for (diff.context_sources) |source| {
            if (std.mem.eql(u8, source.path, hunk.path)) break source.lines.len;
        } else hunkStart(hunk) + hunk.new_count;
        if (hunkStart(hunk) + hunk.new_count < limit) {
            try rows.append(a, .{ .code_before = codes, .headers_before = headers, .kind = .{ .hunk = hunk_index }, .direction = .down });
            headers += 1;
        }
    }
    for (rows.items) |*row| {
        const visual = try a.create(Visual);
        visual.* = .{ .before = row.code_before };
        row.visual = visual;
    }
    return rows.items;
}

fn pieces(a: std.mem.Allocator, bytes: []const u8, width: f32, font: f32, tabs: usize, wrapping: bool, metrics: ui.layout.Measurer) ![]const editor.wrap.Row {
    const safe = if (bytes.len > 65536 or !std.unicode.utf8ValidateSlice(bytes)) "" else std.mem.trimEnd(u8, bytes, "\r");
    if (wrapping) return editor.wrap.segments(a, safe, 0, width, font, tabs, metrics);
    const result = try a.alloc(editor.wrap.Row, 1);
    result[0] = .{ .line = 0, .start = 0, .end = safe.len, .x = 0, .first = true };
    return result;
}
