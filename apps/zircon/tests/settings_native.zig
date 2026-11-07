//! Reproduces the synchronous AppKit focus notification sent while an action
//! opens a child window. It must not reborrow the still-running shell action.
const std = @import("std");
const ui = @import("zircon_ui");
const zircon = @import("zircon");
const t = std.testing;
const native = ui.testing.native;
const objc = native.objc;
const Ops = struct {
    fn openWithFocusNotification(self: *zircon.Shell, cx: *ui.Context(zircon.Shell), view: objc.Id) !void {
        objc.send(void, view, "windowDidResignKey:", .{@as(objc.Id, null)});
        var event: ui.Event(ui.Click) = .{ .data = .{} };
        try self.onCommand(&event, cx, .settings);
    }
    fn child(self: *const zircon.Shell) ui.WindowHandle {
        return self.settings_window.?;
    }
};
test "settings opens across a synchronous native workspace blur notification" {
    const pool = objc.Pool.init();
    defer pool.deinit();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(path);
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    var shell = try zircon.Shell.init(t.allocator, t.io, path, null);
    const main = app.openWindow(zircon.Shell, .{ .title = "Settings regression", .chrome = .integrated, .width = 1100, .height = 720 }, shell) catch |err| {
        shell.deinit(t.allocator);
        return err;
    };
    const owner = try app.windowEntity(zircon.Shell, main);
    try app.update(owner, zircon.Shell.bootstrap, .{main});
    _ = try app.step(0);
    const nsapp = objc.send(objc.Id, objc.class("NSApplication"), "sharedApplication", .{});
    const windows = objc.send(objc.Id, nsapp, "windows", .{});
    var main_window: objc.Id = null;
    for (0..objc.send(usize, windows, "count", .{})) |index| {
        const window = objc.send(objc.Id, windows, "objectAtIndex:", .{index});
        if (std.mem.eql(u8, objc.fromString(objc.send(objc.Id, window, "title", .{})), "Settings regression")) {
            main_window = window;
            break;
        }
    }
    try t.expect(main_window != null);
    const view = objc.send(objc.Id, main_window, "contentView", .{});
    try app.update(owner, Ops.openWithFocusNotification, .{view});
    try native.pump(0);
    _ = try app.step(1);
    const child = try app.read(owner, Ops.child, .{});
    try t.expect((try app.window(child)).frame_count > 0);
    var child_window: objc.Id = null;
    const opened_windows = objc.send(objc.Id, nsapp, "windows", .{});
    for (0..objc.send(usize, opened_windows, "count", .{})) |index| {
        const window = objc.send(objc.Id, opened_windows, "objectAtIndex:", .{index});
        if (objc.send(objc.Id, window, "parentWindow", .{}) == main_window) child_window = window;
    }
    try t.expect(child_window != null);
    try t.expect(objc.send(bool, child_window, "isVisible", .{}));
    const parent_frame = objc.send(objc.CGRect, main_window, "frame", .{});
    const child_frame = objc.send(objc.CGRect, child_window, "frame", .{});
    try t.expectApproxEqAbs(parent_frame.origin.x + parent_frame.size.width / 2, child_frame.origin.x + child_frame.size.width / 2, 1);
    try t.expectApproxEqAbs(parent_frame.origin.y + parent_frame.size.height / 2, child_frame.origin.y + child_frame.size.height / 2, 1);
    try (try app.window(child)).snapshot("/tmp/zircon-settings-regression.png");
    try app.closeWindow(child);
    _ = try app.step(2);
    objc.send(void, view, "windowDidBecomeKey:", .{@as(objc.Id, null)});
    try native.pump(0);
    _ = try app.step(2.1);
    _ = try clickButton(&app, main, main_window, "Workspace menu", 2.2);
    const native_point = try clickButton(&app, main, main_window, "Settings", 3);
    const number = objc.send(isize, main_window, "windowNumber", .{});
    const clicked_child = try app.read(owner, Ops.child, .{});
    _ = try app.window(clicked_child);
    try t.expect(!std.meta.eql(clicked_child, child));
    const entered = objc.send(objc.Id, objc.class("NSEvent"), "enterExitEventWithType:location:modifierFlags:timestamp:windowNumber:context:eventNumber:trackingNumber:userData:", .{ @as(usize, 8), native_point, @as(usize, 0), native.now(), number, @as(objc.Id, null), @as(isize, 0), @as(isize, 0), @as(?*anyopaque, null) });
    objc.send(void, view, "mouseEntered:", .{entered});
    _ = try app.step(3.1);
    try t.expect((try app.window(main)).frames.committed.hovered_node != null);
    objc.send(void, view, "mouseExited:", .{@as(objc.Id, null)});
    try native.pump(0);
    _ = try app.step(3.2);
    try t.expect((try app.window(main)).frames.committed.hovered_node == null);
    try app.closeWindow(clicked_child);
    _ = try app.step(4);
    objc.send(void, view, "windowDidBecomeKey:", .{@as(objc.Id, null)});
    _ = objc.send(bool, main_window, "makeFirstResponder:", .{view});
    const key = objc.send(objc.Id, objc.class("NSEvent"), "keyEventWithType:location:modifierFlags:timestamp:windowNumber:context:characters:charactersIgnoringModifiers:isARepeat:keyCode:", .{ @as(usize, 10), objc.CGPoint{}, @as(usize, 1 << 20), native.now(), number, @as(objc.Id, null), objc.string(","), objc.string(","), false, @as(u16, 43) });
    objc.send(void, main_window, "sendEvent:", .{key});
    try native.pump(0);
    _ = try app.step(5);
    _ = try app.window(try app.read(owner, Ops.child, .{}));
}

fn clickButton(app: *ui.App, handle: ui.WindowHandle, window: objc.Id, label: []const u8, time: f64) !objc.CGPoint {
    const frame = &(try app.window(handle)).frames.committed;
    for (frame.nodes.items, 0..) |node, index| if (node.kind == .button and std.mem.eql(u8, node.kind.button.label, label)) {
        const bounds = frame.bounds[index];
        const view = objc.send(objc.Id, window, "contentView", .{});
        const point = objc.send(objc.CGPoint, view, "convertPoint:toView:", .{ objc.CGPoint{ .x = bounds.x + bounds.width / 2, .y = bounds.y + bounds.height / 2 }, @as(objc.Id, null) });
        const number = objc.send(isize, window, "windowNumber", .{});
        for ([_]usize{ 1, 2 }) |kind| {
            const mouse = objc.send(objc.Id, objc.class("NSEvent"), "mouseEventWithType:location:modifierFlags:timestamp:windowNumber:context:eventNumber:clickCount:pressure:", .{ kind, point, @as(usize, 0), native.now(), number, @as(objc.Id, null), @as(isize, 0), @as(isize, 1), @as(f32, 1) });
            objc.send(void, window, "sendEvent:", .{mouse});
        }
        try native.pump(0);
        _ = try app.step(time);
        return point;
    };
    std.debug.print("settings journey: missing button {s}\n", .{label});
    return error.TestButtonNotFound;
}
