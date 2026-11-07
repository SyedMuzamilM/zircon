const std = @import("std");
const text = @import("zircon_text");
const t = std.testing;
fn expectText(expected: []const u8, document: *const text.Document) !void {
    var snapshot = document.snapshot();
    defer snapshot.deinit();
    const actual = try snapshot.copy(t.allocator, .{ .start = 0, .end = snapshot.byteLen() });
    defer t.allocator.free(actual);
    try t.expectEqualStrings(expected, actual);
    _ = try snapshot.debugValidate();
}
test "UTF8 document snapshots preserve text across edits undo and redo" {
    var doc = try text.Document.init(t.allocator, "hello 日本🙂\r\nlast\n");
    defer doc.deinit();
    var original = doc.snapshot();
    defer original.deinit();
    try t.expectEqual(@as(usize, 3), original.lineCount());
    try t.expectEqual(text.Range{ .start = 0, .end = 16 }, try original.lineRange(0));
    var change = try doc.apply(0, &.{.{ .range = .{ .start = 6, .end = 12 }, .text = "world" }}, 0);
    defer change.deinit();
    try expectText("hello world🙂\r\nlast\n", &doc);
    const old = try original.copy(t.allocator, .{ .start = 0, .end = original.byteLen() });
    defer t.allocator.free(old);
    try t.expectEqualStrings("hello 日本🙂\r\nlast\n", old);
    try t.expect(try doc.undo());
    try expectText("hello 日本🙂\r\nlast\n", &doc);
    try t.expectEqual(@as(u64, 1), doc.stateId());
    try t.expectEqual(@as(u64, 2), doc.revision());
    try t.expect(try doc.redo());
    try expectText("hello world🙂\r\nlast\n", &doc);
}

test "line indexing retains CRLF bytes and UTF16 mapping refuses surrogate interiors" {
    var doc = try text.Document.init(t.allocator, "a🙂日\r\n\r\nend\r");
    defer doc.deinit();
    var s = doc.snapshot();
    defer s.deinit();
    try t.expectEqual(@as(usize, 3), s.lineCount());
    try t.expectEqual(text.Range{ .start = 0, .end = 8 }, try s.lineRange(0));
    try t.expectEqual(text.Range{ .start = 0, .end = 10 }, try s.lineRangeIncludingEnding(0));
    try t.expectEqual(text.Range{ .start = 10, .end = 10 }, try s.lineRange(1));
    try t.expectEqual(text.Range{ .start = 12, .end = 16 }, try s.lineRange(2));
    try t.expectEqual(@as(usize, 3), try s.utf16Offset(5));
    try t.expectEqual(@as(usize, 5), try s.byteOffsetFromUtf16(3));
    try t.expectError(error.InvalidUtf16Boundary, s.byteOffsetFromUtf16(2));
    try t.expectError(error.InvalidOffset, s.utf16Offset(2));
    try t.expectEqual(@as(usize, 10), try s.nextBoundary(8));
    try t.expectEqual(@as(usize, 8), try s.previousBoundary(10));
    for (0..s.byteLen() + 1) |offset| if (s.isBoundary(offset)) {
        try t.expectEqual(offset, try s.offsetAt(try s.pointAt(offset)));
        try t.expectEqual(offset, try s.byteOffsetFromUtf16(try s.utf16Offset(offset)));
    };
    try t.expectError(error.InvalidLine, s.lineRange(3));
}
test "batch edits map affinities and publish one atomic content state" {
    var doc = try text.Document.init(t.allocator, "0123456789");
    defer doc.deinit();
    var change = try doc.apply(0, &.{
        .{ .range = .{ .start = 1, .end = 3 }, .text = "abc" },
        .{ .range = .{ .start = 5, .end = 5 }, .text = "🙂" },
        .{ .range = .{ .start = 7, .end = 9 }, .text = "" },
    }, 0);
    defer change.deinit();
    try expectText("0abc34🙂569", &doc);
    try t.expectEqual(@as(u64, 1), doc.revision());
    try t.expectEqual(@as(usize, 1), change.map(1, .before));
    try t.expectEqual(@as(usize, 4), change.map(1, .after));
    try t.expectEqual(@as(usize, 4), change.map(3, .before));
    try t.expectEqual(@as(usize, 6), change.map(5, .before));
    try t.expectEqual(@as(usize, 10), change.map(5, .after));
    try t.expectEqual(@as(usize, 12), change.map(9, .after));
    try t.expect(try doc.undo());
    try expectText("0123456789", &doc);
}
test "typing groups coalesce history while state identities and redo branches remain exact" {
    var doc = try text.Document.init(t.allocator, "");
    defer doc.deinit();
    var a = try doc.apply(0, &.{.{ .range = .{ .start = 0, .end = 0 }, .text = "a" }}, 7);
    a.deinit();
    var b = try doc.apply(1, &.{.{ .range = .{ .start = 1, .end = 1 }, .text = "b" }}, 7);
    b.deinit();
    const ab = doc.stateId();
    try t.expect(try doc.undo());
    try expectText("", &doc);
    try t.expect(!try doc.undo());
    try t.expect(try doc.redo());
    try expectText("ab", &doc);
    try t.expectEqual(ab, doc.stateId());
    try t.expect(try doc.undo());
    var branch = try doc.apply(doc.revision(), &.{.{ .range = .{ .start = 0, .end = 0 }, .text = "new" }}, 0);
    branch.deinit();
    try t.expect(!try doc.redo());
    try expectText("new", &doc);
    doc.setHistoryLimit(1);
    var c = try doc.apply(doc.revision(), &.{.{ .range = .{ .start = 3, .end = 3 }, .text = "!" }}, 0);
    c.deinit();
    try t.expect(try doc.undo());
    try expectText("new", &doc);
    try t.expect(!try doc.undo());
}
test "invalid stale overlapping and no-op edits preserve revision history and snapshots" {
    var doc = try text.Document.init(t.allocator, "abc日");
    defer doc.deinit();
    try t.expectError(error.StaleRevision, doc.apply(9, &.{}, 0));
    try t.expectError(error.InvalidUtf8, doc.apply(0, &.{.{ .range = .{ .start = 0, .end = 0 }, .text = "\xff" }}, 0));
    try t.expectError(error.InvalidRange, doc.apply(0, &.{.{ .range = .{ .start = 4, .end = 6 }, .text = "x" }}, 0));
    try t.expectError(error.OverlappingEdits, doc.apply(0, &.{ .{ .range = .{ .start = 0, .end = 3 }, .text = "x" }, .{ .range = .{ .start = 2, .end = 3 }, .text = "y" } }, 0));
    var same = try doc.apply(0, &.{.{ .range = .{ .start = 0, .end = 3 }, .text = "abc" }}, 0);
    same.deinit();
    try t.expectEqual(@as(u64, 0), doc.revision());
    try t.expect(!try doc.undo());
    try expectText("abc日", &doc);
}
fn fillLarge(a: std.mem.Allocator) ![]u8 {
    const bytes = try a.alloc(u8, 32768);
    @memset(bytes, 'a');
    for (0..bytes.len / 64) |row| bytes[row * 64 + 63] = '\n';
    return bytes;
}
test "streaming search matches across leaves and supports reverse and explicit ASCII folding" {
    const bytes = try fillLarge(t.allocator);
    defer t.allocator.free(bytes);
    @memcpy(bytes[4094..4099], "Hello");
    var doc = try text.Document.init(t.allocator, bytes);
    defer doc.deinit();
    var s = doc.snapshot();
    defer s.deinit();
    try t.expectEqual(text.Range{ .start = 4094, .end = 4099 }, (try s.find("Hello", 0, .forward, true)).?);
    try t.expect((try s.find("hello", 0, .forward, true)) == null);
    try t.expectEqual(text.Range{ .start = 4094, .end = 4099 }, (try s.find("hello", s.byteLen(), .backward, false)).?);
    try t.expect((try s.find("", 0, .forward, true)) == null);
    const long = try t.allocator.alloc(u8, 300);
    defer t.allocator.free(long);
    @memset(long, 'a');
    try t.expect((try s.find(long, 0, .forward, true)) == null);
    try t.expectError(error.InvalidUtf8, s.find("\xff", 0, .forward, true));
}
const Random = struct {
    value: u64 = 0xa6e2ce4971,
    fn next(self: *Random, max: usize) usize {
        self.value = self.value *% 6364136223846793005 +% 1442695040888963407;
        return @intCast((self.value >> 32) % @as(u64, @intCast(max)));
    }
};
fn referenceReplace(a: std.mem.Allocator, old: []const u8, range: text.Range, insert: []const u8) ![]u8 {
    const next = try a.alloc(u8, old.len - (range.end - range.start) + insert.len);
    @memcpy(next[0..range.start], old[0..range.start]);
    @memcpy(next[range.start..][0..insert.len], insert);
    @memcpy(next[range.start + insert.len ..], old[range.end..]);
    return next;
}
fn randomBoundary(random: *Random, bytes: []const u8) usize {
    var offset = random.next(bytes.len + 1);
    while (offset > 0 and offset < bytes.len and bytes[offset] & 0xc0 == 0x80) offset -= 1;
    return offset;
}
test "random Unicode replacements match flat reference with retained snapshots and indexed metrics" {
    const initial = try fillLarge(t.allocator);
    defer t.allocator.free(initial);
    var flat = try t.allocator.dupe(u8, initial);
    defer t.allocator.free(flat);
    var doc = try text.Document.init(t.allocator, initial);
    defer doc.deinit();
    var retained = doc.snapshot();
    defer retained.deinit();
    var random: Random = .{};
    const inserts = [_][]const u8{ "x", "🙂", "日本\n", "\r\n", "", "abc", "é" };
    for (0..600) |iteration| {
        const a = randomBoundary(&random, flat);
        const b = randomBoundary(&random, flat);
        // Mix small local edits with occasional broad deletion.
        var range: text.Range = .{ .start = @min(a, b), .end = @max(a, b) };
        if (iteration % 5 != 0) {
            range.start = a;
            range.end = a;
        }
        const insert = inserts[random.next(inserts.len)];
        const next = try referenceReplace(t.allocator, flat, range, insert);
        var change = try doc.apply(doc.revision(), &.{.{ .range = range, .text = insert }}, 0);
        change.deinit();
        t.allocator.free(flat);
        flat = next;
        try expectText(flat, &doc);
        var s = doc.snapshot();
        defer s.deinit();
        var lines: usize = 1;
        var utf16: usize = 0;
        for (flat) |byte| {
            if (byte == '\n') lines += 1;
            if (byte & 0xc0 != 0x80) utf16 += if (byte >= 0xf0) @as(usize, 2) else 1;
        }
        try t.expectEqual(lines, s.lineCount());
        try t.expectEqual(utf16, s.utf16Len());
        const at = randomBoundary(&random, flat);
        try t.expectEqual(at, try s.offsetAt(try s.pointAt(at)));
    }
    const old = try retained.copy(t.allocator, .{ .start = 0, .end = retained.byteLen() });
    defer t.allocator.free(old);
    try t.expectEqualStrings(initial, old);
}
test "tiny insertions reuse bounded leaves instead of retaining one leaf per character" {
    var doc = try text.Document.init(t.allocator, "");
    defer doc.deinit();
    for (0..1500) |i| {
        var change = try doc.apply(doc.revision(), &.{.{ .range = .{ .start = i / 2, .end = i / 2 }, .text = "x" }}, 11);
        change.deinit();
    }
    var s = doc.snapshot();
    defer s.deinit();
    const stats = try s.debugValidate();
    try t.expectEqual(@as(usize, 1500), s.byteLen());
    try t.expectEqual(@as(usize, 1), stats.leaves);
    try t.expect(try doc.undo());
    try expectText("", &doc);
}
test "initial construction and multi-edit undo lifecycle release every allocation failure" {
    try t.checkAllAllocationFailures(t.allocator, allocationLifecycle, .{});
}
fn allocationLifecycle(a: std.mem.Allocator) !void {
    const source = try fillLarge(a);
    defer a.free(source);
    var doc = try text.Document.init(a, source);
    defer doc.deinit();
    var original = doc.snapshot();
    defer original.deinit();
    var change = try doc.apply(0, &.{ .{ .range = .{ .start = 4000, .end = 4100 }, .text = "日本🙂" }, .{ .range = .{ .start = 8000, .end = 16000 }, .text = "replacement\n" } }, 0);
    defer change.deinit();
    _ = try doc.undo();
    _ = try doc.redo();
    var snap = doc.snapshot();
    defer snap.deinit();
    _ = try snap.debugValidate();
}
test "OOM while preparing replacement preserves content revision state and undo history" {
    const source = try fillLarge(t.allocator);
    defer t.allocator.free(source);
    var allocation = std.testing.FailingAllocator.init(t.allocator, .{});
    var doc = try text.Document.init(allocation.allocator(), source);
    defer doc.deinit();
    allocation.fail_index = allocation.alloc_index + 3;
    try t.expectError(error.OutOfMemory, doc.apply(0, &.{.{ .range = .{ .start = 4090, .end = 4100 }, .text = "🙂new" }}, 0));
    try expectText(source, &doc);
    try t.expectEqual(@as(u64, 0), doc.revision());
    try t.expectEqual(@as(u64, 1), doc.stateId());
    try t.expect(!try doc.undo());
}
test "snapshot may outlive its document and read immutable text on another thread" {
    var doc = try text.Document.init(t.allocator, "shared 日🙂");
    var retained = doc.snapshot();
    doc.deinit();
    defer retained.deinit();
    const Read = struct {
        fn run(snapshot: text.Snapshot, output: *usize) void {
            output.* = snapshot.byteLen() + snapshot.utf16Len();
        }
    };
    var observed: usize = 0;
    const worker = try std.Thread.spawn(.{}, Read.run, .{ retained, &observed });
    worker.join();
    try t.expectEqual(retained.byteLen() + retained.utf16Len(), observed);
    const actual = try retained.copy(t.allocator, .{ .start = 0, .end = retained.byteLen() });
    defer t.allocator.free(actual);
    try t.expectEqualStrings("shared 日🙂", actual);
}

test "sustained local edits rebalance a large shared rope without flattening storage" {
    const source = try t.allocator.alloc(u8, 131072);
    defer t.allocator.free(source);
    @memset(source, 'z');
    for (0..source.len / 80) |line| source[line * 80 + 79] = '\n';
    var flat = try t.allocator.dupe(u8, source);
    defer t.allocator.free(flat);
    var doc = try text.Document.init(t.allocator, source);
    defer doc.deinit();
    var random: Random = .{ .value = 0x847b92d41 };
    for (0..500) |iteration| {
        const start = randomBoundary(&random, flat);
        var end = @min(flat.len, start + random.next(20));
        while (end < flat.len and flat[end] & 0xc0 == 0x80) end += 1;
        const insert = if (iteration % 2 == 0) "日🙂\n12345" else "local";
        const next = try referenceReplace(t.allocator, flat, .{ .start = start, .end = end }, insert);
        var change = try doc.apply(doc.revision(), &.{.{ .range = .{ .start = start, .end = end }, .text = insert }}, 88);
        change.deinit();
        t.allocator.free(flat);
        flat = next;
        try expectText(flat, &doc);
    }
    var snapshot = doc.snapshot();
    defer snapshot.deinit();
    const stats = try snapshot.debugValidate();
    try t.expect(stats.height < 20);
    try t.expect(stats.leaves < 250);
    try t.expect(try doc.undo());
    try expectText(source, &doc);
    try t.expect(!try doc.undo());
}
test "later invalid batch input and failed undo preparation leave all earlier state intact" {
    var failing = std.testing.FailingAllocator.init(t.allocator, .{});
    var doc = try text.Document.init(failing.allocator(), "012345");
    defer doc.deinit();
    try t.expectError(error.InvalidUtf8, doc.apply(0, &.{ .{ .range = .{ .start = 0, .end = 1 }, .text = "first" }, .{ .range = .{ .start = 4, .end = 4 }, .text = "\xff" } }, 0));
    try expectText("012345", &doc);
    var change = try doc.apply(0, &.{.{ .range = .{ .start = 0, .end = 1 }, .text = "first" }}, 0);
    defer change.deinit();
    failing.fail_index = failing.alloc_index;
    try t.expectError(error.OutOfMemory, doc.undo());
    try expectText("first12345", &doc);
    try t.expectEqual(@as(u64, 1), doc.revision());
}
test "zero history limit retains only current content and no-op empty documents stay valid" {
    var doc = try text.Document.init(t.allocator, "");
    defer doc.deinit();
    doc.setHistoryLimit(0);
    var noop = try doc.apply(0, &.{}, 0);
    noop.deinit();
    try t.expectEqual(@as(u64, 0), doc.revision());
    var change = try doc.apply(0, &.{.{ .range = .{ .start = 0, .end = 0 }, .text = "x" }}, 1);
    change.deinit();
    try t.expect(!try doc.undo());
    try expectText("x", &doc);
    var s = doc.snapshot();
    defer s.deinit();
    try t.expectEqual(@as(usize, 1), s.lineCount());
}

test "multi-byte original chunks split only at code points and index every line" {
    const phrase = "日🙂é\r\n";
    const source = try t.allocator.alloc(u8, phrase.len * 1800);
    defer t.allocator.free(source);
    for (0..1800) |i| @memcpy(source[i * phrase.len ..][0..phrase.len], phrase);
    var doc = try text.Document.init(t.allocator, source);
    defer doc.deinit();
    var snapshot = doc.snapshot();
    defer snapshot.deinit();
    _ = try snapshot.debugValidate();
    for (0..1800) |row| {
        const range = try snapshot.lineRange(row);
        try t.expectEqual(row * phrase.len, range.start);
        try t.expectEqual(row * phrase.len + phrase.len - 2, range.end);
        try t.expectEqual(@as(usize, row * 6), try snapshot.utf16Offset(range.start));
    }
    const pattern = "🙂é\r\n日";
    try t.expectEqual(text.Range{ .start = 3, .end = 14 }, (try snapshot.find(pattern, 0, .forward, true)).?);
}

test "bare CR detection composes across rope leaves and edits" {
    const bytes = try t.allocator.alloc(u8, 8192);
    defer t.allocator.free(bytes);
    @memset(bytes, 'x');
    bytes[4095] = '\r';
    bytes[4096] = '\n';
    var doc = try text.Document.init(t.allocator, bytes);
    defer doc.deinit();
    var first = doc.snapshot();
    defer first.deinit();
    try t.expect(!first.hasBareCarriageReturn());
    var change = try doc.apply(first.revision(), &.{.{ .range = .{ .start = 4096, .end = 4097 }, .text = "" }}, 0);
    defer change.deinit();
    var after = doc.snapshot();
    defer after.deinit();
    try t.expect(after.hasBareCarriageReturn());
    _ = try after.debugValidate();
    _ = try doc.undo();
    var undone = doc.snapshot();
    defer undone.deinit();
    try t.expect(!undone.hasBareCarriageReturn());
}
