const std = @import("std");
const language = @import("zircon_language");
const text = @import("zircon_text");
const t = std.testing;
test "framing handles fragmented headers multiple bodies and rejects invalid lengths" {
    var decoder = language.framing.Decoder.init(t.allocator);
    defer decoder.deinit();
    try decoder.feed("Content-Len");
    try t.expect(try decoder.next() == null);
    try decoder.feed("gth: 2\r\n\r\n{}");
    try t.expectEqualStrings("{}", (try decoder.next()).?);
    try t.expect(try decoder.next() == null);
    try decoder.feed("Content-Length: 4\r\n\r\nnullContent-Length: 2\r\n\r\n{}");
    try t.expectEqualStrings("null", (try decoder.next()).?);
    try t.expectEqualStrings("{}", (try decoder.next()).?);
    try decoder.feed("Content-Length: -1\r\n\r\n");
    try t.expectError(error.InvalidContentLength, decoder.next());
}
test "protocol coordinates are exact UTF16 and reject split surrogate pairs" {
    var doc = try text.Document.init(t.allocator, "a🙂日\r\nnext");
    defer doc.deinit();
    var snap = doc.snapshot();
    defer snap.deinit();
    try t.expectEqual(language.Position{ .line = 0, .character = 3 }, try language.positionAt(snap, 5));
    try t.expectEqual(@as(usize, 5), try language.offsetAt(snap, .{ .line = 0, .character = 3 }));
    try t.expectError(error.InvalidUtf16Boundary, language.offsetAt(snap, .{ .line = 0, .character = 2 }));
    const uri = try language.fileUri(t.allocator, "/tmp/a b#.zig");
    defer t.allocator.free(uri);
    try t.expectEqualStrings("file:///tmp/a%20b%23.zig", uri);
}
test "client fails missing executable without leaking process resources" {
    try t.expectError(error.FileNotFound, language.Client.start(t.allocator, t.io, .{ .command = "/no/such/zircon-lsp", .cwd = "/tmp" }));
}

const fixture = @embedFile("fixture.py");

test "hover accepts markup and legacy language fragments" {
    var input = try std.json.parseFromSlice(std.json.Value, t.allocator, "[{\"language\":\"zig\",\"value\":\"fn answer() u32\"},\"Returns the answer.\"]", .{});
    defer input.deinit();
    const bytes = try language.hover.contents(t.allocator, input.value);
    defer t.allocator.free(bytes);
    try t.expectEqualStrings("```zig\nfn answer() u32\n```\n\nReturns the answer.", bytes);
}

test "stdio hover carries document revision and Markdown documentation" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const path = try fixturePath(tmp);
    defer t.allocator.free(path);
    const client = try language.Client.start(t.allocator, t.io, .{ .command = "python3", .args = &.{path}, .cwd = "/tmp" });
    defer client.deinit();
    try waitReady(client);
    var document = try text.Document.init(t.allocator, "a🙂answer");
    defer document.deinit();
    var snapshot = document.snapshot();
    defer snapshot.deinit();
    const uri = "file:///tmp/hover.zig";
    try client.didOpen(uri, "zig", snapshot);
    const id = try client.hover(uri, snapshot.revision(), .{ .line = 0, .character = 3 });
    const deadline = std.Io.Clock.awake.now(t.io).addDuration(.fromSeconds(3));
    var found = false;
    while (!found) {
        const messages = try client.drain(t.allocator);
        defer language.deinitMessages(t.allocator, messages);
        for (messages) |message| if (message.data == .hover) {
            try t.expectEqual(id, message.data.hover.id);
            try t.expectEqualStrings(uri, message.data.hover.uri);
            try t.expectEqual(snapshot.revision(), message.data.hover.version);
            try t.expect(std.mem.indexOf(u8, message.data.hover.contents, "fn answer() u32") != null);
            found = true;
        };
        if (std.Io.Clock.awake.now(t.io).compare(.gte, deadline)) return error.HoverTimeout;
        std.atomic.spinLoopHint();
    }
    try client.didClose(uri);
}
fn fixturePath(tmp: std.testing.TmpDir) ![:0]u8 {
    try tmp.dir.writeFile(t.io, .{ .sub_path = "server.py", .data = fixture });
    return tmp.dir.realPathFileAlloc(t.io, "server.py", t.allocator);
}
fn waitReady(client: *language.Client) !void {
    const deadline = std.Io.Clock.awake.now(t.io).addDuration(.fromSeconds(3));
    while (!client.ready()) {
        if (client.status() == .failed or client.status() == .exited) return error.FixtureServerFailed;
        if (std.Io.Clock.awake.now(t.io).compare(.gte, deadline)) return error.FixtureTimeout;
        std.atomic.spinLoopHint();
    }
}
test "actual fragmented stdio server initializes publishes versioned diagnostics and completes out of order" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const path = try fixturePath(tmp);
    defer t.allocator.free(path);
    const client = try language.Client.start(t.allocator, t.io, .{ .command = "python3", .args = &.{path}, .cwd = "/tmp" });
    defer client.deinit();
    try waitReady(client);
    var doc = try text.Document.init(t.allocator, "a🙂b");
    defer doc.deinit();
    var snap = doc.snapshot();
    defer snap.deinit();
    const uri = "file:///tmp/fixture.zig";
    try client.didOpen(uri, "zig", snap);
    const one = try client.completion(uri, snap.revision(), .{ .line = 0, .character = 3 });
    const two = try client.completion(uri, snap.revision(), .{ .line = 0, .character = 3 });
    const definition = try client.definition(uri, snap.revision(), .{ .line = 0, .character = 3 });
    const references = try client.references(uri, snap.revision(), .{ .line = 0, .character = 3 });
    const rename = try client.rename(uri, snap.revision(), .{ .line = 0, .character = 3 }, "renamed");
    var diagnostics = false;
    var definition_seen = false;
    var references_seen = false;
    var rename_seen = false;
    var ids: [2]u64 = undefined;
    var count: usize = 0;
    const deadline = std.Io.Clock.awake.now(t.io).addDuration(.fromSeconds(3));
    while (!diagnostics or !definition_seen or !references_seen or !rename_seen or count < 2) {
        const messages = try client.drain(t.allocator);
        defer language.deinitMessages(t.allocator, messages);
        for (messages) |message| switch (message.data) {
            .diagnostics => |value| {
                try t.expectEqual(@as(?u64, snap.revision()), value.version);
                try t.expectEqualStrings("emoji warning", value.items[0].message);
                diagnostics = true;
            },
            .completion => |value| {
                try t.expectEqualStrings("answer🙂", value.items[0].label);
                try t.expectEqual(snap.revision(), value.version);
                if (count < 2) {
                    ids[count] = value.id;
                    count += 1;
                }
            },
            .locations => |value| {
                try t.expect(value.id == definition or value.id == references);
                try t.expectEqual(@as(usize, 1), value.items.len);
                try t.expectEqualStrings(uri, value.items[0].uri);
                if (value.id == definition) {
                    try t.expectEqual(.definition, value.kind);
                    definition_seen = true;
                } else {
                    try t.expectEqual(.references, value.kind);
                    references_seen = true;
                }
            },
            .workspace_edit => |value| {
                try t.expectEqual(rename, value.id);
                try t.expectEqual(@as(usize, 1), value.files.len);
                try t.expectEqualStrings(uri, value.files[0].uri);
                try t.expectEqualStrings("renamed", value.files[0].edits[0].new_text);
                rename_seen = true;
            },
            .failure => return error.FixtureFailure,
            else => {},
        };
        if (std.Io.Clock.awake.now(t.io).compare(.gte, deadline)) return error.FixtureTimeout;
        std.atomic.spinLoopHint();
    }
    try t.expectEqual(two, ids[0]);
    try t.expectEqual(one, ids[1]);
    var change = try doc.apply(doc.revision(), &.{.{ .range = .{ .start = 0, .end = 0 }, .text = "x" }}, 0);
    change.deinit();
    var next = doc.snapshot();
    defer next.deinit();
    try client.didChange(uri, next);
    try t.expectError(error.StaleDocumentVersion, client.didChange(uri, next));
    try client.didClose(uri);
}
test "malformed and unresponsive owned servers terminate without blocked reader joins" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const path = try fixturePath(tmp);
    defer t.allocator.free(path);
    for ([_][]const u8{ "malformed", "blocked", "early" }) |mode| {
        const client = try language.Client.start(t.allocator, t.io, .{ .command = "python3", .args = &.{ path, mode }, .cwd = "/tmp" });
        client.deinit();
    }
}

test "incremental synchronization negotiates and sends insertion ranges" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const path = try fixturePath(tmp);
    defer t.allocator.free(path);
    const client = try language.Client.start(t.allocator, t.io, .{ .command = "python3", .args = &.{ path, "incremental" }, .cwd = "/tmp" });
    defer client.deinit();
    try waitReady(client);
    var doc = try text.Document.init(t.allocator, "abc");
    defer doc.deinit();
    var first = doc.snapshot();
    defer first.deinit();
    const uri = "file:///tmp/incremental.zig";
    try client.didOpen(uri, "zig", first);
    var change = try doc.apply(first.revision(), &.{.{ .range = .{ .start = 1, .end = 1 }, .text = "X" }}, 0);
    defer change.deinit();
    var next = doc.snapshot();
    defer next.deinit();
    try client.didChangeEdits(uri, change.before, next, change.mappings);
    try expectServerText(client, next.revision(), "aXbc", 1);
    try t.expectEqual(@as(u64, 1), client.stats().change_text_bytes);
    try t.expectEqual(@as(u64, 1), client.stats().incremental_changes);
    try t.expectError(error.StaleDocumentVersion, client.didChangeEdits(uri, change.before, next, change.mappings));
    try client.didClose(uri);
}

fn expectServerText(client: *language.Client, revision: u64, expected: []const u8, count: usize) !void {
    const deadline = std.Io.Clock.awake.now(t.io).addDuration(.fromSeconds(5));
    while (std.Io.Clock.awake.now(t.io).compare(.lt, deadline)) {
        const messages = try client.drain(t.allocator);
        defer language.deinitMessages(t.allocator, messages);
        for (messages) |message| switch (message.data) {
            .log => |log| {
                if (!std.mem.startsWith(u8, log.message, "sync:")) continue;
                const Report = struct { version: u64, text: []const u8, changes: usize };
                const parsed = try std.json.parseFromSlice(Report, t.allocator, log.message[5..], .{});
                defer parsed.deinit();
                if (parsed.value.version != revision) continue;
                try t.expectEqualStrings(expected, parsed.value.text);
                try t.expectEqual(count, parsed.value.changes);
                return;
            },
            .failure, .exited => return error.ServerFailedToReconstructText,
            else => {},
        };
        if (!client.ready()) return error.ServerFailedToReconstructText;
        try std.Io.sleep(t.io, .fromMilliseconds(1), .awake);
    }
    return error.ServerDidNotAcknowledgeChange;
}
fn editAndVerify(client: *language.Client, doc: *text.Document, edits: []const text.Edit, expected: []const u8) !void {
    var change = try doc.apply(doc.revision(), edits, 0);
    defer change.deinit();
    var after = doc.snapshot();
    defer after.deinit();
    try client.didChangeEdits("file:///tmp/sync.zig", change.before, after, change.mappings);
    try expectServerText(client, after.revision(), expected, change.mappings.len);
}
test "incremental server reconstructs Unicode multiline replacements deletions batches undo and resync" {
    for ([_][]const u8{ "incremental", "incremental-object" }) |mode| {
        var tmp = t.tmpDir(.{});
        defer tmp.cleanup();
        const path = try fixturePath(tmp);
        defer t.allocator.free(path);
        const client = try language.Client.start(t.allocator, t.io, .{ .command = "python3", .args = &.{ path, mode }, .cwd = "/tmp" });
        defer client.deinit();
        try waitReady(client);
        var doc = try text.Document.init(t.allocator, "a🙂b\r\nsecond\n");
        defer doc.deinit();
        var original = doc.snapshot();
        defer original.deinit();
        const uri = "file:///tmp/sync.zig";
        try client.didOpen(uri, "zig", original);
        try editAndVerify(client, &doc, &.{.{ .range = .{ .start = 1, .end = 5 }, .text = "日本" }}, "a日本b\r\nsecond\n");
        try editAndVerify(client, &doc, &.{.{ .range = .{ .start = 1, .end = 7 }, .text = "" }}, "ab\r\nsecond\n");
        try editAndVerify(client, &doc, &.{.{ .range = .{ .start = 1, .end = 1 }, .text = "🙂\n日" }}, "a🙂\n日b\r\nsecond\n");
        try editAndVerify(client, &doc, &.{
            .{ .range = .{ .start = 0, .end = 1 }, .text = "AA" },
            .{ .range = .{ .start = 9, .end = 10 }, .text = "B" },
        }, "AA🙂\n日B\r\nsecond\n");
        try t.expect(try doc.undo());
        var undone = doc.snapshot();
        defer undone.deinit();
        try client.didChange(uri, undone);
        try expectServerText(client, undone.revision(), "a🙂\n日b\r\nsecond\n", 1);
        // An event gap uses a range against the retained old text, even when
        // revisions skip. Full-sync servers use an un-ranged update instead.
        var first = try doc.apply(doc.revision(), &.{.{ .range = .{ .start = 0, .end = 1 }, .text = "x" }}, 0);
        first.deinit();
        var last = try doc.apply(doc.revision(), &.{.{ .range = .{ .start = 0, .end = 1 }, .text = "y" }}, 0);
        defer last.deinit();
        var current = doc.snapshot();
        defer current.deinit();
        try client.didChangeEdits(uri, last.before, current, last.mappings);
        try expectServerText(client, current.revision(), "y🙂\n日b\r\nsecond\n", 1);
        try client.didClose(uri);
        try client.didOpen(uri, "zig", current);
        try editAndVerify(client, &doc, &.{.{ .range = .{ .start = 0, .end = 0 }, .text = "reopen " }}, "reopen y🙂\n日b\r\nsecond\n");
        try client.didClose(uri);
    }
}
test "invalid incremental mappings do not advance the enqueued version" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const path = try fixturePath(tmp);
    defer t.allocator.free(path);
    const client = try language.Client.start(t.allocator, t.io, .{ .command = "python3", .args = &.{ path, "incremental" }, .cwd = "/tmp" });
    defer client.deinit();
    try waitReady(client);
    var doc = try text.Document.init(t.allocator, "abc");
    defer doc.deinit();
    var before = doc.snapshot();
    defer before.deinit();
    const uri = "file:///tmp/sync.zig";
    try client.didOpen(uri, "zig", before);
    var change = try doc.apply(before.revision(), &.{.{ .range = .{ .start = 0, .end = 0 }, .text = "🙂" }}, 0);
    defer change.deinit();
    var after = doc.snapshot();
    defer after.deinit();
    try t.expectError(error.InvalidRange, client.didChangeEdits(uri, before.revision(), after, &.{.{ .range = .{ .start = 0, .end = 9 }, .inserted = 1 }}));
    try client.didChangeEdits(uri, before.revision(), after, change.mappings);
    try expectServerText(client, after.revision(), "🙂abc", 1);
    try client.didClose(uri);
}

test "CRLF splitting and a final newline deletion use valid incremental ranges" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const path = try fixturePath(tmp);
    defer t.allocator.free(path);
    const client = try language.Client.start(t.allocator, t.io, .{ .command = "python3", .args = &.{ path, "incremental" }, .cwd = "/tmp" });
    defer client.deinit();
    try waitReady(client);
    var doc = try text.Document.init(t.allocator, "a\r\nb\r\n");
    defer doc.deinit();
    var initial = doc.snapshot();
    defer initial.deinit();
    try client.didOpen("file:///tmp/sync.zig", "zig", initial);
    try editAndVerify(client, &doc, &.{.{ .range = .{ .start = 1, .end = 2 }, .text = "" }}, "a\nb\r\n");
    try editAndVerify(client, &doc, &.{.{ .range = .{ .start = 3, .end = 5 }, .text = "" }}, "a\nb");
    try editAndVerify(client, &doc, &.{.{ .range = .{ .start = 0, .end = 3 }, .text = "" }}, "");
    try client.didClose("file:///tmp/sync.zig");
}
test "None and omitted synchronization never enqueue document changes" {
    for ([_][]const u8{ "sync-none", "sync-none-open", "sync-omitted" }) |mode| {
        var tmp = t.tmpDir(.{});
        defer tmp.cleanup();
        const path = try fixturePath(tmp);
        defer t.allocator.free(path);
        const client = try language.Client.start(t.allocator, t.io, .{ .command = "python3", .args = &.{ path, mode }, .cwd = "/tmp" });
        defer client.deinit();
        try waitReady(client);
        var doc = try text.Document.init(t.allocator, "original");
        defer doc.deinit();
        var before = doc.snapshot();
        defer before.deinit();
        try client.didOpen("file:///tmp/sync.zig", "zig", before);
        var change = try doc.apply(before.revision(), &.{.{ .range = .{ .start = 0, .end = 8 }, .text = "different" }}, 0);
        defer change.deinit();
        var after = doc.snapshot();
        defer after.deinit();
        try client.didChangeEdits("file:///tmp/sync.zig", change.before, after, change.mappings);
        try t.expectEqual(@as(u64, 0), client.stats().document_changes);
        try t.expectError(error.StaleDocumentVersion, client.didChange("file:///tmp/sync.zig", after));
        try client.didClose("file:///tmp/sync.zig");
    }
}

test "synchronization options reject unsupported encodings and malformed capabilities" {
    for ([_][]const u8{ "{}", "{\"textDocumentSync\":0}", "{\"textDocumentSync\":null}" }) |json| {
        const parsed = try std.json.parseFromSlice(std.json.Value, t.allocator, json, .{});
        defer parsed.deinit();
        const options = try language.SynchronizationOptions.parse(parsed.value);
        try t.expectEqual(.none, options.kind);
        try t.expect(!options.open_close);
    }
    const invalid = [_]struct { json: []const u8, err: anyerror }{
        .{ .json = "{\"positionEncoding\":\"utf-8\"}", .err = error.UnsupportedPositionEncoding },
        .{ .json = "{\"positionEncoding\":false}", .err = error.UnsupportedPositionEncoding },
        .{ .json = "{\"textDocumentSync\":7}", .err = error.InvalidSynchronizationOptions },
        .{ .json = "{\"textDocumentSync\":{\"openClose\":1}}", .err = error.InvalidSynchronizationOptions },
        .{ .json = "{\"textDocumentSync\":{\"change\":\"incremental\"}}", .err = error.InvalidSynchronizationOptions },
    };
    for (invalid) |case| {
        const parsed = try std.json.parseFromSlice(std.json.Value, t.allocator, case.json, .{});
        defer parsed.deinit();
        try t.expectError(case.err, language.SynchronizationOptions.parse(parsed.value));
    }
}

test "queue pressure leaves the snapshot available for a later retry" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const path = try fixturePath(tmp);
    defer t.allocator.free(path);
    const client = try language.Client.start(t.allocator, t.io, .{ .command = "python3", .args = &.{ path, "incremental" }, .cwd = "/tmp", .outgoing_limit_bytes = 4096 });
    defer client.deinit();
    try waitReady(client);
    var doc = try text.Document.init(t.allocator, "small");
    defer doc.deinit();
    var first = doc.snapshot();
    defer first.deinit();
    const uri = "file:///tmp/sync.zig";
    try client.didOpen(uri, "zig", first);
    const giant = try t.allocator.alloc(u8, 8 * 1024);
    defer t.allocator.free(giant);
    @memset(giant, 'a');
    var change = try doc.apply(doc.revision(), &.{.{ .range = .{ .start = 0, .end = 5 }, .text = giant }}, 0);
    change.deinit();
    var large = doc.snapshot();
    defer large.deinit();
    try t.expectError(error.OutgoingQueueFull, client.didChange(uri, large));
    try t.expectEqual(@as(u64, 0), client.stats().document_changes);
    try t.expect(try doc.undo());
    var recovered = doc.snapshot();
    defer recovered.deinit();
    try client.didChange(uri, recovered);
    try expectServerText(client, recovered.revision(), "small", 1);
    try client.didClose(uri);
}

test "repeated graceful shutdown wakes an idle transport writer" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const path = try fixturePath(tmp);
    defer t.allocator.free(path);
    for (0..24) |_| {
        const client = try language.Client.start(t.allocator, t.io, .{ .command = "python3", .args = &.{path}, .cwd = "/tmp" });
        errdefer client.deinit();
        try waitReady(client);
        client.deinit();
    }
}

test "protocol coordinates recognize CR LF CRLF and preserve Unicode separators" {
    var doc = try text.Document.init(t.allocator, "a\rb\r\n🙂\nc\u{2028}d");
    defer doc.deinit();
    var snapshot = doc.snapshot();
    defer snapshot.deinit();
    const points = [_]struct { at: usize, line: usize, character: usize }{
        .{ .at = 0, .line = 0, .character = 0 },
        .{ .at = 1, .line = 0, .character = 1 },
        .{ .at = 2, .line = 1, .character = 0 },
        .{ .at = 3, .line = 1, .character = 1 },
        .{ .at = 5, .line = 2, .character = 0 },
        .{ .at = 9, .line = 2, .character = 2 },
        .{ .at = 10, .line = 3, .character = 0 },
        .{ .at = 15, .line = 3, .character = 3 },
    };
    for (points) |point| {
        const position: language.Position = .{ .line = point.line, .character = point.character };
        try t.expectEqual(position, try language.positionAt(snapshot, point.at));
        try t.expectEqual(point.at, try language.offsetAt(snapshot, position));
    }
    try t.expectError(error.InvalidPosition, language.positionAt(snapshot, 4));
    try t.expectError(error.InvalidPosition, language.offsetAt(snapshot, .{ .line = 0, .character = 2 }));
    try t.expectError(error.InvalidPosition, language.offsetAt(snapshot, .{ .line = 4, .character = 0 }));
}

test "full and incremental servers reconstruct bare CR and Unicode line separators" {
    for ([_][]const u8{ "incremental", "verify-full" }) |mode| {
        var tmp = t.tmpDir(.{});
        defer tmp.cleanup();
        const path = try fixturePath(tmp);
        defer t.allocator.free(path);
        const client = try language.Client.start(t.allocator, t.io, .{ .command = "python3", .args = &.{ path, mode }, .cwd = "/tmp" });
        defer client.deinit();
        try waitReady(client);
        var doc = try text.Document.init(t.allocator, "a\rb\u{2028}c");
        defer doc.deinit();
        var initial = doc.snapshot();
        defer initial.deinit();
        try client.didOpen("file:///tmp/sync.zig", "zig", initial);
        try editAndVerify(client, &doc, &.{.{ .range = .{ .start = 2, .end = 3 }, .text = "🙂" }}, "a\r🙂\u{2028}c");
        _ = try doc.undo();
        var undone = doc.snapshot();
        defer undone.deinit();
        try client.didChange("file:///tmp/sync.zig", undone);
        try expectServerText(client, undone.revision(), "a\rb\u{2028}c", 1);
        try client.didClose("file:///tmp/sync.zig");
    }
}
