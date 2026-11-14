const std = @import("std");
const git = @import("zircon_git");
const gui = @import("zircon_git_ui");
const multi = @import("zircon_multibuffer");
const text = @import("zircon_text");
const zircon_ui = @import("zircon_ui");
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

test "review text selects deleted unicode and CRLF text with exact line endings" {
    var diff = try git.parseDiff(t.allocator, "diff --git a/a.txt b/a.txt\n--- a/a.txt\n+++ b/a.txt\n@@ -1,2 +1 @@\n-é🌍\r\n-tail\n\\ No newline at end of file\n+new\n");
    defer diff.deinit();
    var projection = try gui.layout.Projection.init(t.allocator, diff);
    defer projection.deinit();
    var state: gui.layout.State = .{};
    defer state.deinit(t.allocator);
    var review = try gui.review.Review.init(t.allocator, diff, projection, &state, .unified);
    defer review.deinit();
    var snapshot = review.document.snapshot();
    defer snapshot.deinit();
    const bytes = try snapshot.copy(t.allocator, .{ .start = 0, .end = snapshot.byteLen() });
    defer t.allocator.free(bytes);
    try t.expectEqualStrings("é🌍\r\ntail\nnew\n", bytes);
    try review.editor.setSelection(snapshot, .{ .start = 2, .end = "é🌍\r\ntail".len });
    review.focused = true;
    const copied = try snapshot.copy(t.allocator, review.editor.primary().range());
    defer t.allocator.free(copied);
    try t.expectEqualStrings("🌍\r\ntail", copied);
    try t.expectEqual(text.Range{ .start = 2, .end = 8 }, review.selected(0, 0, .unified).?);
    try t.expectEqual(null, review.selected(0, 0, .old));
    try t.expectError(error.InvalidRange, snapshot.validateRange(.{ .start = 3, .end = 4 }));
}

test "split review maps old and new independently and skips padding and collapsed files" {
    var diff = try git.parseDiff(t.allocator, patch);
    defer diff.deinit();
    var projection = try gui.layout.Projection.init(t.allocator, diff);
    defer projection.deinit();
    var state: gui.layout.State = .{ .mode = .split };
    defer state.deinit(t.allocator);
    var old = try gui.review.Review.init(t.allocator, diff, projection, &state, .old);
    defer old.deinit();
    var new = try gui.review.Review.init(t.allocator, diff, projection, &state, .new);
    defer new.deinit();
    var old_snapshot = old.document.snapshot();
    defer old_snapshot.deinit();
    const old_bytes = try old_snapshot.copy(t.allocator, .{ .start = 0, .end = old_snapshot.byteLen() });
    defer t.allocator.free(old_bytes);
    try t.expectEqualStrings("same\nold\nno\n", old_bytes);
    const padding = gui.layout.file_height + gui.layout.context_height + 2 * 20 + 1;
    try t.expectEqual(null, old.hit(padding, 20, false));
    try t.expectEqual(@as(?usize, 2), old.hit(padding, 20, true));
    try t.expectEqual(@as(?usize, 2), new.hit(padding, 20, false));
    try state.toggle(t.allocator, "a.zig");
    var collapsed = try gui.review.Review.init(t.allocator, diff, projection, &state, .new);
    defer collapsed.deinit();
    try t.expectEqual(@as(usize, 1), collapsed.rows.len);
    try t.expectEqualStrings("b.zig", collapsed.rows[0].path);
    try t.expectEqual(2 * gui.layout.file_height + gui.layout.context_height, collapsed.rows[0].top(20));
}

test "review selection follows matching text across refresh but never switches source identity" {
    var before = try git.parseDiff(t.allocator, patch);
    defer before.deinit();
    var before_projection = try gui.layout.Projection.init(t.allocator, before);
    defer before_projection.deinit();
    var state: gui.layout.State = .{};
    defer state.deinit(t.allocator);
    var old = try gui.review.Review.init(t.allocator, before, before_projection, &state, .unified);
    defer old.deinit();
    old.focused = true;
    old.editor.selections.single(.{ .anchor = 5, .head = 8 });
    old.editor.dragging = true;
    var next = try gui.review.Review.init(t.allocator, before, before_projection, &state, .unified);
    defer next.deinit();
    next.retainSelection(&old);
    try t.expect(next.focused and next.editor.dragging);
    try t.expectEqual(text.Range{ .start = 5, .end = 8 }, next.editor.primary().range());
    var other_diff = try git.parseDiff(t.allocator, "diff --git a/other.zig b/other.zig\n--- a/other.zig\n+++ b/other.zig\n@@ -1 +1 @@\n-old\n+new\n");
    defer other_diff.deinit();
    var other_projection = try gui.layout.Projection.init(t.allocator, other_diff);
    defer other_projection.deinit();
    var other = try gui.review.Review.init(t.allocator, other_diff, other_projection, &state, .unified);
    defer other.deinit();
    other.retainSelection(&old);
    try t.expect(!other.focused);
}

test "context expansion fills captured gaps once and preserves final newline state" {
    var diff = try git.parseDiff(t.allocator, "diff --git a/a.txt b/a.txt\n--- a/a.txt\n+++ b/a.txt\n@@ -2 +2 @@\n-old\n+two\n@@ -5 +5 @@\n-old\n+five\n");
    defer diff.deinit();
    try gui.context.attach(&diff, "a.txt", "one\ntwo\nthree\nfour\nfive\nsix");
    var state: gui.layout.State = .{};
    defer state.deinit(t.allocator);
    try state.expandContext(t.allocator, diff.hunks[0], .up);
    try state.expandContext(t.allocator, diff.hunks[0], .down);
    try state.expandContext(t.allocator, diff.hunks[1], .down);
    try gui.context.apply(&diff, &state);
    try t.expectEqual(@as(usize, 1), diff.hunks[0].new_start);
    try t.expectEqual(@as(usize, 4), diff.hunks[0].new_count);
    try t.expectEqual(@as(usize, 5), diff.hunks[1].new_start);
    try t.expectEqual(@as(usize, 2), diff.hunks[1].new_count);
    // Reapplying persisted expansion does not duplicate adjacent context.
    try gui.context.apply(&diff, &state);
    var projection = try gui.layout.Projection.init(t.allocator, diff);
    defer projection.deinit();
    var review = try gui.review.Review.init(t.allocator, diff, projection, &state, .new);
    defer review.deinit();
    // With no gap header, navigation lands on the second hunk's deletion row.
    try t.expectEqual(@as(?f32, gui.layout.file_height + gui.layout.context_height + 5 * 20), projection.hunkOffset(&state, 1, 20));
    var snapshot = review.document.snapshot();
    defer snapshot.deinit();
    const bytes = try snapshot.copy(t.allocator, .{ .start = 0, .end = snapshot.byteLen() });
    defer t.allocator.free(bytes);
    try t.expectEqualStrings("one\ntwo\nthree\nfour\nfive\nsix", bytes);
}

test "wrapped Git rows align split padding and context controls with rendered text" {
    const ui = zircon_ui;
    var diff = try git.parseDiff(t.allocator, "diff --git a/a.txt b/a.txt\n--- a/a.txt\n+++ b/a.txt\n@@ -1 +1 @@\n-short\n+this is a very long changed line that wraps onto multiple visual lines\n@@ -3 +3 @@\n-before\n+after\n");
    defer diff.deinit();
    var projection = try gui.layout.Projection.init(t.allocator, diff);
    defer projection.deinit();
    var state: gui.layout.State = .{ .mode = .split };
    defer state.deinit(t.allocator);
    var metrics: ui.layout.FixedMetrics = .{ .advance = 8, .line_height = 20 };
    try t.expect(try projection.ensureLayout(diff, &state, 440, 14, 4, true, true, metrics.measurer()));
    try t.expect(!try projection.ensureLayout(diff, &state, 440, 14, 4, true, true, metrics.measurer()));
    const rows = projection.files[0].split;
    try t.expect(rows[1].height(20) > 20);
    try t.expectEqual(rows[1].top(20) + rows[1].height(20), rows[2].top(20));
    var old = try gui.review.Review.init(t.allocator, diff, projection, &state, .old);
    defer old.deinit();
    var new = try gui.review.Review.init(t.allocator, diff, projection, &state, .new);
    defer new.deinit();
    old.reflow(projection, &state);
    new.reflow(projection, &state);
    const continuation = gui.layout.file_height + rows[1].top(20) + 30;
    try t.expectEqual(null, old.hit(continuation, 20, false));
    try t.expectEqual(@as(?usize, 0), new.hit(continuation, 20, false));
    try t.expectEqual(gui.layout.file_height + rows[4].top(20), new.rows[1].top(20));
    state.mode = .unified;
    _ = try projection.ensureLayout(diff, &state, 440, 14, 4, true, true, metrics.measurer());
    const unified = projection.files[0].unified;
    try t.expect(unified[2].height(20) > 20);
    try t.expectEqual(unified[2].top(20) + unified[2].height(20), unified[3].top(20));
}

test "context arrows expand only five lines at the chosen hunk boundary" {
    var diff = try git.parseDiff(t.allocator, "diff --git a/a.txt b/a.txt\n--- a/a.txt\n+++ b/a.txt\n@@ -10 +10 @@\n-old\n+ten\n@@ -30 +30 @@\n-old\n+thirty\n");
    defer diff.deinit();
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(t.allocator);
    for (1..41) |number| {
        const line = try std.fmt.allocPrint(t.allocator, "line {d}\n", .{number});
        defer t.allocator.free(line);
        try bytes.appendSlice(t.allocator, line);
    }
    try gui.context.attach(&diff, "a.txt", bytes.items);
    var state: gui.layout.State = .{};
    defer state.deinit(t.allocator);
    try state.expandContext(t.allocator, diff.hunks[0], .up);
    try gui.context.apply(&diff, &state);
    try t.expectEqual(@as(usize, 5), diff.hunks[0].new_start);
    try t.expectEqual(@as(usize, 6), diff.hunks[0].new_count);
    try t.expectEqual(@as(usize, 30), diff.hunks[1].new_start);
    try t.expectEqual(@as(usize, 1), diff.hunks[1].new_count);
    try state.expandContext(t.allocator, diff.hunks[0], .down);
    try gui.context.apply(&diff, &state);
    try t.expectEqual(@as(usize, 5), diff.hunks[0].new_start);
    try t.expectEqual(@as(usize, 11), diff.hunks[0].new_count);
    try t.expectEqual(@as(usize, 30), diff.hunks[1].new_start);
    try t.expectEqual(@as(usize, 1), diff.hunks[1].new_count);
    try state.expandContext(t.allocator, diff.hunks[1], .up);
    try gui.context.apply(&diff, &state);
    try t.expectEqual(@as(usize, 5), diff.hunks[0].new_start);
    try t.expectEqual(@as(usize, 11), diff.hunks[0].new_count);
    try t.expectEqual(@as(usize, 25), diff.hunks[1].new_start);
    try t.expectEqual(@as(usize, 6), diff.hunks[1].new_count);
}

test "expansion and fresh diffs retain unrelated file layout" {
    var diff = try git.parseDiff(t.allocator, patch);
    defer diff.deinit();
    try gui.context.attach(&diff, "a.zig", "hidden\nsame\nnew\nextra\nunseen\n");
    var state: gui.layout.State = .{};
    defer state.deinit(t.allocator);
    var projection = try gui.layout.Projection.init(t.allocator, diff);
    defer projection.deinit();
    var metrics: zircon_ui.layout.FixedMetrics = .{ .advance = 8, .line_height = 20 };
    _ = try projection.ensureLayout(diff, &state, 440, 14, 4, true, true, metrics.measurer());
    const rows = projection.files[1].unified.ptr;
    const segments = projection.files[1].unified[1].visual.?.old.ptr;
    try state.expandContext(t.allocator, diff.hunks[0], .down);
    try gui.context.applyFile(&diff, &state, "a.zig");
    try projection.updateFile(diff, "a.zig");
    _ = try projection.ensureLayout(diff, &state, 440, 14, 4, true, true, metrics.measurer());
    try t.expect(rows == projection.files[1].unified.ptr);
    try t.expect(segments == projection.files[1].unified[1].visual.?.old.ptr);
    var next_diff = try git.parseDiff(t.allocator, patch);
    defer next_diff.deinit();
    var next = try gui.layout.Projection.init(t.allocator, next_diff);
    defer next.deinit();
    next.reuseLayouts(&projection, next_diff, diff);
    try t.expect(rows == next.files[1].unified.ptr);
    try t.expect(segments == next.files[1].unified[1].visual.?.old.ptr);
    _ = try next.ensureLayout(next_diff, &state, 440, 14, 4, true, true, metrics.measurer());
    try t.expect(segments == next.files[1].unified[1].visual.?.old.ptr);
}
