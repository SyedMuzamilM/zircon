const std = @import("std");
const zircon = @import("zircon");
const ui = @import("zircon_ui");
const t = std.testing;

fn git(root: []const u8, args: []const []const u8) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(t.allocator);
    try argv.appendSlice(t.allocator, &.{ "git", "-C", root });
    try argv.appendSlice(t.allocator, args);
    const result = try std.process.run(t.allocator, t.io, .{ .argv = argv.items });
    defer t.allocator.free(result.stdout);
    defer t.allocator.free(result.stderr);
    try t.expect(result.term.success());
}
fn settle(app: *ui.App, time: f64) !void {
    _ = try app.step(time);
    const deadline = std.Io.Clock.awake.now(t.io).addDuration(.fromSeconds(5));
    while (try app.tasksPending()) {
        _ = try app.step(time);
        if (std.Io.Clock.awake.now(t.io).compare(.gte, deadline)) return error.SidebarTimeout;
        try std.Io.sleep(t.io, .fromMilliseconds(1), .awake);
    }
    _ = try app.step(time);
}
fn open(app: *ui.App, root: []const u8, file: []const u8) !ui.WindowHandle {
    var shell = try zircon.Shell.init(t.allocator, t.io, root, file);
    const h = app.openWindow(zircon.Shell, .{ .visible = false, .width = 1000, .height = 700 }, shell) catch |err| {
        shell.deinit(t.allocator);
        return err;
    };
    const owner = try app.windowEntity(zircon.Shell, h);
    try app.update(owner, zircon.Shell.bootstrap, .{h});
    try settle(app, 0);
    return h;
}
const Ops = struct {
    fn treeUpdated(self: *const zircon.Shell) bool {
        var root_file = false;
        var nested_file = false;
        var expanded = false;
        var collapsed = false;
        for (self.tree.items) |row| {
            if (std.mem.eql(u8, row.name, "obsolete.txt")) return false;
            if (std.mem.eql(u8, row.name, "new.txt")) root_file = row.depth == 0;
            if (std.mem.eql(u8, row.name, "nested.txt")) nested_file = row.depth == 1;
            if (std.mem.eql(u8, row.name, "src")) expanded = row.expanded;
            if (std.mem.eql(u8, row.name, "hidden")) collapsed = !row.expanded;
        }
        return root_file and nested_file and expanded and collapsed;
    }
    fn showGit(self: *zircon.Shell, cx: *ui.Context(zircon.Shell)) void {
        self.left_panel = .git_changes;
        cx.notify();
    }
    fn openFile(self: *zircon.Shell, cx: *ui.Context(zircon.Shell), path: []const u8) !void {
        try self.openPath(path);
        cx.notify();
    }
    fn markers(self: *const zircon.Shell) usize {
        return self.tabs.items[self.active].editor.git_changes.len;
    }
    fn colors(self: *const zircon.Shell) @FieldType(zircon.Shell, "colors") {
        return self.colors;
    }
};
fn expectColor(app: *ui.App, h: ui.WindowHandle, name: []const u8, color: ui.Color) !void {
    for ((try app.window(h)).frames.committed.nodes.items) |node| {
        if (node.kind == .text and std.mem.eql(u8, node.kind.text, name) and std.meta.eql(node.style.text.color, color)) return;
    }
    std.debug.print("Missing sidebar color for {s}\n", .{name});
    return error.MissingFileColor;
}

test "sidebar discovers external files and removals without collapsing folders" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(t.io, "src", .default_dir);
    try tmp.dir.createDir(t.io, "hidden", .default_dir);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "src/main.txt", .data = "main\n" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "obsolete.txt", .data = "old\n" });
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const h = try open(&app, root, "src/main.txt");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "new.txt", .data = "new\n" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "src/nested.txt", .data = "nested\n" });
    try tmp.dir.deleteFile(t.io, "obsolete.txt");
    try settle(&app, 2);
    const owner = try app.windowEntity(zircon.Shell, h);
    try t.expect(try app.read(owner, Ops.treeUpdated, .{}));
}

test "sidebars refresh Git filename colors and new files have no line gutters" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "main.txt", .data = "old\n" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "gone.txt", .data = "gone\n" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "empty.txt", .data = "" });
    try git(root, &.{ "init", "-q" });
    try git(root, &.{ "add", "." });
    try git(root, &.{ "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false", "commit", "-qm", "initial" });
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const h = try open(&app, root, "main.txt");
    const owner = try app.windowEntity(zircon.Shell, h);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "main.txt", .data = "modified\n" });
    try tmp.dir.deleteFile(t.io, "gone.txt");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "new.txt", .data = "new\n" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "staged.txt", .data = "staged\n" });
    try git(root, &.{ "add", "staged.txt" });
    try settle(&app, 2);
    const colors = try app.read(owner, Ops.colors, .{});
    try expectColor(&app, h, "main.txt", colors.modified);
    try expectColor(&app, h, "new.txt", colors.added);
    try expectColor(&app, h, "staged.txt", colors.added);
    try app.update(owner, Ops.showGit, .{});
    _ = try app.step(2);
    try expectColor(&app, h, "main.txt", colors.modified);
    try expectColor(&app, h, "new.txt", colors.added);
    try expectColor(&app, h, "gone.txt", colors.deleted);
    try app.update(owner, Ops.openFile, .{"new.txt"});
    try settle(&app, 4);
    try t.expectEqual(@as(usize, 0), try app.read(owner, Ops.markers, .{}));
    try app.dispatch(h, .{ .text = "more\n" });
    try settle(&app, 6);
    try t.expectEqual(@as(usize, 0), try app.read(owner, Ops.markers, .{}));
    try app.update(owner, Ops.openFile, .{"staged.txt"});
    try app.dispatch(h, .{ .text = "more\n" });
    try settle(&app, 8);
    try t.expectEqual(@as(usize, 0), try app.read(owner, Ops.markers, .{}));
    try app.update(owner, Ops.openFile, .{"empty.txt"});
    try app.dispatch(h, .{ .text = "tracked addition\n" });
    try settle(&app, 10);
    try t.expect(try app.read(owner, Ops.markers, .{}) > 0);
}
