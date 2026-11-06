const std = @import("std");
const ui = @import("zircon_ui");
const zircon = @import("zircon");
const t = std.testing;

fn open(app: *ui.App) !ui.WindowHandle {
    var shell = try zircon.Shell.init(t.allocator, t.io, ".", null);
    const handle = app.openWindow(zircon.Shell, .{ .visible = false, .width = 1000, .height = 700 }, shell) catch |err| {
        shell.deinit(t.allocator);
        return err;
    };
    const owner = try app.windowEntity(zircon.Shell, handle);
    try app.update(owner, zircon.Shell.bootstrap, .{handle});
    return handle;
}

test "palette filtering is deterministic ASCII case-insensitive substring matching" {
    try t.expect(zircon.view.matches("  SPLIT ", "Split editor"));
    try t.expect(zircon.view.matches("file", "Open file by path"));
    try t.expect(zircon.view.matches("", "Any command"));
    try t.expect(!zircon.view.matches("split", "Save file as…"));
    try t.expect(!zircon.view.matches("long query", "tiny"));
}

test "workspace chrome leaves the canvas room and focuses the editor initially" {
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const handle = try open(&app);
    _ = try app.step(0);
    const window = try app.window(handle);
    const frame = &window.frames.committed;
    try t.expectEqualStrings("primary-editor", frame.nodes.items[window.focus.?].key.?.string);
    var canvas = false;
    var open_button = false;
    for (frame.nodes.items, 0..) |node, i| {
        if (node.key != null and node.key.? == .string and std.mem.eql(u8, node.key.?.string, "primary-editor")) {
            canvas = true;
            try t.expect(frame.bounds[i].width > 600);
            try t.expect(frame.bounds[i].height > 500);
        }
        if (node.kind == .button and std.mem.eql(u8, node.kind.button.label, "Open")) open_button = true;
    }
    try t.expect(canvas and open_button);
}

test "chrome controls fit inside their bars without clipped hover targets" {
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const handle = try open(&app);
    _ = try app.step(0);
    const frame = &(try app.window(handle)).frames.committed;
    for (frame.nodes.items, 0..) |node, i| if (node.kind == .button and inScope(frame, @intCast(i), "status")) {
        const bounds = frame.bounds[i];
        try t.expect(bounds.y >= 676 and bounds.y + bounds.height <= 700);
    };
}
test "utility tabs keep their close and split controls visible in narrow windows" {
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const handle = try open(&app);
    const owner = try app.windowEntity(zircon.Shell, handle);
    try app.update(owner, Operations.command, .{.git_diff_all});
    try app.dispatch(handle, .{ .resize = .{ .width = 600, .height = 500 } });
    _ = try app.step(0);
    const frame = &(try app.window(handle)).frames.committed;
    for (frame.nodes.items, 0..) |node, i| if (node.kind == .button and inScope(frame, @intCast(i), "tabs")) {
        const bounds = frame.bounds[i];
        try t.expect(bounds.x + bounds.width <= 600);
    };
}
test "long status messages leave settings and panel controls inside the window" {
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const handle = try open(&app);
    const owner = try app.windowEntity(zircon.Shell, handle);
    try app.update(owner, Operations.longStatus, .{});
    try app.dispatch(handle, .{ .resize = .{ .width = 400, .height = 400 } });
    _ = try app.step(0);
    const frame = &(try app.window(handle)).frames.committed;
    for (frame.nodes.items, 0..) |node, i| if (node.kind == .button and inScope(frame, @intCast(i), "status")) try t.expect(frame.bounds[i].x + frame.bounds[i].width <= 400);
}

test "palette uses an editable focused query and Escape restores canvas focus" {
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const handle = try open(&app);
    _ = try app.step(0);
    try app.dispatch(handle, .{ .key_down = .{ .key = .p, .modifiers = .{ .command = true, .shift = true } } });
    _ = try app.step(1);
    const window = try app.window(handle);
    try t.expectEqualStrings("query", window.frames.committed.nodes.items[window.focus.?].key.?.string);
    try t.expect(window.frames.committed.text_input != null);
    try app.dispatch(handle, .{ .text = "split" });
    _ = try app.step(2);
    var split_result = false;
    var new_file_result = false;
    for (window.frames.committed.nodes.items, 0..) |node, index| if (node.kind == .button and inScope(&window.frames.committed, @intCast(index), "dialog")) {
        if (std.mem.startsWith(u8, node.kind.button.label, "Split editor")) split_result = true;
        if (std.mem.startsWith(u8, node.kind.button.label, "New file")) new_file_result = true;
    };
    try t.expect(split_result and !new_file_result);
    try app.dispatch(handle, .{ .key_down = .{ .key = .escape } });
    _ = try app.step(3);
    try t.expectEqualStrings("primary-editor", window.frames.committed.nodes.items[window.focus.?].key.?.string);
}

test "compact workspace hides sidebar and still arranges an editable canvas" {
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const handle = try open(&app);
    try app.dispatch(handle, .{ .resize = .{ .width = 400, .height = 320 } });
    _ = try app.step(0);
    const frame = &(try app.window(handle)).frames.committed;
    for (frame.nodes.items, 0..) |node, i| {
        if (node.key) |key| if (key == .string) try t.expect(!std.mem.eql(u8, key.string, "sidebar"));
        if (node.key != null and node.key.? == .string and std.mem.eql(u8, node.key.?.string, "primary-editor")) try t.expect(frame.bounds[i].width >= 390 and frame.bounds[i].height > 150);
    }
}

const Operations = struct {
    fn longStatus(self: *zircon.Shell, cx: *ui.Context(zircon.Shell)) !void {
        try self.setStatus(try self.allocator.dupe(u8, "A long repository or language server message should never hide the Settings button or any panel selector."));
        cx.notify();
    }
    fn command(self: *zircon.Shell, cx: *ui.Context(zircon.Shell), which: zircon.Command) !void {
        var click: ui.Event(ui.Click) = .{ .data = .{} };
        try self.onCommand(&click, cx, which);
    }
    fn manyTabs(self: *zircon.Shell, cx: *ui.Context(zircon.Shell)) !void {
        for (0..14) |_| try self.newFile();
        cx.notify();
    }
    fn active(self: *const zircon.Shell) usize {
        return self.active;
    }
};

test "split ratio controls actual arranged canvas widths" {
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const handle = try open(&app);
    const owner = try app.windowEntity(zircon.Shell, handle);
    try app.update(owner, Operations.command, .{.split});
    _ = try app.step(0);
    const frame = &(try app.window(handle)).frames.committed;
    var primary: ?ui.Rect = null;
    var secondary: ?ui.Rect = null;
    for (frame.nodes.items, 0..) |node, i| if (node.key) |key| if (key == .string) {
        if (std.mem.eql(u8, key.string, "primary-editor")) primary = frame.bounds[i];
        if (std.mem.eql(u8, key.string, "secondary-editor")) secondary = frame.bounds[i];
    };
    try t.expect(primary != null and secondary != null);
    try t.expectApproxEqAbs(primary.?.width, secondary.?.width, 0.01);
    try t.expect(primary.?.width > 300);
}

test "many tabs keep the active document visible and navigation reaches hidden tabs" {
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const handle = try open(&app);
    const owner = try app.windowEntity(zircon.Shell, handle);
    try app.update(owner, Operations.manyTabs, .{});
    _ = try app.step(0);
    const window = try app.window(handle);
    var previous: ?ui.Rect = null;
    var active_visible = false;
    for (window.frames.committed.nodes.items, 0..) |node, i| if (node.kind == .button) {
        if (std.mem.eql(u8, node.kind.button.label, "previous-tab")) previous = window.frames.committed.bounds[i];
        if (std.mem.eql(u8, node.kind.button.label, "Untitled 15")) active_visible = true;
    };
    try t.expect(active_visible and previous != null);
    const position: ui.Point = .{ .x = previous.?.x + 5, .y = previous.?.y + 5 };
    try app.dispatch(handle, .{ .pointer_down = .{ .position = position } });
    try app.dispatch(handle, .{ .pointer_up = .{ .position = position } });
    _ = try app.step(1);
    try t.expect((try app.read(owner, Operations.active, .{})) < 14);
}

fn inScope(frame: anytype, start: u32, key: []const u8) bool {
    var current: ?u32 = start;
    while (current) |index| : (current = frame.nodes.items[index].parent) {
        if (frame.nodes.items[index].key) |value| if (value == .string and std.mem.eql(u8, value.string, key)) return true;
    }
    return false;
}
