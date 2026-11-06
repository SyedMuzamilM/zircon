const std = @import("std");
const agent = @import("zircon_agent");
const t = std.testing;
fn wait(c: *agent.Conversation, state: @TypeOf(c.state)) !void {
    const deadline = std.Io.Clock.awake.now(t.io).addDuration(.fromSeconds(5));
    while (c.state != state) {
        _ = try c.poll();
        if (c.state == .failed) return error.AgentFailed;
        if (std.Io.Clock.awake.now(t.io).compare(.gte, deadline)) return error.Timeout;
        try std.Io.sleep(t.io, .fromMilliseconds(1), .awake);
    }
}
test "ACP and Codex stream Unicode and preserve permission decisions over real subprocesses" {
    inline for (.{ agent.Protocol.acp, agent.Protocol.codex }) |protocol| {
        var tmp = t.tmpDir(.{});
        defer tmp.cleanup();
        const cwd = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
        defer t.allocator.free(cwd);
        var c = agent.Conversation.init(t.allocator);
        defer c.deinit();
        try c.connect(t.io, .{ .command = "python3", .args = &.{ "-u", "-c", @embedFile("fixture.py"), @tagName(protocol) }, .cwd = cwd }, protocol);
        try wait(&c, .ready);
        try t.expectEqualStrings("fixture-session", c.session);
        if (protocol == .acp) {
            try t.expectEqual(@as(usize, 2), c.models.items.len);
            try c.chooseMode("plan");
            while (c.choice_request != null) {
                _ = try c.poll();
                try std.Io.sleep(t.io, .fromMilliseconds(1), .awake);
            }
            try t.expectEqualStrings("plan", c.mode);
            try c.chooseEffort("high");
            while (c.choice_request != null) {
                _ = try c.poll();
                try std.Io.sleep(t.io, .fromMilliseconds(1), .awake);
            }
            try t.expectEqualStrings("high", c.effort);
        }
        try c.prompt("Change example.txt");
        try wait(&c, .permission);
        try t.expectEqualStrings("Hello 日🙂", c.entries.items[1].text.items);
        try t.expectError(error.FileNotFound, tmp.dir.statFile(t.io, "example.txt", .{}));
        try c.answer(if (protocol == .acp) "allow" else "accept");
        try wait(&c, .ready);
        const bytes = try tmp.dir.readFileAlloc(t.io, "example.txt", t.allocator, .limited(100));
        defer t.allocator.free(bytes);
        try t.expectEqualStrings("approved edit\n", bytes);
        try c.chooseModel("fixture-model");
        while (c.choice_request != null) {
            _ = try c.poll();
            try std.Io.sleep(t.io, .fromMilliseconds(1), .awake);
        }
        try t.expectEqualStrings("fixture-model", c.model);
        try c.reconnect(t.io, .{ .command = "python3", .args = &.{ "-u", "-c", @embedFile("fixture.py"), @tagName(protocol) }, .cwd = cwd }, protocol);
        try wait(&c, .ready);
        try t.expectEqualStrings("fixture-session", c.session);
        try c.prompt("Wait for cancellation");
        try wait(&c, .permission);
        // Explicit rejection is tested separately from stopping an owned process.
    }
}
test "JSONL decoder handles fragmented messages and blank lines" {
    var d = agent.lines.Decoder.init(t.allocator);
    defer d.deinit();
    try d.feed("\n{\"id\":");
    try t.expect((try d.next()) == null);
    try d.feed("1}\n{\"id\":2}\n");
    try t.expectEqualStrings("{\"id\":1}", (try d.next()).?);
    try t.expectEqualStrings("{\"id\":2}", (try d.next()).?);
    try t.expect((try d.next()) == null);
}

test "rejection and cancellation leave files untouched in both protocols" {
    inline for (.{ agent.Protocol.acp, agent.Protocol.codex }) |protocol| {
        var tmp = t.tmpDir(.{});
        defer tmp.cleanup();
        const cwd = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
        defer t.allocator.free(cwd);
        var c = agent.Conversation.init(t.allocator);
        defer c.deinit();
        try c.connect(t.io, .{ .command = "python3", .args = &.{ "-u", "-c", @embedFile("fixture.py"), @tagName(protocol) }, .cwd = cwd }, protocol);
        try wait(&c, .ready);
        try c.prompt("Edit a file");
        try wait(&c, .permission);
        try c.answer(if (protocol == .acp) "reject" else "decline");
        try wait(&c, .ready);
        try t.expectError(error.FileNotFound, tmp.dir.statFile(t.io, "example.txt", .{}));
        try c.prompt("Edit another file");
        try wait(&c, .permission);
        try c.cancel();
        try wait(&c, .ready);
        try t.expectError(error.FileNotFound, tmp.dir.statFile(t.io, "example.txt", .{}));
    }
}
