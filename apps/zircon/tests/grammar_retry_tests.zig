const std = @import("std");
const builtin = @import("builtin");
const zircon = @import("zircon");
const ui = @import("zircon_ui");
const t = std.testing;

const Ops = struct {
    fn timeoutState(self: *const zircon.Shell) void {
        const revision = if (self.tabs.items.len > 0) (self.workspace.getConst(self.tabs.items[0].document) catch return).doc.revision() else 0;
        std.debug.print("grammar wait: jobs={d} source revision={d} status error={} status={s}\n", .{ self.language.syntax_jobs, revision, self.status_is_error, self.status });
        for (self.language.syntax_documents.items) |tracked| std.debug.print("attempts={d} pending={} observed={?d} highlighted={?d} retry_at={d}\n", .{ tracked.attempts, tracked.pending, tracked.observed, tracked.revision, tracked.retry_at });
    }

    fn configure(self: *zircon.Shell, cx: *ui.Context(zircon.Shell), home: []const u8, worker: []const u8) !void {
        self.extension_host_path = worker;
        try self.loadExtensions(cx, home);
    }
    fn failedOnce(self: *const zircon.Shell) bool {
        return self.language.syntax_jobs == 1 and self.language.syntax_documents.items.len == 1 and !self.language.syntax_documents.items[0].pending and self.status_is_error;
    }
    fn stopped(self: *const zircon.Shell) bool {
        return self.language.syntax_jobs == 3 and !self.language.syntax_documents.items[0].pending;
    }
    fn recovered(self: *const zircon.Shell) bool {
        const tab = self.tabs.items[0];
        const record = self.workspace.getConst(tab.document) catch return false;
        return tab.editor.grammar_revision == record.doc.revision() and tab.editor.grammar_spans.len == 1 and tab.editor.grammar_spans[0].kind == .keyword;
    }
    fn otherError(self: *zircon.Shell, _: *ui.Context(zircon.Shell)) !void {
        try self.setStatus(try self.allocator.dupe(u8, "unrelated operation failed"));
        self.status_is_error = true;
    }
    fn checkError(self: *const zircon.Shell, unrelated: bool) !void {
        try t.expectEqual(unrelated, self.status_is_error);
        if (unrelated) try t.expectEqualStrings("unrelated operation failed", self.status);
    }
    fn copyBytes(self: *const zircon.Shell, a: std.mem.Allocator, out: *?[]u8) !void {
        var source = try self.workspace.snapshot(self.tabs.items[0].document);
        defer source.deinit();
        out.* = try source.copy(a, .{ .start = 0, .end = source.byteLen() });
    }
    fn count(self: *const zircon.Shell) u64 {
        return self.language.syntax_jobs;
    }
    fn waiting(self: *const zircon.Shell) bool {
        return self.language.syntax_waiting;
    }
};

fn tick(app: *ui.App, now: *f64) !void {
    _ = try app.step(now.*);
    now.* += 0.02;
    try std.Io.sleep(t.io, .fromMilliseconds(1), .awake);
}
fn wait(app: *ui.App, owner: ui.Entity(zircon.Shell), now: *f64, comptime condition: anytype) !void {
    const deadline = std.Io.Clock.awake.now(t.io).addDuration(.fromSeconds(3));
    while (!try app.read(owner, condition, .{})) {
        try tick(app, now);
        if (std.Io.Clock.awake.now(t.io).compare(.gte, deadline)) {
            try app.read(owner, Ops.timeoutState, .{});
            return error.GrammarRetryTimeout;
        }
    }
}
fn journey(mode: []const u8, unrelated_error: bool) !void {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    try tmp.dir.createDirPath(t.io, "extensions/org.zircon.grammar-retry");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "main.retry", .data = "abc" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "mode", .data = mode });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "worker.py", .data =
        \\#!/usr/bin/env python3
        \\import json, pathlib, sys, time
        \\root = pathlib.Path(__file__).parent
        \\source = sys.stdin.buffer.read()
        \\counter = root / 'attempts'
        \\attempt = int(counter.read_text()) + 1 if counter.exists() else 1
        \\counter.write_text(str(attempt))
        \\mode = (root / 'mode').read_text()
        \\if mode == 'stale' and attempt == 1:
        \\    while not (root / 'release').exists(): time.sleep(0.001)
        \\    sys.stderr.write('obsolete grammar failure')
        \\    sys.exit(7)
        \\if mode == 'always' or (mode == 'once' and attempt == 1):
        \\    sys.stderr.write('transient grammar failure')
        \\    sys.exit(7)
        \\size = len(source) + 1 if mode == 'invalid' and attempt == 1 else len(source)
        \\end = len(source) + 1 if mode == 'span' and attempt == 1 else 1
        \\print(json.dumps({'bytes': size, 'spans': [{'start': 0, 'end': end, 'kind': 'keyword'}]}))
        \\
    });
    const file = try tmp.dir.openFile(t.io, "worker.py", .{});
    defer file.close(t.io);
    try file.setPermissions(t.io, if (comptime builtin.os.tag == .windows) .default_file else .fromMode(0o755));
    try tmp.dir.writeFile(t.io, .{ .sub_path = "extensions/org.zircon.grammar-retry/extension.json", .data =
        \\{"schema_version":1,"id":"org.zircon.grammar-retry","name":"Grammar retry","version":"1.0.0","contributes":{"languages":[{"id":"retry","name":"Retry","extensions":["retry"],"grammar":{"builtin":true,"name":"retry","wasm":"","highlights":""}}]}}
    });
    const home = try std.fs.path.join(t.allocator, &.{ root, "extensions" });
    defer t.allocator.free(home);
    const worker = try std.fs.path.join(t.allocator, &.{ root, "worker.py" });
    defer t.allocator.free(worker);
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const h = try app.openWindow(zircon.Shell, .{ .visible = false, .width = 1000, .height = 700 }, try zircon.Shell.init(t.allocator, t.io, root, "main.retry"));
    const owner = try app.windowEntity(zircon.Shell, h);
    try app.update(owner, zircon.Shell.bootstrap, .{h});
    try app.update(owner, Ops.configure, .{ home, worker });
    var now: f64 = 1;
    if (std.mem.eql(u8, mode, "stale")) {
        while (true) {
            if (tmp.dir.statFile(t.io, "attempts", .{})) |_| break else |err| if (err != error.FileNotFound) return err;
            try tick(&app, &now);
        }
        try app.dispatch(h, .{ .text = "x" });
        try app.update(owner, Ops.otherError, .{});
        try tmp.dir.writeFile(t.io, .{ .sub_path = "release", .data = "" });
        try wait(&app, owner, &now, Ops.recovered);
        try t.expectEqual(@as(u64, 2), try app.read(owner, Ops.count, .{}));
    } else if (std.mem.eql(u8, mode, "always")) {
        try wait(&app, owner, &now, Ops.stopped);
        for (0..100) |_| try tick(&app, &now);
        try t.expectEqual(@as(u64, 3), try app.read(owner, Ops.count, .{}));
        try t.expect(!try app.read(owner, Ops.waiting, .{}));
        try tmp.dir.writeFile(t.io, .{ .sub_path = "mode", .data = "success" });
        try app.dispatch(h, .{ .text = "x" });
        try wait(&app, owner, &now, Ops.recovered);
        try t.expectEqual(@as(u64, 4), try app.read(owner, Ops.count, .{}));
    } else {
        try wait(&app, owner, &now, Ops.failedOnce);
        if (unrelated_error) try app.update(owner, Ops.otherError, .{});
        try wait(&app, owner, &now, Ops.recovered);
        try t.expectEqual(@as(u64, 2), try app.read(owner, Ops.count, .{}));
    }
    try app.read(owner, Ops.checkError, .{unrelated_error or std.mem.eql(u8, mode, "stale")});
    var copied: ?[]u8 = null;
    try app.read(owner, Ops.copyBytes, .{ t.allocator, &copied });
    const bytes = copied.?;
    defer t.allocator.free(bytes);
    try t.expectEqualStrings(if (std.mem.eql(u8, mode, "always") or std.mem.eql(u8, mode, "stale")) "xabc" else "abc", bytes);
}

test "transient grammar failure retries the same revision and clears its error" {
    try journey("once", false);
}
test "grammar retry recovery preserves a newer unrelated operation error" {
    try journey("once", true);
}
test "invalid grammar response retries without requiring a source edit" {
    try journey("invalid", false);
}
test "persistent grammar failures stop retrying and an edit rearms the budget" {
    try journey("always", false);
}

test "invalid grammar spans retry without escaping application dispatch" {
    try journey("span", false);
}
test "older source grammar failures cannot overwrite the current operation error" {
    try journey("stale", true);
}

test "bundled highlighting reuses its worker and retries after the worker exits" {
    // The macOS app test target builds the real Rust worker.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    try tmp.dir.createDirPath(t.io, "extensions/org.zircon.highlight-session");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "main.rs", .data = "fn main() {}\n" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "extensions/org.zircon.highlight-session/extension.json", .data =
        \\{"schema_version":1,"id":"org.zircon.highlight-session","name":"Session test","version":"1.0.0","contributes":{"languages":[{"id":"rust","name":"Rust","extensions":["rs"],"grammar":{"builtin":true,"name":"rust","wasm":"","highlights":""}}]}}
    });
    const home = try std.fs.path.join(t.allocator, &.{ root, "extensions" });
    defer t.allocator.free(home);
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const h = try app.openWindow(zircon.Shell, .{ .visible = false, .width = 1000, .height = 700 }, try zircon.Shell.init(t.allocator, t.io, root, "main.rs"));
    const owner = try app.windowEntity(zircon.Shell, h);
    try app.update(owner, zircon.Shell.bootstrap, .{h});
    try app.update(owner, zircon.Shell.loadExtensions, .{home});
    const check = struct {
        fn highlighted(self: *const zircon.Shell) bool {
            const tab = self.tabs.items[0];
            const record = self.workspace.getConst(tab.document) catch return false;
            for (self.language.syntax_documents.items) |tracked| {
                if (std.meta.eql(tracked.id, tab.document) and !tracked.pending and tracked.revision == record.doc.revision()) {
                    return tab.editor.grammar_revision == record.doc.revision() and tab.editor.grammar_spans.len > 0;
                }
            }
            return false;
        }
        fn workerId(self: *const zircon.Shell) std.process.Child.Id {
            return self.highlight_session.?.child.?.id.?;
        }
    };
    var now: f64 = 1;
    try wait(&app, owner, &now, check.highlighted);
    const first_worker = try app.read(owner, check.workerId, .{});
    try app.dispatch(h, .{ .text = "// 🙂\n" });
    try wait(&app, owner, &now, check.highlighted);
    try t.expectEqual(first_worker, try app.read(owner, check.workerId, .{}));
    try t.expectEqual(@as(u64, 2), try app.read(owner, Ops.count, .{}));

    try std.posix.kill(first_worker, .KILL);
    try app.dispatch(h, .{ .text = "// restarted\n" });
    try wait(&app, owner, &now, check.highlighted);
    try t.expect(first_worker != try app.read(owner, check.workerId, .{}));
    try t.expectEqual(@as(u64, 4), try app.read(owner, Ops.count, .{}));
    try app.read(owner, Ops.checkError, .{false});
}
