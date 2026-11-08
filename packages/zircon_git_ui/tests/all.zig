const std = @import("std");
const git = @import("zircon_git");
const gui = @import("zircon_git_ui");
const multi = @import("zircon_multibuffer");
const text = @import("zircon_text");
const workspace = @import("zircon_workspace");
const t = std.testing;
const patch = "diff --git a/a.zig b/a.zig\n--- a/a.zig\n+++ b/a.zig\n@@ -2,2 +2,3 @@\n same\n-old\n+new\n+extra\ndiff --git a/b.zig b/b.zig\n--- a/b.zig\n+++ b/b.zig\n@@ -1 +1 @@\n-no\n+yes\n";

test "Git excerpts map only visible source ranges and refuse edits across files" {
    var diff = try git.parseDiff(t.allocator, patch);
    defer diff.deinit();
    var doc = try text.Document.init(t.allocator, "hidden\nsame\nnew\nextra\nunseen\n");
    defer doc.deinit();
    var snapshot = doc.snapshot();
    defer snapshot.deinit();
    const ranges = try gui.sources.ranges(t.allocator, snapshot, diff.hunks, "a.zig");
    defer t.allocator.free(ranges);
    try t.expectEqual(@as(usize, 1), ranges.len);
    try t.expectEqual(try snapshot.lineStart(1), ranges[0].start);
    try t.expectEqual(try snapshot.lineStart(4), ranges[0].end);
    var other = try text.Document.init(t.allocator, "yes\n");
    defer other.deinit();
    var other_snapshot = other.snapshot();
    defer other_snapshot.deinit();
    var projection = multi.MultiBuffer.init(t.allocator);
    defer projection.deinit();
    const first: workspace.DocumentId = .{ .workspace = 1, .slot = 0, .generation = 1 };
    const second: workspace.DocumentId = .{ .workspace = 1, .slot = 1, .generation = 1 };
    try projection.setSources(&.{
        .{ .source = first, .snapshot = snapshot, .excerpts = ranges },
        .{ .source = second, .snapshot = other_snapshot, .excerpts = &.{.{ .start = 0, .end = 4 }} },
    });
    const bytes = try projection.read(t.allocator);
    defer t.allocator.free(bytes);
    try t.expectEqualStrings("same\nnew\nextra\n\nyes\n", bytes);
    const edit = try projection.edit(.{ .start = 5, .end = 8 }, "NEW");
    try t.expectEqual(first, edit.source);
    try t.expectEqual(try snapshot.lineStart(2), edit.range.start);
    try t.expectError(error.CrossExcerptEdit, projection.edit(.{ .start = 12, .end = bytes.len }, ""));
}

test "split hit testing skips old rows and collapse uses the exact rendered height" {
    var diff = try git.parseDiff(t.allocator, patch);
    defer diff.deinit();
    var projection = try gui.layout.Projection.init(t.allocator, diff);
    defer projection.deinit();
    var state: gui.layout.State = .{};
    defer state.deinit(t.allocator);
    const lh: f32 = 20;
    const start = gui.layout.file_height + gui.layout.context_height;
    try t.expect(projection.hit(diff, &state, lh, start + lh + 1) == null);
    const added = projection.hit(diff, &state, lh, start + lh * 2 + 1).?;
    try t.expectEqual(@as(usize, 2), added.source_row);
    state.mode = .split;
    const split = projection.hit(diff, &state, lh, start + lh + 1).?;
    try t.expectEqual(@as(usize, 2), split.source_row);
    try t.expectEqualStrings("a.zig", split.path);
    try t.expectEqual(start + lh, projection.sourceOffset(diff, &state, "a.zig", 2, lh).?);
    try state.toggle(t.allocator, "a.zig");
    try state.toggle(t.allocator, "b.zig");
    try t.expectEqual(gui.layout.file_height * 2, projection.contentHeight(&state, lh));
    try t.expect(projection.hit(diff, &state, lh, start + 1) == null);
    try t.expectEqual(gui.layout.file_height, projection.fileOffset(&state, "b.zig", lh).?);
}
