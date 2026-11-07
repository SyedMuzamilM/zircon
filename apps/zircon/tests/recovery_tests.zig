const std = @import("std");
const ui = @import("zircon_ui");
const zircon = @import("zircon");
const t = std.testing;
const Shell = zircon.Shell;

const Ops = struct {
    fn busy(self: *const Shell) bool {
        return self.recovery.?.busy;
    }
    fn failed(self: *const Shell) bool {
        return self.recovery.?.last_error != null;
    }
    fn approved(self: *const Shell) bool {
        return self.allow_close;
    }
    fn confirmWindowDiscard(self: *Shell, cx: *ui.Context(Shell)) !void {
        var close: ui.Event(ui.Input) = .{ .data = .close };
        try self.onRoot(&close, cx);
        try command(self, cx, .discard_dirty);
    }
    fn replace(self: *Shell, cx: *ui.Context(Shell), bytes: []const u8) !void {
        const record = try self.workspace.get(self.tabs.items[self.active].document);
        var before = record.doc.snapshot();
        defer before.deinit();
        var change = try record.doc.apply(before.revision(), &.{.{ .range = .{ .start = 0, .end = before.byteLen() }, .text = bytes }}, 0);
        defer change.deinit();
        self.tabs.items[self.active].editor.mapChange(&change);
        var after = record.doc.snapshot();
        defer after.deinit();
        self.tabs.items[self.active].editor.synchronize(after);
        cx.notify();
    }
    fn checkpointBytes(self: *Shell, _: *ui.Context(Shell), expected: []const u8) !void {
        var loaded = (try self.recovery.?.store.?.load(t.allocator)).?;
        defer loaded.deinit();
        try t.expectEqual(@as(usize, 1), loaded.contents.len);
        try t.expectEqualStrings(expected, loaded.contents[0].bytes);
    }
    fn corruptNextContent(self: *const Shell, bytes: []const u8, output: *[]u8) !void {
        const recovery = &self.recovery.?;
        const id = recovery.documents.items[0].id;
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        output.* = try std.fmt.allocPrint(t.allocator, "{s}/doc-{d}-{s}.text", .{ recovery.store.?.path, id, std.fmt.bytesToHex(digest, .lower) });
        try std.Io.Dir.cwd().writeFile(t.io, .{ .sub_path = output.*, .data = "corrupt" });
    }
    fn ready(self: *const Shell) bool {
        const recovery = self.recovery orelse return false;
        return !recovery.busy and recovery.committed != null and recovery.committed == recovery.observed and recovery.due == null;
    }
    fn check(self: *const Shell, saved: []const u8, untitled: []const u8) !void {
        try t.expectEqual(@as(usize, 2), self.tabs.items.len);
        for (self.tabs.items) |tab| {
            const record = try self.workspace.getConst(tab.document);
            var snapshot = record.doc.snapshot();
            defer snapshot.deinit();
            const actual = try snapshot.copy(t.allocator, .{ .start = 0, .end = snapshot.byteLen() });
            defer t.allocator.free(actual);
            try t.expectEqualStrings(if (record.path != null) saved else untitled, actual);
            try t.expect(record.dirty());
        }
    }
    fn new(self: *Shell, cx: *ui.Context(Shell)) !void {
        try self.newFile();
        cx.notify();
    }
    fn command(self: *Shell, cx: *ui.Context(Shell), action: zircon.Command) !void {
        var click: ui.Event(ui.Click) = .{ .data = .{} };
        try self.onCommand(&click, cx, action);
    }
    fn conflict(self: *Shell, _: *ui.Context(Shell)) !void {
        for (self.tabs.items) |tab| if ((try self.workspace.getConst(tab.document)).path != null) {
            try t.expectError(error.DiskConflict, self.workspace.save(tab.document, null));
            return;
        };
        return error.SavedDocumentMissing;
    }
    fn count(self: *const Shell) usize {
        return self.tabs.items.len;
    }
    fn storePath(self: *const Shell, allocator: std.mem.Allocator, output: *[]u8) !void {
        output.* = try allocator.dupe(u8, self.recovery.?.store.?.path);
    }
    fn contentPath(self: *const Shell, output: *[]u8) !void {
        const model = &self.recovery.?;
        const first = model.documents.items[0];
        output.* = try std.fmt.allocPrint(t.allocator, "{s}/doc-{d}-{s}.text", .{ model.store.?.path, first.id, std.fmt.bytesToHex(first.content.?.digest, .lower) });
    }
    fn partialRestore(self: *const Shell) !void {
        try t.expectEqual(@as(usize, 1), self.tabs.items.len);
        try t.expect(std.mem.indexOf(u8, self.status, "recovery records") != null);
        const record = try self.workspace.getConst(self.tabs.items[0].document);
        var snapshot = record.doc.snapshot();
        defer snapshot.deinit();
        const bytes = try snapshot.copy(t.allocator, .{ .start = 0, .end = snapshot.byteLen() });
        defer t.allocator.free(bytes);
        try t.expectEqualStrings("valid work", bytes);
    }
    fn cleanBytes(self: *const Shell, expected: []const u8) !void {
        const record = try self.workspace.getConst(self.tabs.items[self.active].document);
        var snapshot = record.doc.snapshot();
        defer snapshot.deinit();
        const bytes = try snapshot.copy(t.allocator, .{ .start = 0, .end = snapshot.byteLen() });
        defer t.allocator.free(bytes);
        try t.expectEqualStrings(expected, bytes);
        try t.expect(!record.dirty());
    }
};
fn open(app: *ui.App, root: []const u8, home: []const u8, initial: ?[]const u8) !ui.WindowHandle {
    var shell = try Shell.init(t.allocator, t.io, root, initial);
    const handle = app.openWindow(Shell, .{ .visible = false, .width = 1000, .height = 700 }, shell) catch |err| {
        shell.deinit(t.allocator);
        return err;
    };
    const owner = try app.windowEntity(Shell, handle);
    try app.update(owner, Shell.initRecovery, .{home});
    try app.update(owner, Shell.bootstrap, .{handle});
    return handle;
}
fn settle(app: *ui.App, owner: ui.Entity(Shell), time: f64) !void {
    for (0..2000) |iteration| {
        _ = try app.step(time + @as(f64, @floatFromInt(iteration)) * 0.01);
        if (try app.read(owner, Ops.ready, .{})) return;
        try std.Io.sleep(t.io, .fromMilliseconds(1), .awake);
    }
    return error.RecoveryDidNotSettle;
}

test "application recovery restores saved dirty and untitled bytes and keeps the original disk conflict" {
    var temp = t.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const home = try std.fs.path.join(t.allocator, &.{ root, "recovery" });
    defer t.allocator.free(home);
    try temp.dir.writeFile(t.io, .{ .sub_path = "file.txt", .data = "disk" });
    {
        var app = try ui.App.init(.{ .allocator = t.allocator });
        defer app.deinit();
        const handle = try open(&app, root, home, "file.txt");
        const owner = try app.windowEntity(Shell, handle);
        _ = try app.step(0);
        try app.dispatch(handle, .{ .text = "dirty 日本語 " });
        try app.update(owner, Ops.new, .{});
        _ = try app.step(0.1);
        try app.dispatch(handle, .{ .text = "unsaved 👩‍💻" });
        _ = try app.step(0.2);
        try t.expect((try app.window(handle)).deadline != null);
        try settle(&app, owner, 0.5);
        try app.read(owner, Ops.check, .{ "dirty 日本語 disk", "unsaved 👩‍💻" });
    }
    try temp.dir.writeFile(t.io, .{ .sub_path = "file.txt", .data = "external" });
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const handle = try open(&app, root, home, null);
    const owner = try app.windowEntity(Shell, handle);
    try app.read(owner, Ops.check, .{ "dirty 日本語 disk", "unsaved 👩‍💻" });
    try app.update(owner, Ops.conflict, .{});
}

test "recovery excludes an explicitly discarded document before closing it" {
    var temp = t.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const home = try std.fs.path.join(t.allocator, &.{ root, "recovery" });
    defer t.allocator.free(home);
    {
        var app = try ui.App.init(.{ .allocator = t.allocator });
        defer app.deinit();
        const handle = try open(&app, root, home, null);
        const owner = try app.windowEntity(Shell, handle);
        _ = try app.step(0);
        try app.dispatch(handle, .{ .text = "discard me" });
        try settle(&app, owner, 1);
        try app.update(owner, Ops.command, .{.close_tab});
        try app.update(owner, Ops.command, .{.discard_dirty});
        for (0..2000) |iteration| {
            _ = try app.step(2 + @as(f64, @floatFromInt(iteration)) * 0.01);
            if (try app.read(owner, Ops.count, .{}) == 0) break;
            try std.Io.sleep(t.io, .fromMilliseconds(1), .awake);
        }
        try t.expectEqual(@as(usize, 0), try app.read(owner, Ops.count, .{}));
    }
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const handle = try open(&app, root, home, null);
    try t.expectEqual(@as(usize, 0), try app.read(try app.windowEntity(Shell, handle), Ops.count, .{}));
}

test "two live project windows keep independent recovery session locks" {
    var temp = t.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const home = try std.fs.path.join(t.allocator, &.{ root, "recovery" });
    defer t.allocator.free(home);
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const first = try open(&app, root, home, null);
    const owner = try app.windowEntity(Shell, first);
    try settle(&app, owner, 0);
    const second = try open(&app, root, home, null);
    var first_path: []u8 = undefined;
    var second_path: []u8 = undefined;
    try app.read(owner, Ops.storePath, .{ t.allocator, &first_path });
    defer t.allocator.free(first_path);
    try app.read(try app.windowEntity(Shell, second), Ops.storePath, .{ t.allocator, &second_path });
    defer t.allocator.free(second_path);
    try t.expect(!std.mem.eql(u8, first_path, second_path));
}

test "clean recovered files reopen current disk content" {
    var temp = t.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const home = try std.fs.path.join(t.allocator, &.{ root, "recovery" });
    defer t.allocator.free(home);
    try temp.dir.writeFile(t.io, .{ .sub_path = "file.txt", .data = "old" });
    {
        var app = try ui.App.init(.{ .allocator = t.allocator });
        defer app.deinit();
        const handle = try open(&app, root, home, "file.txt");
        try settle(&app, try app.windowEntity(Shell, handle), 0);
    }
    try temp.dir.writeFile(t.io, .{ .sub_path = "file.txt", .data = "new" });
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const handle = try open(&app, root, home, null);
    try app.read(try app.windowEntity(Shell, handle), Ops.cleanBytes, .{"new"});
}

test "window discard refuses edits made after confirmation while a writer is active" {
    var temp = t.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const home = try std.fs.path.join(t.allocator, &.{ root, "recovery" });
    defer t.allocator.free(home);
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const handle = try open(&app, root, home, null);
    const owner = try app.windowEntity(Shell, handle);
    _ = try app.step(0);
    try app.update(owner, Ops.replace, .{"confirmed"});
    _ = try app.step(0.1);
    _ = try app.step(0.4);
    try t.expect(try app.read(owner, Ops.busy, .{}));
    try app.update(owner, Ops.confirmWindowDiscard, .{});
    try app.update(owner, Ops.replace, .{"newer unconfirmed work"});
    try settle(&app, owner, 0.5);
    _ = try app.window(handle);
    try t.expectEqual(@as(usize, 1), try app.read(owner, Ops.count, .{}));
    try app.update(owner, Ops.checkpointBytes, .{"newer unconfirmed work"});
}

test "document discard cannot remove later edits during an active checkpoint" {
    var temp = t.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const home = try std.fs.path.join(t.allocator, &.{ root, "recovery" });
    defer t.allocator.free(home);
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const handle = try open(&app, root, home, null);
    const owner = try app.windowEntity(Shell, handle);
    _ = try app.step(0);
    try app.update(owner, Ops.replace, .{"old work"});
    _ = try app.step(0.1);
    _ = try app.step(0.4);
    try t.expect(try app.read(owner, Ops.busy, .{}));
    try app.update(owner, Ops.command, .{.close_tab});
    try app.update(owner, Ops.command, .{.discard_dirty});
    try app.update(owner, Ops.replace, .{"new work"});
    try settle(&app, owner, 0.5);
    try t.expectEqual(@as(usize, 1), try app.read(owner, Ops.count, .{}));
    try app.update(owner, Ops.checkpointBytes, .{"new work"});
}

test "failed checkpoint preserves the old backup and a persistent warning survives typing" {
    var temp = t.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const home = try std.fs.path.join(t.allocator, &.{ root, "recovery" });
    defer t.allocator.free(home);
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const handle = try open(&app, root, home, null);
    const owner = try app.windowEntity(Shell, handle);
    try app.update(owner, Ops.replace, .{"protected"});
    try settle(&app, owner, 0);
    var blocked: []u8 = undefined;
    try app.read(owner, Ops.corruptNextContent, .{ "new checkpoint", &blocked });
    defer t.allocator.free(blocked);
    try app.update(owner, Ops.replace, .{"new checkpoint"});
    _ = try app.step(1);
    for (0..2000) |iteration| {
        _ = try app.step(1.5 + @as(f64, @floatFromInt(iteration)) * 0.001);
        if (try app.read(owner, Ops.failed, .{})) break;
        try std.Io.sleep(t.io, .fromMilliseconds(1), .awake);
    }
    try t.expect(try app.read(owner, Ops.failed, .{}));
    try app.update(owner, Ops.checkpointBytes, .{"protected"});
    try app.dispatch(handle, .{ .text = "x" });
    _ = try app.step(1.6);
    const frame = &(try app.window(handle)).frames.committed;
    var warning = false;
    for (frame.nodes.items) |node| if (node.kind == .button and std.mem.eql(u8, node.kind.button.label, "Recovery failed")) {
        warning = true;
        try t.expect(std.mem.indexOf(u8, node.tooltip.?, "Last successful recovery checkpoint") != null);
    };
    try t.expect(warning);
}

test "destroying the application with a writer active releases the session lock" {
    var temp = t.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const home = try std.fs.path.join(t.allocator, &.{ root, "recovery" });
    defer t.allocator.free(home);
    var store_path: []u8 = undefined;
    {
        var app = try ui.App.init(.{ .allocator = t.allocator });
        defer app.deinit();
        const handle = try open(&app, root, home, null);
        const owner = try app.windowEntity(Shell, handle);
        try app.read(owner, Ops.storePath, .{ t.allocator, &store_path });
        _ = try app.step(0);
        _ = try app.step(0.3);
        try t.expect(try app.read(owner, Ops.busy, .{}));
    }
    defer t.allocator.free(store_path);
    const dir = try std.Io.Dir.cwd().openDir(t.io, store_path, .{});
    defer dir.close(t.io);
    const lock = try dir.createFile(t.io, "lock", .{ .truncate = false, .lock = .exclusive, .lock_nonblocking = true });
    lock.close(t.io);
}

test "continuous edits cannot move the checkpoint deadline beyond its maximum age" {
    var temp = t.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const home = try std.fs.path.join(t.allocator, &.{ root, "recovery" });
    defer t.allocator.free(home);
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const handle = try open(&app, root, home, null);
    const owner = try app.windowEntity(Shell, handle);
    _ = try app.step(0);
    for (1..11) |iteration| {
        try app.dispatch(handle, .{ .text = "a" });
        _ = try app.step(@as(f64, @floatFromInt(iteration)) * 0.1);
    }
    try t.expect(try app.read(owner, Ops.busy, .{}));
    try settle(&app, owner, 1.1);
    try app.update(owner, Ops.checkpointBytes, .{"aaaaaaaaaa"});
}

fn awaitApproval(app: *ui.App, owner: ui.Entity(Shell), time: f64) !f64 {
    for (0..2000) |iteration| {
        const now = time + @as(f64, @floatFromInt(iteration)) * 0.01;
        _ = try app.step(now);
        if (try app.read(owner, Ops.approved, .{})) return now;
        try std.Io.sleep(t.io, .fromMilliseconds(1), .awake);
    }
    return error.CloseNotApproved;
}

test "a late edit after window discard acknowledgment survives the actual close event" {
    var temp = t.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const home = try std.fs.path.join(t.allocator, &.{ root, "recovery" });
    defer t.allocator.free(home);
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const handle = try open(&app, root, home, null);
    const owner = try app.windowEntity(Shell, handle);
    try app.update(owner, Ops.replace, .{"confirmed discard"});
    try settle(&app, owner, 0);
    try app.update(owner, Ops.confirmWindowDiscard, .{});
    const acknowledged = try awaitApproval(&app, owner, 1);
    try app.update(owner, Ops.replace, .{"late new work"});
    _ = try app.step(acknowledged + 0.01);
    _ = try app.window(handle);
    try t.expect(!try app.read(owner, Ops.approved, .{}));
    try settle(&app, owner, acknowledged + 0.5);
    try app.update(owner, Ops.checkpointBytes, .{"late new work"});
}

test "a late edit after clean window checkpoint is revalidated before close" {
    var temp = t.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const home = try std.fs.path.join(t.allocator, &.{ root, "recovery" });
    defer t.allocator.free(home);
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const handle = try open(&app, root, home, null);
    const owner = try app.windowEntity(Shell, handle);
    try settle(&app, owner, 0);
    try app.requestCloseWindow(handle);
    const acknowledged = try awaitApproval(&app, owner, 1);
    try app.update(owner, Ops.replace, .{"new work after checkpoint"});
    _ = try app.step(acknowledged + 0.01);
    _ = try app.window(handle);
    try t.expect(!try app.read(owner, Ops.approved, .{}));
    try settle(&app, owner, acknowledged + 0.5);
    try app.update(owner, Ops.checkpointBytes, .{"new work after checkpoint"});
}

test "changed window discard creates a fresh session without overwriting another crashed window" {
    var temp = t.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const home = try std.fs.path.join(t.allocator, &.{ root, "recovery" });
    defer t.allocator.free(home);
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const handle = try open(&app, root, home, null);
    const owner = try app.windowEntity(Shell, handle);
    try app.update(owner, Ops.replace, .{"current window"});
    try settle(&app, owner, 0);
    var other_path: []u8 = undefined;
    {
        var other = try ui.App.init(.{ .allocator = t.allocator });
        defer other.deinit();
        const other_handle = try open(&other, root, home, null);
        const other_owner = try other.windowEntity(Shell, other_handle);
        try other.update(other_owner, Ops.replace, .{"other abandoned work"});
        try settle(&other, other_owner, 0);
        try other.read(other_owner, Ops.storePath, .{ t.allocator, &other_path });
    }
    defer t.allocator.free(other_path);
    const dir = try std.Io.Dir.cwd().openDir(t.io, other_path, .{});
    defer dir.close(t.io);
    const before = try dir.readFileAlloc(t.io, "index.json", t.allocator, .limited(65536));
    defer t.allocator.free(before);
    try app.update(owner, Ops.confirmWindowDiscard, .{});
    const acknowledged = try awaitApproval(&app, owner, 1);
    try app.update(owner, Ops.replace, .{"new work retained here"});
    _ = try app.step(acknowledged + 0.01);
    try settle(&app, owner, acknowledged + 0.5);
    try app.update(owner, Ops.checkpointBytes, .{"new work retained here"});
    const after = try dir.readFileAlloc(t.io, "index.json", t.allocator, .limited(65536));
    defer t.allocator.free(after);
    try t.expectEqualSlices(u8, before, after);
}

test "partial recovery restores valid work and retains a corrupt record through later publication" {
    var temp = t.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const home = try std.fs.path.join(t.allocator, &.{ root, "recovery" });
    defer t.allocator.free(home);
    var corrupted_path: []u8 = undefined;
    {
        var app = try ui.App.init(.{ .allocator = t.allocator });
        defer app.deinit();
        const handle = try open(&app, root, home, null);
        const owner = try app.windowEntity(Shell, handle);
        try app.update(owner, Ops.replace, .{"will be corrupted"});
        try app.update(owner, Ops.new, .{});
        try app.update(owner, Ops.replace, .{"valid work"});
        try settle(&app, owner, 0);
        try app.read(owner, Ops.contentPath, .{&corrupted_path});
    }
    defer t.allocator.free(corrupted_path);
    try std.Io.Dir.cwd().writeFile(t.io, .{ .sub_path = corrupted_path, .data = "damaged recovery bytes" });
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const handle = try open(&app, root, home, null);
    const owner = try app.windowEntity(Shell, handle);
    try app.read(owner, Ops.partialRestore, .{});
    try settle(&app, owner, 1);
    const retained = try std.Io.Dir.cwd().readFileAlloc(t.io, corrupted_path, t.allocator, .limited(100));
    defer t.allocator.free(retained);
    try t.expectEqualStrings("damaged recovery bytes", retained);
}

test "unavailable recovery remains visible and does not trap an explicitly discarded window" {
    var temp = t.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const home = try std.fs.path.join(t.allocator, &.{ root, "recovery" });
    defer t.allocator.free(home);
    try temp.dir.writeFile(t.io, .{ .sub_path = "recovery", .data = "not a directory" });
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const handle = try open(&app, root, home, null);
    const owner = try app.windowEntity(Shell, handle);
    _ = try app.step(0);
    try app.dispatch(handle, .{ .text = "local work" });
    _ = try app.step(0.1);
    try t.expect(try app.read(owner, Ops.failed, .{}));
    var warning = false;
    for ((try app.window(handle)).frames.committed.nodes.items) |node| if (node.kind == .button and std.mem.eql(u8, node.kind.button.label, "Recovery failed")) {
        warning = true;
    };
    try t.expect(warning);
    try app.update(owner, Ops.confirmWindowDiscard, .{});
    _ = try app.step(0.2);
    try t.expectError(error.WindowNotFound, app.window(handle));
}
