//! Native Git expansion and typing through frame submission. No physical scanout.
const std = @import("std");
const zircon = @import("zircon");
const ui = @import("zircon_ui");
const Shell = zircon.Shell;
const Ops = struct {
    fn command(self: *Shell, cx: *ui.Context(Shell), which: zircon.Command) !void {
        var event: ui.Event(ui.Click) = .{ .data = .{} };
        try self.onCommand(&event, cx, which);
        if (self.status_is_error) return error.CommandFailed;
    }
    fn configure(self: *Shell, cx: *ui.Context(Shell)) !void {
        self.inline_blame_enabled = false;
        try cx.update(self.settings.?, zircon.Settings.apply, .{zircon.SettingsPatch{ .soft_wrap = .editor_width }});
    }
    fn ready(self: *const Shell) bool {
        return !self.git.busy;
    }
    fn verifyExpansion(self: *const Shell, expected: usize) !void {
        if (self.status_is_error or self.git.diff.?.hunks[0].new_count != expected) return error.ExpansionDidNotHappen;
    }
    fn tabs(self: *const Shell) usize {
        return self.tabs.items.len;
    }
    fn verifyText(self: *const Shell, edits: usize) !void {
        if (self.status_is_error or self.git.error_text.len > 0) return error.ServiceFailed;
        const view = self.git.editing.current() orelse return error.NoEditor;
        var source = try self.workspace.snapshot(view.document);
        defer source.deinit();
        const line = try source.copy(self.allocator, try source.lineRange(100));
        defer self.allocator.free(line);
        if (source.revision() != edits or !std.mem.endsWith(u8, line, "true;")) return error.IncorrectEdit;
        if (line.len != "const value_101 = true;".len + edits) return error.IncorrectEditLength;
        for (line[0..edits]) |byte| if (byte != 'x') return error.IncorrectEditBytes;
    }
};
fn wait(app: *ui.App, owner: ui.Entity(Shell), io: std.Io) !void {
    const deadline = ui.testing.native.now() + 60;
    while (!try app.read(owner, Ops.ready, .{}) or try app.tasksPending()) {
        _ = try app.step(0);
        if (ui.testing.native.now() >= deadline) return error.SetupTimeout;
        try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    }
    _ = try app.step(0);
}
fn bounds(app: *ui.App, h: ui.WindowHandle, key: []const u8) !ui.Rect {
    const frame = &(try app.window(h)).frames.committed;
    for (frame.nodes.items, 0..) |node, i| if (node.key) |id| if (id == .string and std.mem.eql(u8, id.string, key)) return frame.bounds[i];
    return error.TargetMissing;
}
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3) return error.ExpectedRootAndOutput;
    var app = try ui.App.init(.{ .allocator = init.gpa });
    defer app.deinit();
    const h = try app.openWindow(Shell, .{ .visible = false, .width = 1240, .height = 820 }, try Shell.init(init.gpa, init.io, args[1], "main.zig"));
    const owner = try app.windowEntity(Shell, h);
    try app.update(owner, Shell.bootstrap, .{h});
    try wait(&app, owner, init.io);
    try app.update(owner, Ops.configure, .{});
    try app.update(owner, Ops.command, .{.git_diff_all});
    try wait(&app, owner, init.io);
    (try app.window(h)).profile_frames = true;
    var expansion: [4]f64 = undefined;
    var dispatch: [4]f64 = undefined;
    for (&expansion, &dispatch, 0..) |*elapsed, *input, i| {
        const rect = try bounds(&app, h, "git-context:up:main.zig:98");
        const point: ui.Point = .{ .x = rect.x + 14, .y = rect.y + 12 };
        const begin = ui.testing.native.now();
        try app.dispatch(h, .{ .pointer_down = .{ .position = point } });
        const down_dispatched = ui.testing.native.now();
        _ = try app.step(0);
        const up_begin = ui.testing.native.now();
        try app.dispatch(h, .{ .pointer_up = .{ .position = point } });
        const dispatched = ui.testing.native.now();
        _ = try app.step(0);
        elapsed.* = (ui.testing.native.now() - begin) * 1000;
        input.* = (down_dispatched - begin + dispatched - up_begin) * 1000;
        try app.read(owner, Ops.verifyExpansion, .{7 + (i + 1) * 5});
    }
    // Return to the first added line, then time a burst without waiting for Git.
    const area = try bounds(&app, h, "git-diff-lines");
    try app.dispatch(h, .{ .scroll = .{ .position = .{ .x = area.x + 100, .y = area.y + 100 }, .x = 0, .y = 10000 } });
    _ = try app.step(0);
    const line = try bounds(&app, h, "git-live:main.zig:101");
    const point: ui.Point = .{ .x = line.x + 100, .y = line.y + line.height / 2 };
    try app.dispatch(h, .{ .pointer_down = .{ .position = point } });
    _ = try app.step(0);
    try app.dispatch(h, .{ .pointer_up = .{ .position = point } });
    try app.dispatch(h, .{ .key_down = .{ .key = .home } });
    _ = try app.step(0);
    var typing: [24]f64 = undefined;
    var typing_dispatch: [24]f64 = undefined;
    var typing_phases: [24]@FieldType(@TypeOf((try app.window(h)).*), "last_frame_timings") = undefined;
    for (&typing, 0..) |*elapsed, i| {
        const begin = ui.testing.native.now();
        try app.dispatch(h, .{ .text = "x" });
        const dispatched = ui.testing.native.now();
        if (try app.step(0) != 1) return error.EditFrameNotSubmitted;
        elapsed.* = (ui.testing.native.now() - begin) * 1000;
        typing_dispatch[i] = (dispatched - begin) * 1000;
        typing_phases[i] = (try app.window(h)).last_frame_timings;
        try app.read(owner, Ops.verifyText, .{i + 1});
        const prefix = "xxxxxxxxxxxxxxxxxxxxxxxx";
        var painted = false;
        for ((try app.window(h)).frames.committed.scene.items) |item| if (item.kind == .text and std.mem.indexOf(u8, item.text, prefix[0 .. i + 1]) != null) {
            painted = true;
            break;
        };
        if (!painted) return error.EditedTextNotPainted;
    }
    const output = try std.json.Stringify.valueAlloc(init.arena.allocator(), .{ .expansion_ms = expansion, .expansion_dispatch_ms = dispatch, .typing_ms = typing, .typing_dispatch_ms = typing_dispatch, .typing_phases = typing_phases, .tabs = try app.read(owner, Ops.tabs, .{}), .expansions = 4, .edits = 24, .errors = 0 }, .{});
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = args[2], .data = output });
}
