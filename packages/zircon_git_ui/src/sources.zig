//! Git excerpts retain only hunk context in live documents. Adjacent ranges
//! merge so a source line never appears twice in the editing projection.

const std = @import("std");
const git = @import("zircon_git");
const text = @import("zircon_text");
pub fn ranges(a: std.mem.Allocator, snapshot: text.Snapshot, hunks: []const git.Hunk, path: []const u8) ![]text.Range {
    var result: std.ArrayList(text.Range) = .empty;
    errdefer result.deinit(a);
    for (hunks) |hunk| {
        if (!std.mem.eql(u8, hunk.path, path)) continue;
        const first = @min(hunk.new_start -| 1, snapshot.lineCount() - 1);
        const end_row = @min(snapshot.lineCount(), first + hunk.new_count);
        const range: text.Range = .{
            .start = try snapshot.lineStart(first),
            .end = if (end_row < snapshot.lineCount()) try snapshot.lineStart(end_row) else snapshot.byteLen(),
        };
        if (result.items.len > 0 and result.items[result.items.len - 1].end >= range.start) {
            result.items[result.items.len - 1].end = @max(result.items[result.items.len - 1].end, range.end);
        } else try result.append(a, range);
    }
    return result.toOwnedSlice(a);
}
