const std = @import("std");
const zircon = @import("zircon");
const ui = @import("zircon_ui");
const t = std.testing;
const Tree = @FieldType(@FieldType(zircon.Shell, "git"), "tree");

fn entry(path: []const u8) zircon.git.Entry {
    return .{ .path = path, .index = .clean, .worktree = .modified, .staged = false, .unstaged = true };
}

test "Git tree compacts single-child directories and preserves branching depth" {
    var tree: Tree = .{};
    defer tree.deinit(t.allocator);
    const entries = [_]zircon.git.Entry{ entry("src/a/b/file.md"), entry("src/a/b/other.md"), entry("src/other.txt") };
    const rows = try tree.rows(t.allocator, &entries);
    defer t.allocator.free(rows);
    try t.expectEqual(@as(usize, 6), rows.len);
    try t.expectEqualStrings("src", rows[1].directory.label);
    try t.expectEqualStrings("src/a/b", rows[2].directory.path);
    try t.expectEqualStrings("a/b", rows[2].directory.label);
    try t.expectEqual(@as(usize, 1), rows[2].directory.depth);
    try t.expectEqual(@as(usize, 2), rows[3].file.depth);
    try t.expectEqual(@as(u32, 0), rows[3].file.index);
    try t.expectEqual(@as(usize, 1), rows[5].file.depth);
}

test "Git compact directories preserve collapsed ancestors and list view ignores folder collapse" {
    var tree: Tree = .{};
    defer tree.deinit(t.allocator);
    var untracked = entry("tests/unit/lib/helper.zig");
    untracked.worktree = .untracked;
    const entries = [_]zircon.git.Entry{ entry("src/a/b/file.md"), entry("src/a/b/other.md"), untracked };
    {
        const rows = try tree.rows(t.allocator, &entries);
        defer t.allocator.free(rows);
        try t.expectEqual(@as(usize, 7), rows.len);
        try t.expectEqualStrings("src/a/b", rows[1].directory.label);
        try t.expectEqualStrings("tests/unit/lib", rows[5].directory.label);
    }
    try tree.toggleDirectory(t.allocator, "src/a");
    {
        const rows = try tree.rows(t.allocator, &entries);
        defer t.allocator.free(rows);
        try t.expectEqual(@as(usize, 5), rows.len);
        try t.expectEqualStrings("src/a", rows[1].directory.label);
    }
    tree.mode = .list;
    {
        const rows = try tree.rows(t.allocator, &entries);
        defer t.allocator.free(rows);
        try t.expectEqual(@as(usize, 5), rows.len);
        try t.expectEqual(@as(usize, 2), rows[0].section.count);
        try t.expectEqual(@as(usize, 0), rows[1].file.depth);
        try t.expectEqual(@as(u32, 0), rows[1].file.index);
        try t.expectEqual(@as(u32, 1), rows[2].file.index);
        try t.expectEqual(@as(usize, 1), rows[3].section.count);
        try t.expectEqual(@as(u32, 2), rows[4].file.index);
    }
}

const Ops = struct {
    fn seed(self: *zircon.Shell, cx: *ui.Context(zircon.Shell)) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        const entries = try arena.allocator().alloc(zircon.git.Entry, 2);
        entries[0] = entry("src/a/b/file.md");
        entries[1] = entry("src/a/b/other.md");
        self.git.status = .{ .arena = arena, .branch = "main", .entries = entries };
        self.git.repository = true;
        self.left_panel = .git_changes;
        cx.notify();
    }
    fn flat(self: *const zircon.Shell) bool {
        return self.git.tree.mode == .list;
    }
};
fn textVisible(app: *ui.App, h: ui.WindowHandle, bytes: []const u8) !bool {
    for ((try app.window(h)).frames.committed.nodes.items) |node| if (node.kind == .text and std.mem.eql(u8, node.kind.text, bytes)) return true;
    return false;
}
fn click(app: *ui.App, h: ui.WindowHandle, label: []const u8) !void {
    const frame = &(try app.window(h)).frames.committed;
    const rect = for (frame.nodes.items, 0..) |node, index| {
        if (node.kind == .button and std.mem.eql(u8, node.kind.button.label, label)) break frame.bounds[index];
    } else return error.MissingButton;
    const point: ui.Point = .{ .x = rect.x + rect.width / 2, .y = rect.y + rect.height / 2 };
    try app.dispatch(h, .{ .pointer_down = .{ .position = point } });
    try app.dispatch(h, .{ .pointer_up = .{ .position = point } });
    _ = try app.step(0);
}

test "Git sidebar toggles compact tree and flat changed-file list" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "main.zig", .data = "abc\n" });
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const h = try app.openWindow(zircon.Shell, .{ .visible = false, .width = 1100, .height = 760 }, try zircon.Shell.init(t.allocator, t.io, root, "main.zig"));
    const owner = try app.windowEntity(zircon.Shell, h);
    try app.update(owner, Ops.seed, .{});
    _ = try app.step(0);
    try t.expect(try textVisible(&app, h, "src/a/b"));
    try click(&app, h, "src/a/b");
    try t.expect(!try textVisible(&app, h, "file.md"));
    try click(&app, h, "Show changes as list");
    try t.expect(try app.read(owner, Ops.flat, .{}));
    try t.expect(try textVisible(&app, h, "file.md"));
    try t.expect(try textVisible(&app, h, "other.md"));
    try click(&app, h, "Show changes as tree");
    try t.expect(!try app.read(owner, Ops.flat, .{}));
    try t.expect(!try textVisible(&app, h, "file.md"));
}
