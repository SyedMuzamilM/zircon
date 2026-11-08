//! Deterministic native review screens. Does not edit user preferences or files.
const std = @import("std");
const zircon = @import("zircon");
const ui = @import("zircon_ui");
const Shell = zircon.Shell;
const Ops = struct {
    fn command(self: *Shell, cx: *ui.Context(Shell), which: zircon.Command) !void {
        var event: ui.Event(ui.Click) = .{ .data = .{} };
        try self.onCommand(&event, cx, which);
    }
    fn select(self: *Shell, cx: *ui.Context(Shell)) !void {
        const tab = &self.tabs.items[self.active];
        var s = try self.workspace.snapshot(tab.document);
        defer s.deinit();
        try tab.editor.setSelection(s, .{ .start = try s.lineStart(3), .end = (try s.lineRange(10)).end });
        cx.notify();
    }
    fn open(self: *Shell, cx: *ui.Context(Shell), path: []const u8) !void {
        try self.openPath(path);
        cx.notify();
    }
    fn clear(self: *Shell, cx: *ui.Context(Shell)) void {
        self.tabs.items[self.active].editor.selections.single(.{ .anchor = 0, .head = 0 });
        cx.notify();
    }
    fn fieldColors(self: *const zircon.SettingsView) ?ui.Entity(ui.controls.TextInput) {
        return self.query;
    }
    fn background(self: *const ui.controls.TextInput) ui.Color {
        return self.appearance.background;
    }
    fn settings(self: *const Shell) ui.WindowHandle {
        return self.settings_window.?;
    }
    fn searchReady(self: *const Shell) bool {
        return self.overlay == .none and self.search.results != null and self.search.results.?.total_matches > 0;
    }
};
fn settle(app: *ui.App, io: std.Io) !void {
    const deadline = std.Io.Clock.awake.now(io).addDuration(.fromSeconds(20));
    var idle_steps: usize = 0;
    while (idle_steps < 3) {
        _ = try app.step(0);
        idle_steps = if (try app.tasksPending()) 0 else idle_steps + 1;
        if (std.Io.Clock.awake.now(io).compare(.gte, deadline)) return error.ReviewTimeout;
        std.Io.sleep(io, .fromMilliseconds(1), .awake) catch {};
    }
}
fn snapshot(app: *ui.App, h: ui.WindowHandle, a: std.mem.Allocator, output: []const u8, theme: []const u8, name: []const u8) !void {
    _ = try app.step(0);
    const path = try std.fmt.allocPrint(a, "{s}/zircon-{s}-{s}.png", .{ output, theme, name });
    defer a.free(path);
    try (try app.window(h)).snapshot(path);
}
fn click(app: *ui.App, h: ui.WindowHandle, label: []const u8) !void {
    _ = try app.step(0);
    const frame = &(try app.window(h)).frames.committed;
    for (frame.nodes.items, 0..) |node, i| if (node.kind == .button and std.mem.eql(u8, node.kind.button.label, label)) {
        const bounds = frame.bounds[i];
        const position: ui.Point = .{ .x = bounds.x + bounds.width / 2, .y = bounds.y + bounds.height / 2 };
        try app.dispatch(h, .{ .pointer_down = .{ .position = position } });
        try app.dispatch(h, .{ .pointer_up = .{ .position = position } });
        _ = try app.step(0);
        return;
    };
    return error.ReviewControlNotFound;
}
fn escape(app: *ui.App, h: ui.WindowHandle) !void {
    try app.dispatch(h, .{ .key_down = .{ .key = .escape } });
    _ = try app.step(0);
}
pub fn main(init: std.process.Init) !void {
    const a = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3) return error.UsageExpectedProjectAndOutput;
    try std.Io.Dir.cwd().createDirPath(init.io, args[2]);
    for ([_][]const u8{ "dark", "light" }) |theme| {
        const settings_path = try std.fmt.allocPrint(a, "{s}/zircon-{s}-settings.json", .{ args[2], theme });
        defer a.free(settings_path);
        const json = try std.fmt.allocPrint(a, "{{\"theme\":\"zircon.{s}\",\"font_size\":14,\"ui_font_size\":13}}", .{theme});
        defer a.free(json);
        try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = settings_path, .data = json });
        var app = try ui.App.init(.{ .allocator = a });
        defer app.deinit();
        const shell = try Shell.init(a, init.io, args[1], "src/main.zig");
        const h = try app.openWindow(Shell, .{ .title = "EditorReview", .chrome = .integrated, .visible = false, .width = 1240, .height = 820 }, shell);
        const owner = try app.windowEntity(Shell, h);
        try app.update(owner, Shell.loadSettings, .{@as(?[]const u8, settings_path)});
        try app.update(owner, Shell.bootstrap, .{h});
        try settle(&app, init.io);
        try snapshot(&app, h, a, args[2], theme, "editor");
        try app.update(owner, Ops.select, .{});
        try snapshot(&app, h, a, args[2], theme, "selection");
        try app.update(owner, Ops.clear, .{});
        try app.update(owner, Ops.command, .{.palette});
        try snapshot(&app, h, a, args[2], theme, "commands");
        try app.update(owner, Ops.command, .{.dismiss});
        try click(&app, h, "Workspace menu");
        try snapshot(&app, h, a, args[2], theme, "workspace-menu");
        try escape(&app, h);
        try click(&app, h, "Split editor");
        try snapshot(&app, h, a, args[2], theme, "split-menu");
        try escape(&app, h);
        try app.update(owner, Ops.command, .{.split_right});
        try snapshot(&app, h, a, args[2], theme, "split");
        try app.update(owner, Ops.command, .{.git_changes});
        try settle(&app, init.io);
        try snapshot(&app, h, a, args[2], theme, "git");
        try click(&app, h, "Branches and stashes");
        try settle(&app, init.io);
        try snapshot(&app, h, a, args[2], theme, "git-branches");
        try click(&app, h, "Stashes");
        try snapshot(&app, h, a, args[2], theme, "git-stashes");
        try click(&app, h, "Branches");
        try snapshot(&app, h, a, args[2], theme, "git-branches-return");
        try escape(&app, h);
        try app.update(owner, Ops.command, .{.project_search});
        _ = try app.step(0);
        try app.dispatch(h, .{ .text = "session" });
        try app.dispatch(h, .{ .key_down = .{ .key = .enter } });
        try settle(&app, init.io);
        if (!try app.read(owner, Ops.searchReady, .{})) return error.ReviewSearchNotReady;
        try snapshot(&app, h, a, args[2], theme, "search");
        try app.update(owner, Ops.open, .{"README.md"});
        try app.update(owner, Ops.command, .{.markdown_preview});
        try settle(&app, init.io);
        try snapshot(&app, h, a, args[2], theme, "markdown");
        try app.update(owner, Ops.command, .{.settings});
        const settings = try app.read(owner, Ops.settings, .{});
        const settings_owner = try app.windowEntity(zircon.SettingsView, settings);
        const query = (try app.read(settings_owner, Ops.fieldColors, .{})).?;
        const background = try app.read(query, Ops.background, .{});
        if (std.mem.eql(u8, theme, "light") and background.r < 0.8) return error.WrongSettingsInputTheme;
        try snapshot(&app, settings, a, args[2], theme, "settings");
        try click(&app, settings, "Lilex");
        try app.dispatch(settings, .{ .text = "Menlo" });
        try snapshot(&app, settings, a, args[2], theme, "font-picker");
        try escape(&app, settings);
        try click(&app, settings, if (std.mem.eql(u8, theme, "light")) "One Light" else "One Dark");
        try snapshot(&app, settings, a, args[2], theme, "theme-picker");
        const narrow_shell = try Shell.init(a, init.io, args[1], "src/main.zig");
        const narrow = try app.openWindow(Shell, .{ .title = "EditorReview narrow", .chrome = .integrated, .visible = false, .width = 700, .height = 650 }, narrow_shell);
        const narrow_owner = try app.windowEntity(Shell, narrow);
        try app.update(narrow_owner, Shell.loadSettings, .{@as(?[]const u8, settings_path)});
        try app.update(narrow_owner, Shell.bootstrap, .{narrow});
        try settle(&app, init.io);
        try snapshot(&app, narrow, a, args[2], theme, "narrow-editor");
        try app.update(narrow_owner, Ops.command, .{.palette});
        try snapshot(&app, narrow, a, args[2], theme, "narrow-commands");
    }
}
