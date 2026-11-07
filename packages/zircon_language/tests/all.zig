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
    var diagnostics = false;
    var ids: [2]u64 = undefined;
    var count: usize = 0;
    const deadline = std.Io.Clock.awake.now(t.io).addDuration(.fromSeconds(3));
    while (!diagnostics or count < 2) {
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
