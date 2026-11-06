const std = @import("std");
const ui = @import("zircon_ui");
const zircon = @import("zircon");
const t = std.testing;
const Ops = struct {
    fn command(self: *zircon.Shell, cx: *ui.Context(zircon.Shell), which: zircon.Command) !void {
        var e: ui.Event(ui.Click) = .{ .data = .{} };
        try self.onCommand(&e, cx, which);
    }
    fn ready(self: *const zircon.Shell) bool {
        const s = self.agents.current() orelse return false;
        return s.conversation.state == .ready;
    }
    fn permission(self: *const zircon.Shell) bool {
        const s = self.agents.current() orelse return false;
        return s.conversation.state == .permission;
    }
    fn failed(self: *const zircon.Shell) bool {
        const s = self.agents.current() orelse return false;
        return s.conversation.state == .failed;
    }
    fn content(self: *const zircon.Shell) bool {
        const s = self.agents.current() orelse return false;
        for (s.conversation.entries.items) |entry| if (std.mem.indexOf(u8, entry.text.items, "Hello 日🙂") != null) return true;
        return false;
    }
    fn multiline(self: *const zircon.Shell) bool {
        const s = self.agents.current() orelse return false;
        return std.mem.eql(u8, s.conversation.entries.items[0].text.items, "Change example.txt\nKeep it small.");
    }
    fn settings(self: *const zircon.Shell) ?ui.Entity(zircon.Settings) {
        return self.settings;
    }
    fn history(self: *const zircon.Shell) bool {
        const s = self.agents.current() orelse return false;
        return s.conversation.session.len > 0 and s.conversation.entries.items.len > 0;
    }
};
fn wait(app: *ui.App, owner: ui.Entity(zircon.Shell), comptime predicate: anytype) !void {
    const deadline = std.Io.Clock.awake.now(t.io).addDuration(.fromSeconds(8));
    while (!try app.read(owner, predicate, .{})) {
        _ = try app.step(0);
        if (try app.read(owner, Ops.failed, .{})) return error.AgentFailed;
        if (std.Io.Clock.awake.now(t.io).compare(.gte, deadline)) return error.AgentTimeout;
        try std.Io.sleep(t.io, .fromMilliseconds(1), .awake);
    }
    _ = try app.step(0);
}
fn click(app: *ui.App, h: ui.WindowHandle, label: []const u8) !void {
    const frame = &(try app.window(h)).frames.committed;
    for (frame.nodes.items, 0..) |node, index| if (node.kind == .button and std.mem.eql(u8, node.kind.button.label, label)) {
        const r = frame.bounds[index];
        const point: ui.Point = .{ .x = r.x + r.width / 2, .y = r.y + r.height / 2 };
        try app.dispatch(h, .{ .pointer_down = .{ .position = point } });
        try app.dispatch(h, .{ .pointer_up = .{ .position = point } });
        _ = try app.step(0);
        return;
    };
    return error.MissingControl;
}
test "native agent workspace sends multiline text gates edits and restores project conversation history" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const home = try std.fs.path.join(t.allocator, &.{ root, "preferences" });
    defer t.allocator.free(home);
    const script = try std.fs.path.join(t.allocator, &.{ root, "agent.py" });
    defer t.allocator.free(script);
    try tmp.dir.createDir(t.io, "preferences", .default_dir);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "agent.py", .data = @embedFile("agent_fixture") });
    const config = try std.json.Stringify.valueAlloc(t.allocator, .{ .providers = .{.{ .name = "Test agent", .protocol = "acp", .command = "python3", .args = .{ "-u", script, "acp" } }} }, .{});
    defer t.allocator.free(config);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "preferences/agents.json", .data = config });
    {
        var app = try ui.App.init(.{ .allocator = t.allocator });
        defer app.deinit();
        const h = try app.openWindow(zircon.Shell, .{ .visible = false, .width = 1240, .height = 820 }, try zircon.Shell.init(t.allocator, t.io, root, null));
        const owner = try app.windowEntity(zircon.Shell, h);
        try app.update(owner, zircon.Shell.configureAgents, .{ home, null });
        try app.update(owner, zircon.Shell.bootstrap, .{h});
        try app.update(owner, Ops.command, .{.agent_mode});
        try app.update(owner, Ops.command, .{.agent_connect});
        try wait(&app, owner, Ops.ready);
        const frame = &(try app.window(h)).frames.committed;
        for (frame.nodes.items, 0..) |node, index| if (node.key) |key| if (key == .string and std.mem.eql(u8, key.string, "agent-composer")) {
            const r = frame.bounds[index];
            const point: ui.Point = .{ .x = r.x + 30, .y = r.y + 20 };
            try app.dispatch(h, .{ .pointer_down = .{ .position = point } });
            try app.dispatch(h, .{ .pointer_up = .{ .position = point } });
            break;
        };
        try click(&app, h, "fixture-model");
        try app.dispatch(h, .{ .text = "Other" });
        _ = try app.step(0);
        if (comptime ui.testing.native != void) try (try app.window(h)).snapshot("/tmp/zircon-agent-model-picker.png");
        try app.dispatch(h, .{ .key_down = .{ .key = .enter } });
        const Selected = struct {
            fn call(self: *const zircon.Shell) bool {
                return std.mem.eql(u8, self.agents.current().?.conversation.model, "fixture-other");
            }
        };
        try wait(&app, owner, Selected.call);
        try app.dispatch(h, .{ .text = "Change example.txt" });
        try app.dispatch(h, .{ .key_down = .{ .key = .enter, .modifiers = .{ .shift = true } } });
        try app.dispatch(h, .{ .text = "Keep it small." });
        try app.dispatch(h, .{ .key_down = .{ .key = .enter } });
        try wait(&app, owner, Ops.permission);
        try t.expect(try app.read(owner, Ops.content, .{}));
        try t.expect(try app.read(owner, Ops.multiline, .{}));
        try t.expectError(error.FileNotFound, tmp.dir.statFile(t.io, "example.txt", .{}));
        if (comptime ui.testing.native != void) try (try app.window(h)).snapshot("/tmp/zircon-agent-permission.png");
        try click(&app, h, "Allow once");
        try wait(&app, owner, Ops.ready);
        const bytes = try tmp.dir.readFileAlloc(t.io, "example.txt", t.allocator, .limited(100));
        defer t.allocator.free(bytes);
        try t.expectEqualStrings("approved edit\n", bytes);
        if (comptime ui.testing.native != void) try (try app.window(h)).snapshot("/tmp/zircon-agent-complete.png");
        const Light = struct {
            fn call(self: *zircon.Shell, cx: *ui.Context(zircon.Shell)) !void {
                try cx.update(self.settings.?, zircon.Settings.apply, .{zircon.SettingsPatch{ .theme = "zircon.light" }});
            }
        };
        try app.update(owner, Light.call, .{});
        _ = try app.step(0);
        if (comptime ui.testing.native != void) try (try app.window(h)).snapshot("/tmp/zircon-agent-light.png");
        var narrow_shell = try zircon.Shell.init(t.allocator, t.io, root, null);
        narrow_shell.settings = try app.read(owner, Ops.settings, .{});
        const narrow = try app.openWindow(zircon.Shell, .{ .visible = false, .width = 700, .height = 650 }, narrow_shell);
        const narrow_owner = try app.windowEntity(zircon.Shell, narrow);
        try app.update(narrow_owner, zircon.Shell.configureAgents, .{ home, null });
        try app.update(narrow_owner, zircon.Shell.bootstrap, .{narrow});
        try app.update(narrow_owner, Ops.command, .{.agent_mode});
        _ = try app.step(0);
        if (comptime ui.testing.native != void) try (try app.window(narrow)).snapshot("/tmp/zircon-agent-narrow.png");
    }
    {
        var app = try ui.App.init(.{ .allocator = t.allocator });
        defer app.deinit();
        const h = try app.openWindow(zircon.Shell, .{ .visible = false }, try zircon.Shell.init(t.allocator, t.io, root, null));
        const owner = try app.windowEntity(zircon.Shell, h);
        try app.update(owner, zircon.Shell.configureAgents, .{ home, null });
        try app.update(owner, zircon.Shell.bootstrap, .{h});
        try app.update(owner, Ops.command, .{.agent_mode});
        try t.expect(try app.read(owner, Ops.history, .{}));
    }
}
