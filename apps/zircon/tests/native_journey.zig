//! Drives actual AppKit input and verifies rendered editor state and disk bytes.
const std = @import("std");
const ui = @import("zircon_ui");
const zircon = @import("zircon");
const t = std.testing;
const native = ui.testing.native;
const objc = native.objc;
fn bytes(self: *const zircon.Shell, a: std.mem.Allocator, out: *[]u8) !void {
    const tab = self.tabs.items[self.active];
    var snapshot = try self.workspace.snapshot(tab.document);
    defer snapshot.deinit();
    out.* = try snapshot.copy(a, .{ .start = 0, .end = snapshot.byteLen() });
}
fn sendKey(app: *ui.App, h: ui.WindowHandle, key: ui.Key, mods: ui.Modifiers) !void {
    try app.dispatch(h, .{ .key_down = .{ .key = key, .modifiers = mods } });
}
fn nativeKey(window: objc.Id, code: u16, characters: []const u8, flags: usize) !void {
    const number = objc.send(isize, window, "windowNumber", .{});
    const app = objc.send(objc.Id, objc.class("NSApplication"), "sharedApplication", .{});
    const event = objc.send(objc.Id, objc.class("NSEvent"), "keyEventWithType:location:modifierFlags:timestamp:windowNumber:context:characters:charactersIgnoringModifiers:isARepeat:keyCode:", .{ @as(usize, 10), objc.CGPoint{}, flags, native.now(), number, @as(objc.Id, null), objc.string(characters), objc.string(characters), false, code });
    objc.send(void, app, "postEvent:atStart:", .{ event, false });
    for (0..32) |_| try native.pump(0);
}
fn command(app: *ui.App, owner: ui.Entity(zircon.Shell), which: zircon.Command) !void {
    const Call = struct {
        fn invoke(self: *zircon.Shell, cx: *ui.Context(zircon.Shell), action: zircon.Command) !void {
            var event: ui.Event(ui.Click) = .{ .data = .{} };
            try self.onCommand(&event, cx, action);
        }
    };
    try app.update(owner, Call.invoke, .{which});
}
test "native editor edits finds replaces splits saves and protects dirty close" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const source = "const std = @import(\"std\");\n\n// A document rendered by Zircon UI.\npub fn main() void {\n    std.debug.print(\"Hello, Zircon!\\n\", .{});\n}\n";
    try tmp.dir.writeFile(t.io, .{ .sub_path = "hello.zig", .data = source });
    const root_path = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root_path);
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    var shell = try zircon.Shell.init(t.allocator, t.io, root_path, "hello.zig");
    const h = app.openWindow(zircon.Shell, .{ .title = "Zircon · Native verification", .width = 1160, .height = 760 }, shell) catch |err| {
        shell.deinit(t.allocator);
        return err;
    };
    const owner = try app.windowEntity(zircon.Shell, h);
    try app.update(owner, zircon.Shell.bootstrap, .{h});
    _ = try app.step(0);
    const pool = objc.Pool.init();
    defer pool.deinit();
    const nsapp = objc.send(objc.Id, objc.class("NSApplication"), "sharedApplication", .{});
    const list = objc.send(objc.Id, nsapp, "windows", .{});
    const window = objc.send(objc.Id, list, "objectAtIndex:", .{@as(usize, 0)});
    const view = objc.send(objc.Id, window, "contentView", .{});
    try (try app.window(h)).snapshot("/tmp/zircon-editor-initial.png");
    try nativeKey(window, 0, "a", 1 << 20);
    _ = try app.step(1);
    objc.send(void, view, "insertText:replacementRange:", .{ objc.string("const answer = 42;\n"), Range{ .location = std.math.maxInt(usize), .length = 0 } });
    _ = try app.step(2);
    var actual: []u8 = undefined;
    try app.read(owner, bytes, .{ t.allocator, &actual });
    try t.expectEqualStrings("const answer = 42;\n", actual);
    t.allocator.free(actual);
    try nativeKey(window, 6, "z", 1 << 20);
    _ = try app.step(3);
    try app.read(owner, bytes, .{ t.allocator, &actual });
    try t.expectEqualStrings(source, actual);
    t.allocator.free(actual);
    try nativeKey(window, 6, "z", (1 << 20) | (1 << 17));
    _ = try app.step(4);
    try command(&app, owner, .split);
    _ = try app.step(5);
    try command(&app, owner, .replace);
    _ = try app.step(6);
    try app.dispatch(h, .{ .text = "42" });
    _ = try app.step(7);
    try sendKey(&app, h, .tab, .{});
    _ = try app.step(8);
    try app.dispatch(h, .{ .text = "84" });
    _ = try app.step(9);
    try command(&app, owner, .replace_all);
    _ = try app.step(10);
    try sendKey(&app, h, .escape, .{});
    _ = try app.step(11);
    try command(&app, owner, .save);
    _ = try app.step(12);
    const disk = try tmp.dir.readFileAlloc(t.io, "hello.zig", t.allocator, .limited(1024));
    defer t.allocator.free(disk);
    try t.expectEqualStrings("const answer = 84;\n", disk);
    try (try app.window(h)).snapshot("/tmp/zircon-editor-split.png");
    try command(&app, owner, .palette);
    _ = try app.step(13);
    try app.dispatch(h, .{ .text = "Save" });
    _ = try app.step(14);
    try (try app.window(h)).snapshot("/tmp/zircon-editor-palette.png");
    try sendKey(&app, h, .escape, .{});
    _ = try app.step(15);
    try app.dispatch(h, .{ .text = "// unsaved\n" });
    _ = try app.step(16);
    objc.send(void, window, "performClose:", .{@as(objc.Id, null)});
    for (0..16) |_| try native.pump(0);
    _ = try app.step(17);
    _ = try app.window(h);
    try (try app.window(h)).snapshot("/tmp/zircon-editor-dirty-close.png");
    try command(&app, owner, .dismiss);
    _ = try app.step(18);
    _ = try app.window(h);
    try command(&app, owner, .save);
    _ = try app.step(19);
    objc.send(void, window, "performClose:", .{@as(objc.Id, null)});
    for (0..16) |_| try native.pump(0);
    _ = try app.step(20);
    try t.expectError(error.WindowNotFound, app.window(h));
}
const Range = extern struct { location: usize, length: usize };
