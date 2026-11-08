const std = @import("std");
const builtin = @import("builtin");
const zircon = @import("zircon");
const ui = @import("zircon_ui");
const t = std.testing;

fn bounds(app: *ui.App, h: ui.WindowHandle, name: []const u8, button: bool) !ui.Rect {
    const frame = &(try app.window(h)).frames.committed;
    for (frame.nodes.items, 0..) |node, i| {
        if (button and node.kind == .button and std.mem.eql(u8, node.kind.button.label, name)) return frame.bounds[i];
        if (!button) if (node.key) |key| if (key == .string and std.mem.eql(u8, key.string, name)) return frame.bounds[i];
    }
    return error.ControlNotFound;
}
fn center(rect: ui.Rect) ui.Point {
    return .{ .x = rect.x + rect.width / 2, .y = rect.y + rect.height / 2 };
}
fn click(app: *ui.App, h: ui.WindowHandle, name: []const u8) !void {
    const position = center(try bounds(app, h, name, true));
    try app.dispatch(h, .{ .pointer_down = .{ .position = position } });
    try app.dispatch(h, .{ .pointer_up = .{ .position = position } });
    _ = try app.step(1);
}
const Ops = struct {
    fn open(self: *zircon.Shell, cx: *ui.Context(zircon.Shell)) !void {
        self.git_anchor = .{ .x = 100, .y = 4, .width = 100, .height = 24 };
        self.git.menu = .branches;
        cx.notify();
    }
    fn query(self: *zircon.Shell, cx: *ui.Context(zircon.Shell), expected: []const u8) !void {
        var value: []u8 = &.{};
        try cx.read(self.fields.?.path, ui.controls.TextInput.copy, .{ t.allocator, &value });
        defer t.allocator.free(value);
        try t.expectEqualStrings(expected, value);
    }
    fn git(self: *zircon.Shell, cx: *ui.Context(zircon.Shell)) void {
        self.left_panel = .git_changes;
        cx.notify();
    }
    fn split(self: *zircon.Shell, cx: *ui.Context(zircon.Shell)) !void {
        var event: ui.Event(ui.Click) = .{ .data = .{} };
        try self.onCommand(&event, cx, .split_down);
    }
};

test "branch and stash tabs retain popup placement across repeated pointer clicks" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const h = try app.openWindow(zircon.Shell, .{ .visible = false, .width = 1240, .height = 820 }, try zircon.Shell.init(t.allocator, t.io, root, null));
    const owner = try app.windowEntity(zircon.Shell, h);
    try app.update(owner, zircon.Shell.bootstrap, .{h});
    try app.update(owner, Ops.open, .{});
    _ = try app.step(1);
    const original = try bounds(&app, h, "git-controls", false);
    for (0..5) |_| {
        try click(&app, h, "Stashes");
        try t.expectEqual(original, try bounds(&app, h, "git-controls", false));
        try app.dispatch(h, .{ .text = "stash search" });
        try app.update(owner, Ops.query, .{"stash search"});
        try click(&app, h, "Branches");
        try app.update(owner, Ops.query, .{""});
        try app.dispatch(h, .{ .text = "branch search" });
        try app.update(owner, Ops.query, .{"branch search"});
        try t.expectEqual(original, try bounds(&app, h, "git-controls", false));
    }
}
fn expectCursor(app: *ui.App, h: ui.WindowHandle, cursor: ui.Cursor) !void {
    try t.expectEqual(cursor, (try app.window(h)).cursor);
    if (ui.testing.native != void) {
        const objc = ui.testing.native.objc;
        const selector: [:0]const u8 = switch (cursor) {
            .resize_horizontal => "resizeLeftRightCursor",
            .resize_vertical => "resizeUpDownCursor",
            else => "arrowCursor",
        };
        const expected = objc.send(objc.Id, objc.class("NSCursor"), selector, .{});
        try t.expectEqual(expected, objc.send(objc.Id, objc.class("NSCursor"), "currentCursor", .{}));
    }
}
test "Git sidebar and pane resize cursors track hover capture release and blur" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const h = try app.openWindow(zircon.Shell, .{ .visible = false, .width = 1240, .height = 820 }, try zircon.Shell.init(t.allocator, t.io, root, null));
    const owner = try app.windowEntity(zircon.Shell, h);
    try app.update(owner, zircon.Shell.bootstrap, .{h});
    try app.update(owner, Ops.git, .{});
    _ = try app.step(1);
    try app.dispatch(h, .{ .focus = true });
    const point = center(try bounds(&app, h, "sidebar-divider", false));
    try app.dispatch(h, .{ .pointer_move = .{ .position = point } });
    try expectCursor(&app, h, .resize_horizontal);
    try app.dispatch(h, .{ .pointer_down = .{ .position = point } });
    const outside: ui.Point = .{ .x = point.x + 80, .y = point.y };
    try app.dispatch(h, .{ .pointer_move = .{ .position = outside } });
    try expectCursor(&app, h, .resize_horizontal);
    try app.dispatch(h, .{ .pointer_up = .{ .position = outside } });
    try expectCursor(&app, h, .arrow);
    try app.dispatch(h, .pointer_leave);
    try expectCursor(&app, h, .arrow);
    try app.update(owner, Ops.split, .{});
    _ = try app.step(1);
    const horizontal = center(try bounds(&app, h, "pane-divider", false));
    try app.dispatch(h, .{ .pointer_move = .{ .position = horizontal } });
    try expectCursor(&app, h, .resize_vertical);
    try app.dispatch(h, .{ .focus = false });
    try expectCursor(&app, h, .arrow);
}

fn git(root: []const u8, args: []const []const u8) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(t.allocator);
    try argv.appendSlice(t.allocator, &.{ "/usr/bin/git", "-C", root });
    try argv.appendSlice(t.allocator, args);
    const result = try std.process.run(t.allocator, t.io, .{ .argv = argv.items });
    defer t.allocator.free(result.stdout);
    defer t.allocator.free(result.stderr);
    try t.expect(result.term.success());
}
const CountOps = struct {
    fn ready(self: *const zircon.Shell) bool {
        return !self.git.busy and self.git.status != null and self.git.status.?.entries.len == 2;
    }
};
test "Git rows render real rounded counts and joined action menus at narrow widths" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "main.txt", .data = "one\ntwo\nthree\n" });
    try git(root, &.{ "init", "-q" });
    try git(root, &.{ "add", "main.txt" });
    try git(root, &.{ "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false", "commit", "-qm", "initial" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "main.txt", .data = "one\nreplacement\nthree\n" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "image.bin", .data = "\x00binary" });
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const h = try app.openWindow(zircon.Shell, .{ .visible = false, .width = 1240, .height = 820 }, try zircon.Shell.init(t.allocator, t.io, root, null));
    const owner = try app.windowEntity(zircon.Shell, h);
    try app.update(owner, zircon.Shell.bootstrap, .{h});
    try app.update(owner, Ops.git, .{});
    const deadline = std.Io.Clock.awake.now(t.io).addDuration(.fromSeconds(5));
    while (!try app.read(owner, CountOps.ready, .{})) {
        _ = try app.step(1);
        if (std.Io.Clock.awake.now(t.io).compare(.gte, deadline)) return error.GitCountsTimeout;
        try std.Io.sleep(t.io, .fromMilliseconds(1), .awake);
    }
    for ([_]f32{ 1240, 620 }) |width| {
        try app.dispatch(h, .{ .resize = .{ .width = width, .height = 820 } });
        _ = try app.step(1);
        const frame = &(try app.window(h)).frames.committed;
        var additions = false;
        var deletions = false;
        var binary = false;
        for (frame.nodes.items) |node| if (node.kind == .text) {
            const label = node.kind.text;
            if (std.mem.eql(u8, label, "+1") or std.mem.eql(u8, label, "−1")) {
                additions = additions or std.mem.eql(u8, label, "+1");
                deletions = deletions or std.mem.eql(u8, label, "−1");
                const badge = frame.nodes.items[node.parent.?];
                try t.expectEqual(@as(f32, 4), badge.style.radius);
                try t.expectEqual(@as(f32, 0.12), badge.style.background.?.a);
            }
            binary = binary or std.mem.eql(u8, label, "Binary");
            try t.expect(!std.mem.eql(u8, label, "A") and !std.mem.eql(u8, label, "M") and !std.mem.eql(u8, label, "D"));
        };
        try t.expect(additions and deletions and binary);
        const main = try bounds(&app, h, "Stage all", true);
        const arrow = try bounds(&app, h, "Change actions", true);
        try t.expectApproxEqAbs(main.x + main.width + 1, arrow.x, 0.1);
        try t.expectEqual(main.y, arrow.y);
        try t.expect((try bounds(&app, h, "git-stage-control", false)).width >= main.width + arrow.width);
        const publish = try bounds(&app, h, "Publish", true);
        const remote = try bounds(&app, h, "Remote actions", true);
        try t.expectApproxEqAbs(publish.x + publish.width + 1, remote.x, 0.1);
    }
}
