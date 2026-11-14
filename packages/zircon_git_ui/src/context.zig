//! Context expansion uses captured comparison text, never the current contents
//! of a historical file. Expanded row counts persist with each presentation.

const std = @import("std");
const git = @import("zircon_git");
const layout = @import("layout.zig");
pub fn attach(diff: *git.Diff, path: []const u8, bytes: []const u8) !void {
    if (bytes.len > 8 * 1024 * 1024) return;
    if (!std.unicode.utf8ValidateSlice(bytes) or std.mem.indexOfScalar(u8, bytes, 0) != null) return;
    const a = diff.arena.allocator();
    const owned = try a.dupe(u8, bytes);
    var lines: std.ArrayList([]const u8) = .empty;
    var start: usize = 0;
    for (owned, 0..) |byte, index| if (byte == '\n') {
        try lines.append(a, owned[start..index]);
        start = index + 1;
    };
    if (start < owned.len) try lines.append(a, owned[start..]);
    const sources = try a.alloc(@typeInfo(@TypeOf(diff.context_sources)).pointer.child, diff.context_sources.len + 1);
    @memcpy(sources[0..diff.context_sources.len], diff.context_sources);
    sources[sources.len - 1] = .{ .path = try a.dupe(u8, path), .bytes = owned, .lines = lines.items };
    diff.context_sources = sources;
}

pub fn apply(diff: *git.Diff, state: *const layout.State) !void {
    return applyFile(diff, state, null);
}
pub fn applyFile(diff: *git.Diff, state: *const layout.State, path: ?[]const u8) !void {
    if (state.context.count() == 0) return;
    const a = diff.arena.allocator();
    const hunks = try a.dupe(git.Hunk, diff.hunks);
    for (hunks, 0..) |*hunk, index| {
        if (path) |selected| if (!std.mem.eql(u8, selected, hunk.path)) continue;
        const key = try layout.contextKey(a, hunk.*);
        const amount = state.context.get(key) orelse continue;
        const source = for (diff.context_sources) |source| {
            if (std.mem.eql(u8, source.path, hunk.path)) break source;
        } else continue;
        if (hunk.lines.len == 0 or hunk.lines[0].kind == .metadata) continue;
        if (hunk.original == null) hunk.original = .{ .old_start = hunk.old_start, .old_count = hunk.old_count, .new_start = hunk.new_start, .new_count = hunk.new_count };
        const original = hunk.original.?;
        const start = if (hunk.new_count == 0) hunk.new_start else hunk.new_start -| 1;
        const end = start + hunk.new_count;
        const old_start = if (hunk.old_count == 0) hunk.old_start else hunk.old_start -| 1;
        const original_start = if (original.new_count == 0) original.new_start else original.new_start -| 1;
        var first = original_start -| amount.above;
        var last = @min(source.lines.len, original_start + original.new_count +| amount.below);
        if (index > 0 and std.mem.eql(u8, hunks[index - 1].path, hunk.path)) {
            const previous = hunks[index - 1];
            first = @max(first, layout.hunkStart(previous) + previous.new_count);
        }
        if (index + 1 < hunks.len and std.mem.eql(u8, hunks[index + 1].path, hunk.path)) last = @min(last, layout.hunkStart(hunks[index + 1]));
        first = @min(first, start);
        last = @max(last, end);
        if (first == start and last == end) continue;
        const prefix = start - first;
        const suffix = last - end;
        if (prefix > old_start or last > source.lines.len) continue;
        const no_newline = suffix > 0 and last == source.lines.len and !std.mem.endsWith(u8, source.bytes, "\n");
        const lines = try a.alloc(git.Line, prefix + hunk.lines.len + suffix + @intFromBool(no_newline));
        for (0..prefix) |n| lines[n] = .{ .kind = .context, .text = source.lines[first + n], .old_line = old_start - prefix + n + 1, .new_line = first + n + 1 };
        @memcpy(lines[prefix..][0..hunk.lines.len], hunk.lines);
        for (0..suffix) |n| lines[prefix + hunk.lines.len + n] = .{ .kind = .context, .text = source.lines[end + n], .old_line = old_start + hunk.old_count + n + 1, .new_line = end + n + 1 };
        if (no_newline) lines[lines.len - 1] = .{ .kind = .metadata, .text = "\\ No newline at end of file" };
        hunk.original = original;
        hunk.lines = lines;
        hunk.old_start = old_start - prefix + 1;
        hunk.new_start = first + 1;
        hunk.old_count += prefix + suffix;
        hunk.new_count += prefix + suffix;
    }
    diff.hunks = hunks;
}
