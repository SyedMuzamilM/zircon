//! Fixtures for numbered Git patches, status records, blame and bounded line diffs.
const std = @import("std");
const diff = @import("diff.zig");
const history = @import("history.zig");
const status = @import("status.zig");
const t = std.testing;
test "history hunks retain separate file headings including spaces and deletions" {
    var patch = try diff.parse(t.allocator, "diff --git a/first file.zig b/first file.zig\n--- a/first file.zig\n+++ b/first file.zig\n@@ -1 +1 @@\n-old\n+new\n" ++
        "diff --git a/deleted.zig b/deleted.zig\n--- a/deleted.zig\n+++ /dev/null\n@@ -1 +0,0 @@\n-gone\n" ++
        "diff --git a/new.zig b/new.zig\n--- /dev/null\n+++ b/new.zig\n@@ -0,0 +1 @@\n+added\n");
    defer patch.deinit();
    try t.expectEqual(@as(usize, 3), patch.hunks.len);
    try t.expectEqualStrings("first file.zig", patch.hunks[0].path);
    try t.expectEqualStrings("deleted.zig", patch.hunks[1].path);
    try t.expectEqualStrings("new.zig", patch.hunks[2].path);
    try t.expectEqual(@as(?usize, 1), patch.hunks[0].lines[0].old_line);
    try t.expectEqual(@as(?usize, 1), patch.hunks[0].lines[1].new_line);
}
test "machine parsers retain path bytes and release allocation failures" {
    try t.checkAllAllocationFailures(t.allocator, allocationCase, .{});
}

test "diff parser decodes Git path delimiters and quoted escapes" {
    var patch = try diff.parse(t.allocator, "diff --git a/space name.txt b/space name.txt\n" ++
        "--- a/space name.txt\t\n+++ b/space name.txt\t\n@@ -1 +1 @@\n-old\n+new\n" ++
        "diff --git \"a/line\\nname.txt\" \"b/line\\nname.txt\"\n" ++
        "--- \"a/line\\nname.txt\"\n+++ \"b/line\\nname.txt\"\n@@ -1 +1 @@\n-old\n+new\n");
    defer patch.deinit();
    try t.expectEqualStrings("space name.txt", patch.hunks[0].path);
    try t.expectEqualStrings("line\nname.txt", patch.hunks[1].path);
}
fn allocationCase(a: std.mem.Allocator) !void {
    var state = try status.parse(a, "## main\x00R  new\n日.txt\x00old name.txt\x00?? new.txt\x00");
    defer state.deinit();
    try t.expectEqualStrings("old name.txt", state.entries[0].old_path.?);
    var conflict = try status.parse(a, "## main\x00AA conflict.txt\x00");
    defer conflict.deinit();
    try t.expect(conflict.entries[0].conflicted);
    var patch = try diff.parse(a, "diff --git a/a b/a\n@@ -1,2 +1,2 @@\n first\n-old\n+new\n");
    defer patch.deinit();
    try t.expectEqual(@as(usize, 3), patch.hunks[0].lines.len);
    const commits = try history.parse(a, "0123456789012345678901234567890123456789\x00Author\x00author@example.invalid\x001000\x00Subject\x00\n");
    defer history.deinitHistory(a, commits);
    try t.expectEqual(@as(usize, 1), commits.len);
    var blame = try history.parseBlame(a, "0123456789012345678901234567890123456789 2 3 1\nauthor Name\nauthor-mail <name@example.invalid>\nauthor-time 1000\nsummary Summary\n\tline text\n");
    defer blame.deinit();
    try t.expectEqualStrings("line text", blame.contents);
    const changes = try diff.diffLines(a, "a\nb\nc\n", "a\nnew\nc\n");
    defer a.free(changes);
    try t.expectEqual(@as(usize, 1), changes.len);
}
test "invalid machine data refuses without leaking partial history entries" {
    try t.expectError(error.InvalidGitStatus, status.parse(t.allocator, "M\x00"));
    try t.expectError(error.InvalidGitHistory, history.parse(t.allocator, "0123456789012345678901234567890123456789\x00Author\x00email\x00invalid\x00subject\x00"));
    try t.expectError(error.InvalidGitBlame, history.parseBlame(t.allocator, "not-an-oid 1 1\n"));
    try t.expectError(error.InvalidGitDiff, diff.parse(t.allocator, "@@ -bad +1 @@\n"));
}
test "line changes account for missing final newlines and preserve equal suffixes" {
    const ending = try diff.diffLines(t.allocator, "a\n", "a");
    defer t.allocator.free(ending);
    try t.expectEqual(@as(usize, 1), ending.len);
    try t.expect(ending[0].kind == .modified);
    const beginning = try diff.diffLines(t.allocator, "same\n", "new\nsame\n");
    defer t.allocator.free(beginning);
    try t.expect(beginning[0].kind == .added);
    try t.expectEqual(@as(usize, 0), beginning[0].start);
    const all = try diff.diffLines(t.allocator, "", "a\nb\n");
    defer t.allocator.free(all);
    try t.expectEqual(@as(usize, 2), all[0].end);
}
test "large unrelated blocks use documented bounded conservative range" {
    var before: std.ArrayList(u8) = .empty;
    defer before.deinit(t.allocator);
    var after: std.ArrayList(u8) = .empty;
    defer after.deinit(t.allocator);
    for (0..2000) |_| {
        try before.appendSlice(t.allocator, "before\n");
        try after.appendSlice(t.allocator, "after\n");
    }
    const changed = try diff.diffLines(t.allocator, before.items, after.items);
    defer t.allocator.free(changed);
    try t.expectEqual(@as(usize, 1), changed.len);
    try t.expectEqual(@as(usize, 2000), changed[0].end);
}
