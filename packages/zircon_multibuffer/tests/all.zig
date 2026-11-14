const std = @import("std");
const multi = @import("zircon_multibuffer");
const text = @import("zircon_text");
const workspace = @import("zircon_workspace");
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

test "setSources atomically replaces a multi-file projection" {
    var first = try snapshot("one\ntwo");
    defer first.deinit();
    const second_id = workspace.DocumentId{ .workspace = 1, .slot = 2, .generation = 1 };
    var second = try snapshot("alpha\nbeta");
    defer second.deinit();
    var mb = multi.MultiBuffer.init(t.allocator);
    defer mb.deinit();
    try mb.setSources(&.{
        .{ .source = id, .snapshot = first, .excerpts = &.{.{ .start = 0, .end = 3 }} },
        .{ .source = second_id, .snapshot = second, .excerpts = &.{.{ .start = 6, .end = 10 }} },
    });
    const bytes = try mb.read(t.allocator);
    defer t.allocator.free(bytes);
    try t.expectEqualStrings("one\nbeta", bytes);
    const edit = try mb.edit(.{ .start = 4, .end = 8 }, "BETA");
    try t.expectEqual(second_id, edit.source);
    try t.expectEqual(@as(u64, second.revision()), edit.source_revision);

    var replacement = try snapshot("replacement");
    defer replacement.deinit();
    try t.expectError(error.InvalidRange, mb.setSources(&.{
        .{ .source = id, .snapshot = replacement, .excerpts = &.{.{ .start = 1, .end = 999 }} },
    }));
    const retained = try mb.read(t.allocator);
    defer t.allocator.free(retained);
    try t.expectEqualStrings("one\nbeta", retained);
}

test "removing a source reindexes the remaining editable excerpts" {
    var source = try snapshot("one");
    defer source.deinit();
    var other = try snapshot("two");
    defer other.deinit();
    const second_id = workspace.DocumentId{ .workspace = 1, .slot = 1, .generation = 1 };
    var mb = multi.MultiBuffer.init(t.allocator);
    defer mb.deinit();
    try mb.setSources(&.{ .{ .source = id, .snapshot = source, .excerpts = &.{.{ .start = 0, .end = 3 }} }, .{ .source = second_id, .snapshot = other, .excerpts = &.{.{ .start = 0, .end = 3 }} } });
    try mb.removeSource(id);
    const edit = try mb.edit(.{ .start = 0, .end = 3 }, "TWO");
    try t.expectEqual(second_id, edit.source);
    try t.expectEqual(text.Range{ .start = 0, .end = 3 }, edit.range);
}

test "cross-excerpt replacement preserves hidden text and travels as one history step" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    var ws = try workspace.Workspace.init(t.allocator, t.io, root);
    defer ws.deinit();
    const first = try ws.untitled("abc HIDDEN def");
    const second = try ws.untitled("xyz");
    var one = try ws.snapshot(first);
    defer one.deinit();
    var two = try ws.snapshot(second);
    defer two.deinit();
    var mb = multi.MultiBuffer.init(t.allocator);
    defer mb.deinit();
    try mb.setSources(&.{
        .{ .source = first, .snapshot = one, .excerpts = &.{ .{ .start = 0, .end = 3 }, .{ .start = 11, .end = 14 } } },
        .{ .source = second, .snapshot = two, .excerpts = &.{.{ .start = 0, .end = 3 }} },
    });
    const edits = try mb.edits(t.allocator, .{ .start = 1, .end = 10 }, "!");
    defer t.allocator.free(edits);
    var history = multi.Transactions.init(t.allocator);
    defer history.deinit();
    var applied = try history.apply(&ws, edits);
    defer applied.deinit();
    try expectSource(&ws, first, "a! HIDDEN ");
    try expectSource(&ws, second, "z");
    var undone = (try history.travel(&ws, second, .undo)).?;
    defer undone.deinit();
    try expectSource(&ws, first, "abc HIDDEN def");
    try expectSource(&ws, second, "xyz");
    var redone = (try history.travel(&ws, first, .redo)).?;
    defer redone.deinit();
    try expectSource(&ws, first, "a! HIDDEN ");
    try expectSource(&ws, second, "z");
}

fn expectSource(ws: *workspace.Workspace, source: workspace.DocumentId, expected: []const u8) !void {
    var snap = try ws.snapshot(source);
    defer snap.deinit();
    const bytes = try snap.copy(t.allocator, .{ .start = 0, .end = snap.byteLen() });
    defer t.allocator.free(bytes);
    try t.expectEqualStrings(expected, bytes);
}

test "multi-source preparation and grouped history reject stale peers without partial changes" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    var ws = try workspace.Workspace.init(t.allocator, t.io, root);
    defer ws.deinit();
    const first = try ws.untitled("one");
    const second = try ws.untitled("two");
    var history = multi.Transactions.init(t.allocator);
    defer history.deinit();
    const edits = [_]multi.SourceEdit{
        .{ .source = first, .source_revision = 0, .range = .{ .start = 0, .end = 3 }, .replacement = "ONE" },
        .{ .source = second, .source_revision = 1, .range = .{ .start = 0, .end = 3 }, .replacement = "TWO" },
    };
    try t.expectError(error.StaleRevision, history.apply(&ws, &edits));
    try expectSource(&ws, first, "one");
    try t.expectEqual(@as(u64, 0), (try ws.get(first)).doc.revision());
    try t.expectEqual(null, (try ws.get(first)).doc.historyTarget(.undo));
    var valid = edits;
    valid[1].source_revision = 0;
    var applied = try history.apply(&ws, &valid);
    defer applied.deinit();
    const peer = &(try ws.get(second)).doc;
    var local = try peer.apply(peer.revision(), &.{.{ .range = .{ .start = 0, .end = 0 }, .text = "local " }}, 0);
    defer local.deinit();
    try t.expectError(error.HistoryDiverged, history.travel(&ws, first, .undo));
    try expectSource(&ws, first, "ONE");
    try expectSource(&ws, second, "local TWO");
    try t.expectEqual(null, try history.travel(&ws, second, .undo));
    try t.expect(try peer.undo());
    var undone = (try history.travel(&ws, first, .undo)).?;
    defer undone.deinit();
    try expectSource(&ws, first, "one");
    try expectSource(&ws, second, "two");
    var branch = try peer.apply(peer.revision(), &.{.{ .range = .{ .start = 0, .end = 0 }, .text = "branch " }}, 0);
    defer branch.deinit();
    try t.expectError(error.HistoryDiverged, history.travel(&ws, first, .redo));
    try expectSource(&ws, first, "one");
}

test "projected copying validates unicode endpoints and preserves separators" {
    var source = try snapshot("é one HIDDEN 二");
    defer source.deinit();
    var mb = multi.MultiBuffer.init(t.allocator);
    defer mb.deinit();
    try mb.setSources(&.{.{ .source = id, .snapshot = source, .excerpts = &.{ .{ .start = 0, .end = 6 }, .{ .start = 14, .end = 17 } } }});
    const bytes = try mb.copy(t.allocator, .{ .start = 0, .end = 10 });
    defer t.allocator.free(bytes);
    try t.expectEqualStrings("é one\n二", bytes);
    try t.expectError(error.InvalidRange, mb.edits(t.allocator, .{ .start = 1, .end = 10 }, "!"));
    try t.expectError(error.InvalidUtf8, mb.edits(t.allocator, .{ .start = 0, .end = 10 }, "\xff"));
}
