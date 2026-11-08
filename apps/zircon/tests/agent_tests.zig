const std = @import("std");
const zircon = @import("zircon");
const ui = @import("zircon_ui");
const t = std.testing;
const Ops = struct {
    fn command(self: *zircon.Shell, cx: *ui.Context(zircon.Shell), which: zircon.Command) !void {
        var e: ui.Event(ui.Click) = .{ .data = .{} };
        try self.onCommand(&e, cx, which);
    }
    fn editorOnly(self: *const zircon.Shell) bool {
        return !self.agent_mode and self.agents.config == null and self.agents.sessions.items.len == 0 and self.layout_setting == .classic and !self.status_is_error;
    }
};

test "retired agent commands and shortcuts leave the editor active" {
    for (zircon.commands) |entry| {
        try t.expect(!std.mem.startsWith(u8, entry.label, "Agent:"));
        try t.expect(entry.command != .layout_agentic);
    }
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "settings.json", .data = "{\"panel_layout\":\"agentic\",\"key_bindings\":{\"cmd-shift-j\":\"agent_mode\"}}" });
    const settings_path = try std.fs.path.join(t.allocator, &.{ root, "settings.json" });
    defer t.allocator.free(settings_path);
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const h = try app.openWindow(zircon.Shell, .{ .visible = false, .width = 1000, .height = 700 }, try zircon.Shell.init(t.allocator, t.io, root, null));
    const owner = try app.windowEntity(zircon.Shell, h);
    try app.update(owner, zircon.Shell.loadSettings, .{@as(?[]const u8, settings_path)});
    try app.update(owner, zircon.Shell.bootstrap, .{h});
    _ = try app.step(0);
    for ([_]zircon.Command{ .agent_mode, .agent_new, .agent_connect, .agent_send, .agent_cancel, .agent_config, .agent_reload, .agent_context, .agent_toggle_editor, .agent_transcript, .layout_agentic }) |action| try app.update(owner, Ops.command, .{action});
    try app.dispatch(h, .{ .key_down = .{ .key = .j, .modifiers = .{ .command = true, .shift = true } } });
    try app.dispatch(h, .{ .key_down = .{ .key = .n, .modifiers = .{ .command = true, .alt = true } } });
    try app.dispatch(h, .{ .key_down = .{ .key = .enter, .modifiers = .{ .command = true } } });
    _ = try app.step(0);
    try t.expect(try app.read(owner, Ops.editorOnly, .{}));
    var editor_visible = false;
    for ((try app.window(h)).frames.committed.nodes.items) |node| {
        if (node.key) |key| if (key == .string and std.mem.eql(u8, key.string, "primary-editor")) {
            editor_visible = true;
        };
        if (node.kind == .button) try t.expect(!std.mem.eql(u8, node.kind.button.label, "Agent workspace"));
    }
    try t.expect(editor_visible);
}
