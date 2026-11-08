const zircon = @import("zircon");
const ui = @import("zircon_ui");
const std = @import("std");
const builtin = @import("builtin");
const git = @import("zircon_git");
const t = std.testing;
fn run(root: []const u8, args: []const []const u8) ![]u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(t.allocator);
    try argv.appendSlice(t.allocator, &.{ "git", "-C", root });
    try argv.appendSlice(t.allocator, args);
    const result = try std.process.run(t.allocator, t.io, .{ .argv = argv.items });
    defer t.allocator.free(result.stderr);
    errdefer t.allocator.free(result.stdout);
    if (result.term != .exited or result.term.exited != 0) {
        std.debug.print("Git fixture failed: {s}\n", .{result.stderr});
        return error.FixtureGitFailed;
    }
    return result.stdout;
}
fn command(root: []const u8, args: []const []const u8) !void {
    const bytes = try run(root, args);
    t.allocator.free(bytes);
}

fn settle(app: *ui.App) !void {
    const deadline = std.Io.Clock.awake.now(t.io).addDuration(.fromSeconds(5));
    while (try app.tasksPending()) {
        _ = try app.step(0);
        if (std.Io.Clock.awake.now(t.io).compare(.gte, deadline)) return error.JourneyTimeout;
        std.Io.sleep(t.io, .fromMilliseconds(1), .awake) catch {};
    }
    _ = try app.step(0);
}
const Ops = struct {
    fn refresh(self: *zircon.Shell, cx: *ui.Context(zircon.Shell)) !void {
        self.git.next_refresh = 0;
        try self.pollLanguage(cx);
    }
    fn matchesHead(self: *const zircon.Shell, expected: []const u8) !void {
        try t.expect(self.git.commits.len > 0);
        std.debug.print("history cached head={s}, external head={s}\n", .{self.git.commits[0].oid, expected});
        try t.expectEqualStrings(expected, self.git.commits[0].oid);
    }
    fn command(self: *zircon.Shell, cx: *ui.Context(zircon.Shell), which: zircon.Command) !void {
        var event: ui.Event(ui.Click) = .{.data=.{}};
        try self.onCommand(&event, cx, which);
        if (self.status_is_error) {
            std.debug.print("app error: {s}\n", .{self.status});
            return error.CommandFailed;
        }
    }
    fn spacedSourceEditable(self: *const zircon.Shell) !void {
        const projection = self.git.editable.?;
        std.debug.print("space-name editable sources={d}\n", .{projection.sources.items.len});
        try t.expectEqual(@as(usize,1),projection.sources.items.len);
    }
    fn mixedBinaryVisible(self: *const zircon.Shell) !void {
        const status = self.git.status.?;
        const projection = self.git.projection.?;
        std.debug.print("mixed comparison status entries={d}, projected files={d}\n", .{status.entries.len,projection.files.len});
        try t.expectEqual(@as(usize,2),status.entries.len);
        for (projection.files) |file| if (std.mem.eql(u8,file.path,"binary.dat")) return;
        return error.BinaryFileMissingFromComparison;
    }
    fn stashInstalled(self: *const zircon.Shell) !void {
        try t.expect(self.git.stash_view);
        std.debug.print("stash selected={s}, diff installed={any}\n", .{self.git.selected_commit,self.git.diff != null});
        try t.expect(self.git.diff != null);
        try t.expect(self.git.diff.?.hunks.len > 0);
    }
};
fn prepare(temp: *t.TmpDir) ![:0]u8 {
    const root = try temp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    errdefer t.allocator.free(root);
    try command(root, &.{"init","-b","main"});
    try command(root, &.{"config","user.name","Audit"});
    try command(root, &.{"config","user.email","audit@example.invalid"});
    try temp.dir.writeFile(t.io,.{.sub_path="source.zig",.data="const number = 1;\n"});
    try command(root, &.{"add","source.zig"});
    try command(root, &.{"commit","-m","baseline"});
    return root;
}
test "audit external commits refresh visible history" {
    var temp = t.tmpDir(.{});
    defer temp.cleanup();
    const root = try prepare(&temp);
    defer t.allocator.free(root);
    var app = try ui.App.init(.{.allocator=t.allocator});
    defer app.deinit();
    const h = try app.openWindow(zircon.Shell,.{.visible=false,.width=1000,.height=700},try zircon.Shell.init(t.allocator,t.io,root,null));
    const owner = try app.windowEntity(zircon.Shell,h);
    try app.update(owner,zircon.Shell.bootstrap,.{h});
    try settle(&app);
    try command(root,&.{"commit","--allow-empty","-m","external change"});
    const oid_raw = try run(root,&.{"rev-parse","HEAD"});
    defer t.allocator.free(oid_raw);
    const oid = std.mem.trim(u8,oid_raw,"\r\n");
    try app.update(owner,Ops.refresh,.{});
    try settle(&app);
    try app.read(owner,Ops.matchesHead,.{oid});
}
test "audit selecting a stash installs its patch" {
    var temp = t.tmpDir(.{});
    defer temp.cleanup();
    const root = try prepare(&temp);
    defer t.allocator.free(root);
    try temp.dir.writeFile(t.io,.{.sub_path="source.zig",.data="const number = 2;\n"});
    try command(root,&.{"stash","push","-m","stash fixture"});
    var app = try ui.App.init(.{.allocator=t.allocator});
    defer app.deinit();
    const h = try app.openWindow(zircon.Shell,.{.visible=false,.width=1000,.height=700},try zircon.Shell.init(t.allocator,t.io,root,null));
    const owner = try app.windowEntity(zircon.Shell,h);
    try app.update(owner,zircon.Shell.bootstrap,.{h});
    try settle(&app);
    try app.update(owner,Ops.command,.{.git_stash_show});
    try settle(&app);
    try app.read(owner,Ops.stashInstalled,.{});
}

test "audit mixed binary and text comparison exposes both files" {
    var temp = t.tmpDir(.{});
    defer temp.cleanup();
    const root = try prepare(&temp);
    defer t.allocator.free(root);
    try temp.dir.writeFile(t.io,.{.sub_path="binary.dat",.data="before\x00bytes"});
    try command(root,&.{"add","binary.dat"});
    try command(root,&.{"commit","-m","binary baseline"});
    try temp.dir.writeFile(t.io,.{.sub_path="binary.dat",.data="after\x00bytes"});
    try temp.dir.writeFile(t.io,.{.sub_path="source.zig",.data="const number = 2;\n"});
    var app = try ui.App.init(.{.allocator=t.allocator});
    defer app.deinit();
    const h = try app.openWindow(zircon.Shell,.{.visible=false,.width=1000,.height=700},try zircon.Shell.init(t.allocator,t.io,root,null));
    const owner = try app.windowEntity(zircon.Shell,h);
    try app.update(owner,zircon.Shell.bootstrap,.{h});
    try settle(&app);
    try app.update(owner,Ops.command,.{.git_diff_all});
    try settle(&app);
    try app.read(owner,Ops.mixedBinaryVisible,.{});
}

test "audit space-name changed file becomes an editable source" {
    var temp = t.tmpDir(.{});
    defer temp.cleanup();
    const root = try prepare(&temp);
    defer t.allocator.free(root);
    try temp.dir.writeFile(t.io,.{.sub_path="space name.zig",.data="const number = 1;\n"});
    try command(root,&.{"add","space name.zig"});
    try command(root,&.{"commit","-m","space baseline"});
    try temp.dir.writeFile(t.io,.{.sub_path="space name.zig",.data="const number = 2;\n"});
    var app = try ui.App.init(.{.allocator=t.allocator});
    defer app.deinit();
    const h = try app.openWindow(zircon.Shell,.{.visible=false,.width=1000,.height=700},try zircon.Shell.init(t.allocator,t.io,root,null));
    const owner = try app.windowEntity(zircon.Shell,h);
    try app.update(owner,zircon.Shell.bootstrap,.{h});
    try settle(&app);
    try app.update(owner,Ops.command,.{.git_diff_all});
    try settle(&app);
    try app.read(owner,Ops.spacedSourceEditable,.{});
}
