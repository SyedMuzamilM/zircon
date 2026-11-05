//! Optional acceptance check against the installed Apple clangd. It is kept
//! separate from portable checks so those do not require a particular server.
const std = @import("std");
const ui = @import("zircon_ui");
const zircon = @import("zircon");
const t = std.testing;
const Ops = struct {
    fn configure(self: *zircon.Shell, cx: *ui.Context(zircon.Shell), home: []const u8) !void {
        try self.loadExtensions(cx, home);
    }
    fn command(self: *zircon.Shell, cx: *ui.Context(zircon.Shell), which: zircon.Command) !void {
        var event: ui.Event(ui.Click) = .{ .data = .{} };
        try self.onCommand(&event, cx, which);
        if (self.status_is_error) {
            std.debug.print("clangd journey: {s}\n", .{self.status});
            return error.CommandFailed;
        }
    }
    fn opened(self: *const zircon.Shell) bool {
        return self.language.documents.items.len == 1 and self.language.documents.items[0].version != null;
    }
    fn completion(self: *const zircon.Shell) bool {
        return self.language.completions != null;
    }
    fn cursor(self: *zircon.Shell, cx: *ui.Context(zircon.Shell)) !void {
        const tab = &self.tabs.items[self.active];
        var snapshot = try self.workspace.snapshot(tab.document);
        defer snapshot.deinit();
        const at = snapshot.byteLen();
        try tab.editor.setSelection(snapshot, .{ .start = at, .end = at });
        cx.notify();
    }
    fn accept(self: *zircon.Shell, cx: *ui.Context(zircon.Shell)) !void {
        const message = self.language.completions orelse return error.NoCompletions;
        for (message.data.completion.items, 0..) |item, index| {
            const inserted = if (item.text_edit) |edit| edit.new_text else item.insert_text;
            if (!std.mem.eql(u8, inserted, "variable")) continue;
            var event: ui.Event(ui.Click) = .{ .data = .{} };
            try self.onCompletion(&event, cx, @intCast(index));
            if (self.status_is_error) return error.CompletionRejected;
            return;
        }
        return error.ExpectedCompletionMissing;
    }
    fn source(self: *const zircon.Shell, a: std.mem.Allocator, output: *[]u8) !void {
        var snapshot = try self.workspace.snapshot(self.tabs.items[self.active].document);
        defer snapshot.deinit();
        output.* = try snapshot.copy(a, .{ .start = 0, .end = snapshot.byteLen() });
    }
};
test "real clangd completion replaces a prefix in the original editor document" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    try tmp.dir.createDir(t.io, "source", .default_dir);
    const source = "int main(void) { int variable = 1; varia";
    try tmp.dir.writeFile(t.io, .{ .sub_path = "main.c", .data = source });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "source/extension.json", .data =
        \\{"schema_version":1,"id":"org.zircon.clangd-fixture","name":"Clangd acceptance","version":"1.0.0","contributes":{"languages":[{"id":"c","name":"C","extensions":["c"],"keywords":["int","return"],"line_comment":"//"}],"language_servers":[{"id":"clangd","languages":["c"],"command":"/usr/bin/clangd","args":["--background-index=false","--log=error"]}]}}
    });
    const home = try std.fs.path.join(t.allocator, &.{ root, "extensions" });
    defer t.allocator.free(home);
    const install = try std.fs.path.join(t.allocator, &.{ root, "source" });
    defer t.allocator.free(install);
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    var shell = try zircon.Shell.init(t.allocator, t.io, root, "main.c");
    const window = app.openWindow(zircon.Shell, .{ .visible = false, .width = 1100, .height = 700 }, shell) catch |err| {
        shell.deinit(t.allocator);
        return err;
    };
    const owner = try app.windowEntity(zircon.Shell, window);
    try app.update(owner, Ops.configure, .{home});
    try app.update(owner, zircon.Shell.bootstrap, .{window});
    try app.update(owner, Ops.command, .{zircon.Command.install_extension});
    _ = try app.step(0);
    try app.dispatch(window, .{ .text = install });
    try app.dispatch(window, .{ .key_down = .{ .key = .enter } });
    const deadline = std.Io.Clock.awake.now(t.io).addDuration(.fromSeconds(10));
    while (!try app.read(owner, Ops.opened, .{})) {
        _ = try app.step(0);
        if (std.Io.Clock.awake.now(t.io).compare(.gte, deadline)) return error.ServerTimeout;
        std.Io.sleep(t.io, .fromMilliseconds(2), .awake) catch {};
    }
    try app.update(owner, Ops.command, .{zircon.Command.back_to_editor});
    try app.update(owner, Ops.cursor, .{});
    _ = try app.step(0);
    try app.update(owner, Ops.command, .{zircon.Command.complete});
    while (!try app.read(owner, Ops.completion, .{})) {
        _ = try app.step(0);
        if (std.Io.Clock.awake.now(t.io).compare(.gte, deadline)) return error.CompletionTimeout;
        std.Io.sleep(t.io, .fromMilliseconds(2), .awake) catch {};
    }
    try (try app.window(window)).snapshot("/tmp/zircon-clangd.png");
    try app.update(owner, Ops.accept, .{});
    var actual: []u8 = undefined;
    try app.read(owner, Ops.source, .{ t.allocator, &actual });
    defer t.allocator.free(actual);
    try t.expectEqualStrings("int main(void) { int variable = 1; variable", actual);
}
