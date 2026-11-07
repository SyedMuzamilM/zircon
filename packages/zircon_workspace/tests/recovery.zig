const std = @import("std");
const ws = @import("zircon_workspace");
const recovery = ws.recovery;
const t = std.testing;

fn path(temp: *t.TmpDir) ![:0]u8 {
    return temp.dir.realPathFileAlloc(t.io, ".", t.allocator);
}
fn index(root: []const u8, docs: []const recovery.Document) recovery.Index {
    return .{ .root = root, .documents = docs, .active = if (docs.len > 0) docs[0].id else null };
}
fn contentFile(a: std.mem.Allocator, store: *recovery.Store, id: u64, bytes: []const u8) ![]u8 {
    const ref = recovery.reference(bytes);
    return std.fmt.allocPrint(a, "{s}/doc-{d}-{s}.text", .{ store.path, id, std.fmt.bytesToHex(ref.digest, .lower) });
}

test "recovery publishes raw exact text and preserves disk baseline and view metadata" {
    var temp = t.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    const home = try path(&temp);
    defer t.allocator.free(home);
    try temp.dir.writeFile(t.io, .{ .sub_path = "source.txt", .data = "original" });
    var workspace = try ws.Workspace.init(t.allocator, t.io, home);
    defer workspace.deinit();
    const source = try workspace.open("source.txt");
    const record = try workspace.get(source);
    var store = try recovery.Store.init(t.allocator, t.io, home, workspace.root_path);
    defer store.deinit();
    const bytes = "unsaved\r\n日本語\r\n";
    const documents: []const recovery.Document = &.{.{ .id = 7, .path = record.path, .disk = record.disk, .view = .{ .anchor = 2, .head = 5, .scroll = 14 }, .primary = false, .secondary = true, .secondary_view = .{ .head = 9 } }};
    var metadata = index(workspace.root_path, documents);
    metadata.secondary_active = 7;
    metadata.focus_secondary = true;
    try store.publish(t.allocator, metadata, &.{.{ .id = 7, .bytes = bytes }});
    const raw_path = try contentFile(t.allocator, &store, 7, bytes);
    defer t.allocator.free(raw_path);
    const raw = try std.Io.Dir.cwd().readFileAlloc(t.io, raw_path, t.allocator, .limited(1024));
    defer t.allocator.free(raw);
    try t.expectEqualStrings(bytes, raw);
    var loaded = (try store.load(t.allocator)).?;
    defer loaded.deinit();
    try t.expectEqual(@as(usize, 0), loaded.warnings);
    try t.expectEqual(@as(usize, 1), loaded.contents.len);
    try t.expectEqualStrings(bytes, loaded.contents[0].bytes);
    try t.expect(std.meta.eql(record.disk, loaded.index.documents[0].disk));
    try t.expect(loaded.index.focus_secondary);
    try t.expectEqual(@as(usize, 5), loaded.index.documents[0].view.head);
    try store.publish(t.allocator, loaded.index, &.{});
}

test "failed publication and an orphan checkpoint keep the last committed index" {
    var temp = t.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    const home = try path(&temp);
    defer t.allocator.free(home);
    var store = try recovery.Store.init(t.allocator, t.io, home, home);
    defer store.deinit();
    try store.publish(t.allocator, index(home, &.{.{ .id = 1 }}), &.{.{ .id = 1, .bytes = "committed" }});
    try t.expectError(error.MissingRecoveryContent, store.publish(t.allocator, index(home, &.{ .{ .id = 1 }, .{ .id = 2 } }), &.{.{ .id = 1, .bytes = "orphan" }}));
    var loaded = (try store.load(t.allocator)).?;
    defer loaded.deinit();
    try t.expectEqualStrings("committed", loaded.contents[0].bytes);
    try t.expectEqual(@as(usize, 1), loaded.index.documents.len);
}

test "corrupt recovery text is retained while other documents restore" {
    var temp = t.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    const home = try path(&temp);
    defer t.allocator.free(home);
    var store = try recovery.Store.init(t.allocator, t.io, home, home);
    defer store.deinit();
    try store.publish(t.allocator, index(home, &.{ .{ .id = 1 }, .{ .id = 2 } }), &.{ .{ .id = 1, .bytes = "first" }, .{ .id = 2, .bytes = "second" } });
    const raw_path = try contentFile(t.allocator, &store, 1, "first");
    defer t.allocator.free(raw_path);
    try std.Io.Dir.cwd().writeFile(t.io, .{ .sub_path = raw_path, .data = "broken" });
    var loaded = (try store.load(t.allocator)).?;
    defer loaded.deinit();
    try t.expectEqual(@as(usize, 1), loaded.warnings);
    try t.expectEqual(@as(usize, 1), loaded.contents.len);
    try t.expectEqual(@as(u64, 2), loaded.contents[0].id);
    const retained = try std.Io.Dir.cwd().readFileAlloc(t.io, raw_path, t.allocator, .limited(100));
    defer t.allocator.free(retained);
    try t.expectEqualStrings("broken", retained);
}

test "active session locks isolate windows and unlocked sessions are claimed" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var temp = t.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    const home = try path(&temp);
    defer t.allocator.free(home);
    var first = try recovery.Store.init(t.allocator, t.io, home, home);
    try first.publish(t.allocator, index(home, &.{.{ .id = 1 }}), &.{.{ .id = 1, .bytes = "saved checkpoint" }});
    const claimed = try t.allocator.dupe(u8, first.path);
    defer t.allocator.free(claimed);
    var second = try recovery.Store.init(t.allocator, t.io, home, home);
    defer second.deinit();
    try t.expect(!std.mem.eql(u8, first.path, second.path));
    first.deinit();
    var third = try recovery.Store.init(t.allocator, t.io, home, home);
    defer third.deinit();
    try t.expectEqualStrings(claimed, third.path);
}

test "document and session discard cannot be resurrected by stale publication" {
    var temp = t.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    const home = try path(&temp);
    defer t.allocator.free(home);
    var store = try recovery.Store.init(t.allocator, t.io, home, home);
    defer store.deinit();
    const docs: []const recovery.Document = &.{ .{ .id = 1 }, .{ .id = 2 } };
    const contents: []const recovery.Content = &.{ .{ .id = 1, .bytes = "discard this" }, .{ .id = 2, .bytes = "keep this" } };
    try store.publish(t.allocator, index(home, docs), contents);
    try store.exclude(1);
    var before = (try store.load(t.allocator)).?;
    defer before.deinit();
    try t.expectEqual(@as(usize, 1), before.contents.len);
    try store.publish(t.allocator, index(home, docs), contents);
    var after = (try store.load(t.allocator)).?;
    defer after.deinit();
    try t.expectEqual(@as(usize, 1), after.contents.len);
    try t.expectEqual(@as(u64, 2), after.contents[0].id);
    try store.discard();
    try t.expect(try store.load(t.allocator) == null);
    try t.expectError(error.RecoverySessionDiscarded, store.publish(t.allocator, index(home, docs), contents));
}

test "restored text keeps its original disk stamp and conflicts with external edits" {
    var temp = t.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    const home = try path(&temp);
    defer t.allocator.free(home);
    try temp.dir.writeFile(t.io, .{ .sub_path = "source.txt", .data = "before" });
    var original = try ws.Workspace.init(t.allocator, t.io, home);
    defer original.deinit();
    const opened = try original.open("source.txt");
    const record = try original.get(opened);
    try temp.dir.writeFile(t.io, .{ .sub_path = "source.txt", .data = "external" });
    var restored = try ws.Workspace.init(t.allocator, t.io, home);
    defer restored.deinit();
    const id = try restored.restore("unsaved\r\n日本語", record.path, true, record.disk, "");
    try t.expect(try restored.dirty(id));
    try t.expectError(error.DiskConflict, restored.save(id, null));
    var source = try restored.snapshot(id);
    defer source.deinit();
    const bytes = try source.copy(t.allocator, .{ .start = 0, .end = source.byteLen() });
    defer t.allocator.free(bytes);
    try t.expectEqualStrings("unsaved\r\n日本語", bytes);
}

test "corrupt index is quarantined and an omitted corrupt document keeps its identity reserved" {
    var temp = t.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    const home = try path(&temp);
    defer t.allocator.free(home);
    var store = try recovery.Store.init(t.allocator, t.io, home, home);
    defer store.deinit();
    try store.publish(t.allocator, index(home, &.{ .{ .id = 1 }, .{ .id = 9 } }), &.{ .{ .id = 1, .bytes = "keep" }, .{ .id = 9, .bytes = "damaged" } });
    try store.exclude(9);
    var loaded = (try store.load(t.allocator)).?;
    defer loaded.deinit();
    try t.expectEqual(@as(u64, 10), loaded.index.next_document_id);
    const index_path = try std.fs.path.join(t.allocator, &.{ store.path, "index.json" });
    defer t.allocator.free(index_path);
    try std.Io.Dir.cwd().writeFile(t.io, .{ .sub_path = index_path, .data = "{torn" });
    try t.expectError(error.CorruptRecoveryIndex, store.load(t.allocator));
    const dir = try std.Io.Dir.cwd().openDir(t.io, store.path, .{ .iterate = true });
    defer dir.close(t.io);
    var iterator = dir.iterate();
    var found = false;
    while (try iterator.next(t.io)) |entry| if (std.mem.startsWith(u8, entry.name, "corrupt-index-")) {
        const retained = try dir.readFileAlloc(t.io, entry.name, t.allocator, .limited(100));
        defer t.allocator.free(retained);
        try t.expectEqualStrings("{torn", retained);
        found = true;
    };
    try t.expect(found);
}
test "committed recovery replaces old content without deleting a corrupt document" {
    var temp = t.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    const home = try path(&temp);
    defer t.allocator.free(home);
    var store = try recovery.Store.init(t.allocator, t.io, home, home);
    defer store.deinit();
    try store.publish(t.allocator, index(home, &.{.{ .id = 1 }}), &.{.{ .id = 1, .bytes = "old" }});
    const old = try contentFile(t.allocator, &store, 1, "old");
    defer t.allocator.free(old);
    try store.publish(t.allocator, index(home, &.{.{ .id = 1 }}), &.{.{ .id = 1, .bytes = "new" }});
    try t.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(t.io, old, .{}));
    var loaded = (try store.load(t.allocator)).?;
    defer loaded.deinit();
    try t.expectEqualStrings("new", loaded.contents[0].bytes);
}
