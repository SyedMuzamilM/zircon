//! Optional acceptance check against the installed Apple clangd. It is kept
//! separate from portable checks so those do not require a particular server.
const std = @import("std");
const zircon = @import("zircon");
const ui = @import("zircon_ui");
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

test "real ZLS narrows imported functions while typing and applies the completion edit" {
    const executable = t.environ.getAlloc(t.allocator, "ZIRCON_TEST_ZLS") catch return error.SkipZigTest;
    defer t.allocator.free(executable);
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const source = "const lib = @import(\"lib.zig\");\npub fn main() void { lib.an";
    try tmp.dir.writeFile(t.io, .{ .sub_path = "main.zig", .data = source });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "lib.zig", .data = "pub fn answer() u32 { return 42; }\npub fn another() void {}\n" });
    try tmp.dir.createDirPath(t.io, "extensions/org.zircon.zls");
    const manifest = try std.json.Stringify.valueAlloc(t.allocator, .{ .schema_version = 1, .id = "org.zircon.zls", .name = "ZLS acceptance", .version = "1.0.0", .contributes = .{ .language_servers = .{.{ .id = "zls", .languages = .{"zig"}, .command = executable }} } }, .{});
    defer t.allocator.free(manifest);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "extensions/org.zircon.zls/extension.json", .data = manifest });
    const home = try std.fs.path.join(t.allocator, &.{ root, "extensions" });
    defer t.allocator.free(home);
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const h = try app.openWindow(zircon.Shell, .{ .title = "Zircon ZLS acceptance", .visible = false, .width = 1100, .height = 700 }, try zircon.Shell.init(t.allocator, t.io, root, "main.zig"));
    const owner = try app.windowEntity(zircon.Shell, h);
    try app.update(owner, Ops.configure, .{home});
    try app.update(owner, zircon.Shell.bootstrap, .{h});
    const deadline = std.Io.Clock.awake.now(t.io).addDuration(.fromSeconds(10));
    while (!try app.read(owner, Ops.opened, .{})) {
        _ = try app.step(0);
        if (std.Io.Clock.awake.now(t.io).compare(.gte, deadline)) return error.ZlsServerTimeout;
        try std.Io.sleep(t.io, .fromMilliseconds(1), .awake);
    }
    try app.update(owner, Ops.cursor, .{});
    _ = try app.step(0);
    const native = ui.testing.native;
    const objc = native.objc;
    const nsapp = objc.send(objc.Id, objc.class("NSApplication"), "sharedApplication", .{});
    const windows = objc.send(objc.Id, nsapp, "windows", .{});
    const window = for (0..objc.send(usize, windows, "count", .{})) |index| {
        const candidate = objc.send(objc.Id, windows, "objectAtIndex:", .{index});
        if (std.mem.eql(u8, "Zircon ZLS acceptance", objc.fromString(objc.send(objc.Id, candidate, "title", .{})))) break candidate;
    } else return error.ZlsWindowMissing;
    const native_event = objc.send(objc.Id, objc.class("NSEvent"), "keyEventWithType:location:modifierFlags:timestamp:windowNumber:context:characters:charactersIgnoringModifiers:isARepeat:keyCode:", .{ @as(usize, 10), objc.CGPoint{}, @as(usize, 0), native.now(), objc.send(isize, window, "windowNumber", .{}), @as(objc.Id, null), objc.string("s"), objc.string("s"), false, @as(u16, 1) });
    objc.send(void, window, "sendEvent:", .{native_event});
    try native.pump(0);
    while (!try app.read(owner, Ops.completion, .{})) {
        _ = try app.step(0);
        if (std.Io.Clock.awake.now(t.io).compare(.gte, deadline)) return error.ZlsCompletionTimeout;
        try std.Io.sleep(t.io, .fromMilliseconds(1), .awake);
    }
    const Zls = struct {
        fn accept(self: *zircon.Shell, cx: *ui.Context(zircon.Shell)) !void {
            const items = self.language.completions.?.data.completion.items;
            try t.expectEqual(@as(usize, 1), items.len);
            try t.expectEqualStrings("answer", items[0].label);
            var event: ui.Event(ui.Click) = .{ .data = .{} };
            try self.onCompletion(&event, cx, 0);
            try t.expect(!self.status_is_error);
        }
    };
    try app.update(owner, Zls.accept, .{});
    var actual: []u8 = undefined;
    try app.read(owner, Ops.source, .{ t.allocator, &actual });
    defer t.allocator.free(actual);
    try t.expectEqualStrings("const lib = @import(\"lib.zig\");\npub fn main() void { lib.answer", actual);
}
