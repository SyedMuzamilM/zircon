const std = @import("std");
const zircon = @import("zircon");
const ui = @import("zircon_ui");
const zircon_workspace = @import("zircon_workspace");
const t = std.testing;
test "shell opens an untitled document and builds its real custom editor" {
    var app = try ui.App.init(.{ .allocator = std.testing.allocator });
    defer app.deinit();
    var shell = try zircon.Shell.init(std.testing.allocator, std.testing.io, ".", null);
    const h = app.openWindow(zircon.Shell, .{ .visible = false, .width = 1000, .height = 700 }, shell) catch |err| {
        shell.deinit(std.testing.allocator);
        return err;
    };
    const owner = try app.windowEntity(zircon.Shell, h);
    try app.update(owner, zircon.Shell.bootstrap, .{h});
    _ = try app.step(0);
    try std.testing.expect((try app.window(h)).frames.committed.nodes.items.len > 10);
}

test "editor input publishes one ordered document change with a typed origin" {
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    var shell = try zircon.Shell.init(t.allocator, t.io, ".", null);
    const h = app.openWindow(zircon.Shell, .{ .visible = false, .width = 1000, .height = 700 }, shell) catch |err| {
        shell.deinit(t.allocator);
        return err;
    };
    const owner = try app.windowEntity(zircon.Shell, h);
    try app.update(owner, zircon.Shell.bootstrap, .{h});
    _ = try app.step(0);
    try app.dispatch(h, .{ .text = "hello" });
    try t.expectEqual(@as(usize, 1), try app.read(owner, zircon.Shell.documentChangeCount, .{}));
    try t.expectEqual(zircon_workspace.ChangeOrigin.typing, try app.read(owner, zircon.Shell.documentChangeOrigin, .{0}));
    try app.update(owner, zircon.Shell.clearDocumentChanges, .{});
    try t.expectEqual(@as(usize, 0), try app.read(owner, zircon.Shell.documentChangeCount, .{}));
}

test "command undo and redo publish reset events in document revision order" {
    const Commands = struct {
        fn execute(self: *zircon.Shell, cx: *ui.Context(zircon.Shell), command: zircon.Command) !void {
            var click: ui.Event(ui.Click) = .{ .data = .{} };
            try self.onCommand(&click, cx, command);
        }
        fn check(self: *const zircon.Shell) !void {
            try t.expectEqual(@as(usize, 3), self.document_changes.len);
            const typed = self.document_changes.get(0).?;
            const undone = self.document_changes.get(1).?;
            const redone = self.document_changes.get(2).?;
            try t.expectEqual(zircon_workspace.ChangeOrigin.undo, undone.origin);
            try t.expectEqual(zircon_workspace.ChangeOrigin.redo, redone.origin);
            try t.expectEqual(typed.after, undone.before);
            try t.expectEqual(undone.after, redone.before);
            try t.expectEqual(@as(usize, 0), undone.mappings.len);
            try t.expectEqual(typed.state, redone.state);
        }
    };
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    var shell = try zircon.Shell.init(t.allocator, t.io, ".", null);
    const h = app.openWindow(zircon.Shell, .{ .visible = false, .width = 1000, .height = 700 }, shell) catch |err| {
        shell.deinit(t.allocator);
        return err;
    };
    const owner = try app.windowEntity(zircon.Shell, h);
    try app.update(owner, zircon.Shell.bootstrap, .{h});
    _ = try app.step(0);
    try app.dispatch(h, .{ .text = "hello" });
    try app.update(owner, Commands.execute, .{.undo});
    try app.update(owner, Commands.execute, .{.redo});
    try app.read(owner, Commands.check, .{});
}
test "Vim undo and redo publish their actual history origins" {
    const Commands = struct {
        fn execute(self: *zircon.Shell, cx: *ui.Context(zircon.Shell), command: zircon.Command) !void {
            var click: ui.Event(ui.Click) = .{ .data = .{} };
            try self.onCommand(&click, cx, command);
        }
        fn check(self: *const zircon.Shell) !void {
            try t.expectEqual(@as(usize, 3), self.document_changes.len);
            const typed = self.document_changes.get(0).?;
            const undone = self.document_changes.get(1).?;
            const redone = self.document_changes.get(2).?;
            try t.expectEqual(zircon_workspace.ChangeOrigin.undo, undone.origin);
            try t.expectEqual(zircon_workspace.ChangeOrigin.redo, redone.origin);
            try t.expectEqual(typed.after, undone.before);
            try t.expectEqual(undone.after, redone.before);
            try t.expectEqual(@as(usize, 0), undone.mappings.len);
            try t.expectEqual(typed.state, redone.state);
        }
    };
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    var shell = try zircon.Shell.init(t.allocator, t.io, ".", null);
    const h = app.openWindow(zircon.Shell, .{ .visible = false, .width = 1000, .height = 700 }, shell) catch |err| {
        shell.deinit(t.allocator);
        return err;
    };
    const owner = try app.windowEntity(zircon.Shell, h);
    try app.update(owner, zircon.Shell.bootstrap, .{h});
    _ = try app.step(0);
    try app.dispatch(h, .{ .text = "hello" });
    try app.update(owner, Commands.execute, .{.toggle_vim});
    try app.dispatch(h, .{ .text = "u" });
    try app.dispatch(h, .{ .key_down = .{ .key = .r, .modifiers = .{ .control = true } } });
    try app.read(owner, Commands.check, .{});
}

const Ops = struct {
    fn add(self: *zircon.Shell, cx: *ui.Context(zircon.Shell)) !void {
        try self.newFile();
        cx.notify();
    }
    fn copy(self: *const zircon.Shell, a: std.mem.Allocator, out: *[]u8) !void {
        var s = try self.workspace.snapshot(self.tabs.items[self.active].document);
        defer s.deinit();
        out.* = try s.copy(a, .{ .start = 0, .end = s.byteLen() });
    }
};
test "clicking a tab must return keyboard editing to its document" {
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    var shell = try zircon.Shell.init(t.allocator, t.io, ".", null);
    const h = app.openWindow(zircon.Shell, .{ .visible = false, .width = 1000, .height = 700 }, shell) catch |err| {
        shell.deinit(t.allocator);
        return err;
    };
    const owner = try app.windowEntity(zircon.Shell, h);
    try app.update(owner, Ops.add, .{});
    _ = try app.step(0);
    const w = try app.window(h);
    var position: ui.Point = undefined;
    var found = false;
    for (w.frames.committed.nodes.items, 0..) |node, i| if (node.kind == .button and std.mem.startsWith(u8, node.kind.button.label, "Untitled")) {
        const b = w.frames.committed.bounds[i];
        position = .{ .x = b.x + 5, .y = b.y + 5 };
        found = true;
        break;
    };
    try t.expect(found);
    try app.dispatch(h, .{ .pointer_down = .{ .position = position } });
    try app.dispatch(h, .{ .pointer_up = .{ .position = position } });
    _ = try app.step(1);
    try app.dispatch(h, .{ .text = "x" });
    _ = try app.step(2);
    var actual: []u8 = undefined;
    try app.read(owner, Ops.copy, .{ t.allocator, &actual });
    defer t.allocator.free(actual);
    try t.expectEqualStrings("x", actual);
}

const AppOps = struct {
    fn command(self: *zircon.Shell, cx: *ui.Context(zircon.Shell), action: zircon.Command) !void {
        var e: ui.Event(ui.Click) = .{ .data = .{} };
        try self.onCommand(&e, cx, action);
    }
    fn overlay(self: *const zircon.Shell) bool {
        return self.overlay == .dirty;
    }
    fn title(self: *const zircon.Shell) usize {
        return self.tabs.items.len;
    }
    fn copy(self: *const zircon.Shell, a: std.mem.Allocator, out: *[]u8) !void {
        var snap = try self.workspace.snapshot(self.tabs.items[self.active].document);
        defer snap.deinit();
        out.* = try snap.copy(a, .{ .start = 0, .end = snap.byteLen() });
    }
};
fn createIn(app: *ui.App, path: []const u8, initial: ?[]const u8) !ui.WindowHandle {
    var shell = try zircon.Shell.init(t.allocator, t.io, path, initial);
    const h = app.openWindow(zircon.Shell, .{ .visible = false, .width = 1000, .height = 700 }, shell) catch |err| {
        shell.deinit(t.allocator);
        return err;
    };
    const owner = try app.windowEntity(zircon.Shell, h);
    try app.update(owner, zircon.Shell.bootstrap, .{h});
    _ = try app.step(0);
    return h;
}
fn sendCommand(app: *ui.App, h: ui.WindowHandle, action: zircon.Command) !void {
    try app.update(try app.windowEntity(zircon.Shell, h), AppOps.command, .{action});
}
fn replaceField(app: *ui.App, h: ui.WindowHandle, value: []const u8) !void {
    try app.dispatch(h, .{ .key_down = .{ .key = .a, .modifiers = .{ .command = true } } });
    try app.dispatch(h, .{ .text = value });
}
test "save as writes actual bytes and saving separates later typing undo history" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(path);
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const h = try createIn(&app, path, null);
    const owner = try app.windowEntity(zircon.Shell, h);
    try app.dispatch(h, .{ .text = "first" });
    _ = try app.step(1);
    try sendCommand(&app, h, .save);
    _ = try app.step(2);
    try replaceField(&app, h, "saved.zig");
    _ = try app.step(3);
    try app.dispatch(h, .{ .key_down = .{ .key = .enter } });
    _ = try app.step(4);
    const disk = try tmp.dir.readFileAlloc(t.io, "saved.zig", t.allocator, .limited(100));
    defer t.allocator.free(disk);
    try t.expectEqualStrings("first", disk);
    try app.dispatch(h, .{ .text = " second" });
    _ = try app.step(5);
    try app.dispatch(h, .{ .key_down = .{ .key = .z, .modifiers = .{ .command = true } } });
    _ = try app.step(6);
    var actual: []u8 = undefined;
    try app.read(owner, AppOps.copy, .{ t.allocator, &actual });
    defer t.allocator.free(actual);
    try t.expectEqualStrings("first", actual);
    try sendCommand(&app, h, .close_tab);
    _ = try app.step(7);
    try t.expectEqual(@as(usize, 0), try app.read(owner, AppOps.title, .{}));
}
test "dirty native-close policy cancel preserves state and discard closes" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(path);
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const h = try createIn(&app, path, null);
    const owner = try app.windowEntity(zircon.Shell, h);
    try app.dispatch(h, .{ .text = "unsaved" });
    _ = try app.step(1);
    try app.closeWindow(h);
    _ = try app.step(2);
    try t.expect(try app.read(owner, AppOps.overlay, .{}));
    try sendCommand(&app, h, .dismiss);
    _ = try app.step(3);
    var bytes: []u8 = undefined;
    try app.read(owner, AppOps.copy, .{ t.allocator, &bytes });
    defer t.allocator.free(bytes);
    try t.expectEqualStrings("unsaved", bytes);
    try app.closeWindow(h);
    _ = try app.step(4);
    try sendCommand(&app, h, .discard_dirty);
    _ = try app.step(5);
    try t.expectError(error.WindowNotFound, app.window(h));
}
test "quick open uses real background-indexed files and returns typing focus" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "target.zig", .data = "const value = 1;\n" });
    const path = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(path);
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const h = try createIn(&app, path, null);
    const owner = try app.windowEntity(zircon.Shell, h);
    while (try app.tasksPending()) {
        _ = try app.step(0);
        std.atomic.spinLoopHint();
    }
    try sendCommand(&app, h, .quick_open);
    _ = try app.step(1);
    try app.dispatch(h, .{ .text = "target" });
    _ = try app.step(2);
    try app.dispatch(h, .{ .key_down = .{ .key = .enter } });
    _ = try app.step(3);
    try app.dispatch(h, .{ .text = "// " });
    _ = try app.step(4);
    var bytes: []u8 = undefined;
    try app.read(owner, AppOps.copy, .{ t.allocator, &bytes });
    defer t.allocator.free(bytes);
    try t.expectEqualStrings("// const value = 1;\n", bytes);
}
