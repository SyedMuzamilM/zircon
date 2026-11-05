const std = @import("std");
const search = @import("zircon_search");
const text = @import("zircon_text");
const t = std.testing;
fn path(a: std.mem.Allocator, tmp: *std.testing.TmpDir, name: []const u8) ![:0]u8 {
    return tmp.dir.realPathFileAlloc(t.io, name, a);
}
fn groupById(result: search.Results, id: u64) ?search.Group {
    for (result.groups) |group| if (group.source == .buffer and group.source.buffer.document_id == id) return group;
    return null;
}
test "unsaved buffers override canonical disk duplicates and include untitled text" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "one.zig", .data = "disk only" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "two.zig", .data = "needle two\n" });
    const one = try path(t.allocator, &tmp, "one.zig");
    defer t.allocator.free(one);
    const two = try path(t.allocator, &tmp, "two.zig");
    defer t.allocator.free(two);
    var doc = try text.Document.init(t.allocator, "unsaved needle\n");
    defer doc.deinit();
    var snap = doc.snapshot();
    defer snap.deinit();
    var untitled = try text.Document.init(t.allocator, "needle unsaved untitled");
    defer untitled.deinit();
    var other = untitled.snapshot();
    defer other.deinit();
    var result = try search.search(t.allocator, t.io, .{ .generation = 9, .query = .{ .text = "needle" }, .open_buffers = &.{ .{ .document_id = 1, .path = one, .title = "one.zig", .snapshot = snap }, .{ .document_id = 2, .title = "Untitled", .snapshot = other } }, .files = &.{ one, one, two } }, .{});
    defer result.deinit();
    try t.expectEqual(@as(u64, 9), result.generation);
    try t.expectEqual(@as(usize, 3), result.groups.len);
    try t.expectEqual(@as(usize, 3), result.total_matches);
    try t.expectEqual(@as(usize, 0), result.errors.len);
    const first = groupById(result, 1).?;
    try t.expectEqualStrings("unsaved needle\n", first.excerpts[0].bytes);
    try t.expectEqual(@as(usize, 8), first.matches[0].range.start);
    try t.expect(first.isCurrentBuffer(1, snap));
    try t.expect(!first.isCurrentBuffer(99, snap));
    try t.expect(groupById(result, 2) != null);
    var disk_count: usize = 0;
    for (result.groups) |group| if (group.source == .disk) {
        disk_count += 1;
        try t.expectEqualStrings(two, group.source.disk.path);
    };
    try t.expectEqual(@as(usize, 1), disk_count);
}
test "Unicode and multiline match coordinates retain exact merged source context" {
    var doc = try text.Document.init(t.allocator, "zero\r\na日🙂 needle\r\nnext needle\nlast\nfar\nneedle\n");
    defer doc.deinit();
    var snap = doc.snapshot();
    defer snap.deinit();
    var result = try search.search(t.allocator, t.io, .{ .generation = 1, .query = .{ .text = "needle" }, .open_buffers = &.{.{ .document_id = 3, .title = "Unicode", .snapshot = snap }}, .limits = .{ .context_lines = 0 } }, .{});
    defer result.deinit();
    const group = result.groups[0];
    try t.expectEqual(@as(usize, 3), group.matches.len);
    try t.expectEqual(@as(usize, 1), group.matches[0].line);
    try t.expectEqual(@as(usize, 9), group.matches[0].column);
    try t.expectEqual(@as(usize, 15), group.matches[0].range.start);
    try t.expectEqual(@as(usize, 2), group.excerpts.len);
    try t.expectEqualStrings("a日🙂 needle\r\nnext needle\n", group.excerpts[0].bytes);
    try t.expectEqual(@as(usize, 2), group.excerpts[0].match_ranges.len);
    try t.expectEqual(@as(usize, 9), group.excerpts[0].match_ranges[0].start);
    var multi = try search.search(t.allocator, t.io, .{ .generation = 2, .query = .{ .text = "needle\r\nnext" }, .open_buffers = &.{.{ .document_id = 3, .title = "Unicode", .snapshot = snap }}, .limits = .{ .context_lines = 0 } }, .{});
    defer multi.deinit();
    try t.expectEqual(@as(usize, 1), multi.total_matches);
    try t.expectEqual(@as(usize, 1), multi.groups[0].excerpts[0].start_line);
    try t.expectEqual(@as(usize, 3), multi.groups[0].excerpts[0].end_line);
}
test "case folding and whole-word matching use an explicit non-overlapping policy" {
    var doc = try text.Document.init(t.allocator, "cat scatter Cat cat_ 日本cat cat日本 cat-cat");
    defer doc.deinit();
    var snap = doc.snapshot();
    defer snap.deinit();
    var result = try search.search(t.allocator, t.io, .{ .generation = 1, .query = .{ .text = "CAT", .case_sensitive = false, .whole_word = true }, .open_buffers = &.{.{ .document_id = 1, .title = "Words", .snapshot = snap }} }, .{});
    defer result.deinit();
    try t.expectEqual(@as(usize, 4), result.total_matches);
    var sensitive = try search.search(t.allocator, t.io, .{ .generation = 1, .query = .{ .text = "Cat", .whole_word = true }, .open_buffers = &.{.{ .document_id = 1, .title = "Words", .snapshot = snap }} }, .{});
    defer sensitive.deinit();
    try t.expectEqual(@as(usize, 1), sensitive.total_matches);
}
test "disk fingerprints and buffer versions reject stale source activation" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "source", .data = "needle" });
    const file = try path(t.allocator, &tmp, "source");
    defer t.allocator.free(file);
    var result = try search.search(t.allocator, t.io, .{ .generation = 1, .query = .{ .text = "needle" }, .files = &.{file} }, .{});
    defer result.deinit();
    try t.expect(try result.groups[0].isCurrentDisk(t.io));
    try tmp.dir.writeFile(t.io, .{ .sub_path = "source", .data = "other!" });
    try t.expect(!try result.groups[0].isCurrentDisk(t.io));
    var doc = try text.Document.init(t.allocator, "needle");
    defer doc.deinit();
    var before = doc.snapshot();
    defer before.deinit();
    var buffer = try search.search(t.allocator, t.io, .{ .generation = 1, .query = .{ .text = "needle" }, .open_buffers = &.{.{ .document_id = 1, .title = "Buffer", .snapshot = before }} }, .{});
    defer buffer.deinit();
    var change = try doc.apply(doc.revision(), &.{.{ .range = .{ .start = 0, .end = 0 }, .text = "x" }}, 0);
    change.deinit();
    var after = doc.snapshot();
    defer after.deinit();
    try t.expect(!buffer.groups[0].isCurrentBuffer(1, after));
}
const CancelCounter = struct {
    calls: usize = 0,
    after: usize,
    fn canceled(raw: ?*anyopaque) bool {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        self.calls += 1;
        return self.calls >= self.after;
    }
};
test "cancellation is checked during long streaming searches not only matches" {
    const input = try t.allocator.alloc(u8, 100_000);
    defer t.allocator.free(input);
    @memset(input, 'a');
    var doc = try text.Document.init(t.allocator, input);
    defer doc.deinit();
    var snap = doc.snapshot();
    defer snap.deinit();
    var counter: CancelCounter = .{ .after = 7 };
    try t.expectError(error.Canceled, search.search(t.allocator, t.io, .{ .generation = 1, .query = .{ .text = "missing" }, .open_buffers = &.{.{ .document_id = 1, .title = "Large", .snapshot = snap }} }, .{ .context = &counter, .is_canceled = CancelCounter.canceled }));
    try t.expect(counter.calls >= 7);
}
test "source failures and explicit search limits are reported without losing valid groups" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "binary", .data = "needle\x00" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "invalid", .data = "\xffneedle" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "large", .data = "needle needle needle" });
    const binary = try path(t.allocator, &tmp, "binary");
    defer t.allocator.free(binary);
    const invalid = try path(t.allocator, &tmp, "invalid");
    defer t.allocator.free(invalid);
    const large = try path(t.allocator, &tmp, "large");
    defer t.allocator.free(large);
    var result = try search.search(t.allocator, t.io, .{ .generation = 1, .query = .{ .text = "needle" }, .files = &.{ binary, invalid, large }, .limits = .{ .matches = 2 } }, .{});
    defer result.deinit();
    try t.expectEqual(@as(usize, 2), result.errors.len);
    try t.expectEqual(@as(usize, 2), result.total_matches);
    try t.expect(result.truncated);
    var limited = try search.search(t.allocator, t.io, .{ .generation = 1, .query = .{ .text = "needle" }, .files = &.{large}, .limits = .{ .file_bytes = 8 } }, .{});
    defer limited.deinit();
    try t.expect(limited.truncated);
    try t.expectEqual(error.FileTooLarge, limited.errors[0].reason);
    try t.expectError(error.InvalidQuery, search.search(t.allocator, t.io, .{ .generation = 1, .query = .{ .text = "" } }, .{}));
}
test "search matches across rope leaf boundaries and merges neighboring contexts" {
    const input = try t.allocator.alloc(u8, 12_000);
    defer t.allocator.free(input);
    @memset(input, 'x');
    @memcpy(input[4093..][0..8], "needle!!");
    @memcpy(input[8190..][0..6], "needle");
    var doc = try text.Document.init(t.allocator, input);
    defer doc.deinit();
    var snap = doc.snapshot();
    defer snap.deinit();
    var result = try search.search(t.allocator, t.io, .{ .generation = 1, .query = .{ .text = "needle" }, .open_buffers = &.{.{ .document_id = 1, .title = "Long", .snapshot = snap }} }, .{});
    defer result.deinit();
    try t.expectEqual(@as(usize, 2), result.total_matches);
    try t.expectEqual(@as(usize, 4093), result.groups[0].matches[0].range.start);
    try t.expectEqual(@as(usize, 1), result.groups[0].excerpts.len);
}
test "allocation failures release all result and scratch ownership" {
    try t.checkAllAllocationFailures(t.allocator, allocationCase, .{});
}
fn allocationCase(a: std.mem.Allocator) !void {
    var doc = try text.Document.init(a, "first needle\nsecond needle\n");
    defer doc.deinit();
    var snap = doc.snapshot();
    defer snap.deinit();
    var result = try search.search(a, t.io, .{ .generation = 1, .query = .{ .text = "needle" }, .open_buffers = &.{.{ .document_id = 1, .title = "Buffer", .snapshot = snap }} }, .{});
    defer result.deinit();
    try t.expectEqual(@as(usize, 2), result.total_matches);
}

test "disk aliases deduplicate and source budget bounds failed input records" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "original", .data = "needle" });
    try tmp.dir.symLink(t.io, "original", "alias", .{});
    const original = try path(t.allocator, &tmp, "original");
    defer t.allocator.free(original);
    const root = try path(t.allocator, &tmp, ".");
    defer t.allocator.free(root);
    const alias = try std.fs.path.join(t.allocator, &.{ root, "alias" });
    defer t.allocator.free(alias);
    const missing = try std.fs.path.join(t.allocator, &.{ root, "missing" });
    defer t.allocator.free(missing);
    var result = try search.search(t.allocator, t.io, .{ .generation = 1, .query = .{ .text = "needle" }, .files = &.{ original, alias, original } }, .{});
    defer result.deinit();
    try t.expectEqual(@as(usize, 1), result.groups.len);
    try t.expectEqual(@as(usize, 1), result.total_matches);
    var limited = try search.search(t.allocator, t.io, .{ .generation = 1, .query = .{ .text = "needle" }, .files = &.{ missing, original }, .limits = .{ .sources = 1 } }, .{});
    defer limited.deinit();
    try t.expect(limited.truncated);
    try t.expectEqual(@as(usize, 1), limited.errors.len);
    try t.expectEqual(@as(usize, 0), limited.groups.len);
    var bytes = try search.search(t.allocator, t.io, .{ .generation = 1, .query = .{ .text = "needle" }, .files = &.{original}, .limits = .{ .total_bytes = 3 } }, .{});
    defer bytes.deinit();
    try t.expect(bytes.truncated);
    try t.expectEqual(error.SearchByteLimit, bytes.errors[0].reason);
}
test "disk search allocation failures release snapshots excerpts paths and scratch" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "source", .data = "first needle\nsecond needle\n" });
    const file = try path(t.allocator, &tmp, "source");
    defer t.allocator.free(file);
    try t.checkAllAllocationFailures(t.allocator, diskAllocationCase, .{file});
}
fn diskAllocationCase(a: std.mem.Allocator, file: []const u8) !void {
    var result = try search.search(a, t.io, .{ .generation = 1, .query = .{ .text = "needle" }, .files = &.{file} }, .{});
    defer result.deinit();
    try t.expectEqual(@as(usize, 2), result.total_matches);
}

test "worker reads a retained old buffer snapshot and results outlive its document" {
    var result: search.Results = block: {
        var document = try text.Document.init(t.allocator, "needle before edit\n");
        defer document.deinit();
        var snapshot = document.snapshot();
        defer snapshot.deinit();
        const Worker = struct {
            snapshot: text.Snapshot,
            start: std.atomic.Value(bool) = .init(false),
            result: anyerror!search.Results = undefined,
            fn run(self: *@This()) void {
                while (!self.start.load(.acquire)) std.atomic.spinLoopHint();
                self.result = search.search(t.allocator, t.io, .{ .generation = 7, .query = .{ .text = "needle" }, .open_buffers = &.{.{ .document_id = 42, .title = "Worker buffer", .snapshot = self.snapshot }} }, .{});
            }
        };
        var worker: Worker = .{ .snapshot = snapshot };
        const thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});
        var joined = false;
        defer if (!joined) {
            worker.start.store(true, .release);
            thread.join();
            if (worker.result) |*found| found.deinit() else |_| {}
        };
        var change = try document.apply(document.revision(), &.{.{ .range = .{ .start = 0, .end = 6 }, .text = "changed" }}, 0);
        change.deinit();
        worker.start.store(true, .release);
        thread.join();
        joined = true;
        break :block try worker.result;
    };
    defer result.deinit();
    try t.expectEqual(@as(usize, 1), result.total_matches);
    try t.expectEqualStrings("needle before edit\n", result.groups[0].excerpts[0].bytes);
    try t.expectEqual(@as(u64, 0), result.groups[0].source.buffer.revision);
}
