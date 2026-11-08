//! Clipboard text comes from the patch's actual changed lines, without prefixes.

const std = @import("std");
const git = @import("zircon_git");
pub const Side = enum { added, deleted };

pub fn copyText(a: std.mem.Allocator, hunk: git.Hunk, side: Side) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(a);
    for (hunk.lines, 0..) |line, i| {
        const kind: @FieldType(git.Line, "kind") = if (side == .added) .addition else .deletion;
        if (line.kind != kind) continue;
        try bytes.appendSlice(a, line.text);
        const no_newline = i + 1 < hunk.lines.len and hunk.lines[i + 1].kind == .metadata and std.mem.indexOf(u8, hunk.lines[i + 1].text, "No newline") != null;
        if (!no_newline) try bytes.append(a, '\n');
    }
    return bytes.toOwnedSlice(a);
}
