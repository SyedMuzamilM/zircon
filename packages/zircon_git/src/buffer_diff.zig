//! Build ordinary numbered hunks from unsaved source text. The bounded line
//! comparison is shared with gutters; no file is saved to compute this patch.
const std = @import("std");
const diff = @import("diff.zig");
pub const Buffer = struct { path: []const u8, before: []const u8, after: []const u8 };

pub fn fromText(a: std.mem.Allocator, input: Buffer) !diff.Diff {
    var arena = std.heap.ArenaAllocator.init(a);
    errdefer arena.deinit();
    var hunks: std.ArrayList(diff.Hunk) = .empty;
    try appendBufferHunks(a, arena.allocator(), &hunks, input);
    return .{ .arena = arena, .text = if (hunks.items.len == 0) "" else "Unsaved source changes", .hunks = hunks.items };
}

fn appendBufferHunks(allocator: std.mem.Allocator, output: std.mem.Allocator, hunks: *std.ArrayList(diff.Hunk), input: Buffer) !void {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const aa = scratch.allocator();
    const changes = try diff.diffLines(aa, input.before, input.after);
    if (changes.len == 0) return;
    const before = try lines(aa, input.before);
    const after = try lines(aa, input.after);
    const path = try output.dupe(u8, input.path);
    var i: usize = 0;
    while (i < changes.len) {
        const first = i;
        const old_start = changes[i].old_start -| 3;
        const new_start = changes[i].start -| 3;
        var old_end = @min(before.len, changes[i].old_end +| 3);
        var new_end = @min(after.len, changes[i].end +| 3);
        i += 1;
        while (i < changes.len and changes[i].old_start -| 3 <= old_end) : (i += 1) {
            old_end = @min(before.len, changes[i].old_end +| 3);
            new_end = @min(after.len, changes[i].end +| 3);
        }
        var rows: std.ArrayList(diff.Line) = .empty;
        var old = old_start;
        var new = new_start;
        for (changes[first..i]) |change| {
            while (old < change.old_start and new < change.start) {
                try rows.append(output, .{ .kind = .context, .text = try output.dupe(u8, before[old]), .old_line = old + 1, .new_line = new + 1 });
                old += 1;
                new += 1;
            }
            while (old < change.old_end) : (old += 1) try rows.append(output, .{ .kind = .deletion, .text = try output.dupe(u8, before[old]), .old_line = old + 1 });
            while (new < change.end) : (new += 1) try rows.append(output, .{ .kind = .addition, .text = try output.dupe(u8, after[new]), .new_line = new + 1 });
        }
        while (old < old_end and new < new_end) {
            try rows.append(output, .{ .kind = .context, .text = try output.dupe(u8, before[old]), .old_line = old + 1, .new_line = new + 1 });
            old += 1;
            new += 1;
        }
        const old_count = old_end - old_start;
        const new_count = new_end - new_start;
        try hunks.append(output, .{ .path = path, .old_start = if (old_count == 0) old_start else old_start + 1, .old_count = old_count, .new_start = if (new_count == 0) new_start else new_start + 1, .new_count = new_count, .header = try std.fmt.allocPrint(output, "@@ -{d},{d} +{d},{d} @@", .{ if (old_count == 0) old_start else old_start + 1, old_count, if (new_count == 0) new_start else new_start + 1, new_count }), .lines = rows.items });
    }
}

pub fn replace(a: std.mem.Allocator, original: diff.Diff, replacements: []const Buffer) !diff.Diff {
    var arena = std.heap.ArenaAllocator.init(a);
    errdefer arena.deinit();
    const aa = arena.allocator();
    var hunks: std.ArrayList(diff.Hunk) = .empty;
    for (original.hunks) |hunk| {
        var overridden = false;
        for (replacements) |input| if (std.mem.eql(u8, input.path, hunk.path)) {
            overridden = true;
            break;
        };
        if (!overridden) try append(aa, &hunks, hunk);
    }
    for (replacements) |input| try appendBufferHunks(a, aa, &hunks, input);
    // Path ordering is independent of tab order and worker completion order.
    std.mem.sort(diff.Hunk, hunks.items, {}, struct {
        fn less(_: void, left: diff.Hunk, right: diff.Hunk) bool {
            const order = std.mem.order(u8, left.path, right.path);
            return order == .lt or (order == .eq and left.new_start < right.new_start);
        }
    }.less);
    return .{ .arena = arena, .text = if (hunks.items.len == 0) "" else try aa.dupe(u8, if (original.text.len > 0) original.text else "Unsaved source changes"), .hunks = hunks.items };
}
fn append(a: std.mem.Allocator, out: *std.ArrayList(diff.Hunk), input: diff.Hunk) !void {
    var hunk = input;
    hunk.path = try a.dupe(u8, input.path);
    hunk.header = try a.dupe(u8, input.header);
    const rows = try a.dupe(diff.Line, input.lines);
    for (rows) |*row| row.text = try a.dupe(u8, row.text);
    hunk.lines = rows;
    try out.append(a, hunk);
}
fn lines(a: std.mem.Allocator, bytes: []const u8) ![]const []const u8 {
    var result: std.ArrayList([]const u8) = .empty;
    var from: usize = 0;
    while (std.mem.indexOfScalarPos(u8, bytes, from, '\n')) |end| {
        const content_end = if (end > from and bytes[end - 1] == '\r') end - 1 else end;
        try result.append(a, bytes[from..content_end]);
        from = end + 1;
    }
    if (from < bytes.len) try result.append(a, bytes[from..]);
    return result.items;
}
