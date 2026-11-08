const std = @import("std");
const text = @import("zircon_text");
const workspace = @import("zircon_workspace");
const multi = @import("zircon_multibuffer");
const t = std.testing;
const id = workspace.DocumentId{ .workspace = 1, .slot = 0, .generation = 1 };

fn snapshot(bytes: []const u8) !text.Snapshot {
    var document = try text.Document.init(t.allocator, bytes);
    defer document.deinit();
    return document.snapshot();
}

test "multibuffer keeps source identities while projecting separate excerpts" {
    var mb = multi.MultiBuffer.init(t.allocator);
    defer mb.deinit();
    var first = try snapshot("one\ntwo\nthree");
    defer first.deinit();
    const second_id = workspace.DocumentId{ .workspace = 1, .slot = 1, .generation = 1 };
    var second = try snapshot("alpha\nbeta");
    defer second.deinit();
    try mb.addSource(id, first);
    try mb.addSource(second_id, second);
    try mb.setExcerpts(id, &.{ .{ .start = 0, .end = 3 }, .{ .start = 4, .end = 7 } });
    try mb.setExcerpts(second_id, &.{.{ .start = 0, .end = 5 }});
    const bytes = try mb.read(t.allocator);
    defer t.allocator.free(bytes);
    try t.expectEqualStrings("one\ntwo\nalpha", bytes);
    const edit = try mb.edit(.{ .start = 4, .end = 7 }, "TWO");
    try t.expectEqual(id, edit.source);
    try t.expectEqual(text.Range{ .start = 4, .end = 7 }, edit.range);
    try t.expectError(error.CrossExcerptEdit, mb.edit(.{ .start = 2, .end = 8 }, "x"));
}

test "source changes remap excerpt ranges and stable anchors" {
    var document = try text.Document.init(t.allocator, "aa\nbb\ncc");
    defer document.deinit();
    var mb = multi.MultiBuffer.init(t.allocator);
    defer mb.deinit();
    var before = document.snapshot();
    defer before.deinit();
    try mb.addSource(id, before);
    try mb.setExcerpts(id, &.{.{ .start = 3, .end = 5 }});
    const anchor = try mb.sourceAnchor(.{ .source = id, .offset = 4, .bias = .after });
    var change = try document.apply(before.revision(), &.{.{ .range = .{ .start = 0, .end = 0 }, .text = "prefix\n" }}, 0);
    defer change.deinit();
    var after = document.snapshot();
    defer after.deinit();
    const moved = try mb.mapAnchor(anchor, &change);
    try t.expectEqual(@as(usize, 11), moved.offset);
    try mb.updateSource(id, &change, after);
    const projected = mb.excerptList()[0].value.source_range;
    try t.expectEqual(text.Range{ .start = 10, .end = 12 }, projected);
    const bytes = try mb.read(t.allocator);
    defer t.allocator.free(bytes);
    try t.expectEqualStrings("bb", bytes);
}

test "stale source updates and cross-source edits are refused" {
    var mb = multi.MultiBuffer.init(t.allocator);
    defer mb.deinit();
    var source = try snapshot("abc");
    defer source.deinit();
    try mb.addSource(id, source);
    try mb.setExcerpts(id, &.{.{ .start = 0, .end = 3 }});
    var document = try text.Document.init(t.allocator, "abc");
    defer document.deinit();
    var first_change = try document.apply(0, &.{.{ .range = .{ .start = 1, .end = 1 }, .text = "x" }}, 0);
    defer first_change.deinit();
    var change = try document.apply(1, &.{.{ .range = .{ .start = 2, .end = 2 }, .text = "y" }}, 0);
    defer change.deinit();
    var after = document.snapshot();
    defer after.deinit();
    try t.expectError(error.StaleSourceRevision, mb.updateSource(id, &change, after));
    try t.expectError(error.CrossExcerptEdit, mb.edit(.{ .start = 1, .end = 4 }, "z"));
}
