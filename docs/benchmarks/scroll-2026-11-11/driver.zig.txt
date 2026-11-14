//! Native scroll event to frame submission. Fixture setup is outside timing.
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
    fn query(self: *Shell, cx: *ui.Context(Shell)) !void {
        const Set = struct {
            fn call(field: *ui.controls.TextInput, context: *ui.Context(ui.controls.TextInput)) !void {
                try field.bytes.appendSlice(field.allocator, "needle");
                field.cursor = field.bytes.items.len;
                field.anchor = field.cursor;
                field.revision +%= 1;
                context.notify();
            }
        };
        try cx.update(self.fields.?.project_search.query, Set.call, .{});
    }
    fn configure(self: *Shell, cx: *ui.Context(Shell), wrap: bool) !void {
        self.inline_blame_enabled = false;
        if (wrap) try cx.update(self.settings.?, zircon.Settings.apply, .{zircon.SettingsPatch{ .soft_wrap = .editor_width }});
    }
    fn ready(self: *const Shell, mode: []const u8) bool {
        if (self.git.busy or self.search.busy) return false;
        if (std.mem.eql(u8, mode, "git")) return self.git.review != null;
        if (std.mem.eql(u8, mode, "search")) return self.search.results != null;
        return true;
    }
    fn offset(self: *const Shell, mode: []const u8) f32 {
        if (std.mem.eql(u8, mode, "git")) return self.git.diff_scroll.offset;
        if (std.mem.eql(u8, mode, "search")) return self.search.editing.scroll[0].offset;
        return self.tabs.items[self.active].editor.scroll.offset;
    }
    fn verify(self: *const Shell) !void {
        if (self.status_is_error) return error.ScrollStatusError;
        for (self.tabs.items) |tab| if (try self.workspace.dirty(tab.document)) return error.ScrollMutatedSource;
    }
};
fn wait(app: *ui.App, owner: ui.Entity(Shell), io: std.Io, mode: []const u8) !void {
    const deadline = ui.testing.native.now() + 30;
    while (!try app.read(owner, Ops.ready, .{mode}) or try app.tasksPending()) {
        _ = try app.step(ui.testing.native.now());
        if (ui.testing.native.now() >= deadline) return error.ScrollSetupTimeout;
        try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    }
    _ = try app.step(ui.testing.native.now());
}
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 5) return error.ExpectedRootModeWrapAndOutput;
    const root = args[1];
    const mode = args[2];
    var app = try ui.App.init(.{ .allocator = init.gpa });
    defer app.deinit();
    const h = try app.openWindow(Shell, .{ .visible = false, .width = 1240, .height = 820 }, try Shell.init(init.gpa, init.io, root, "main.zig"));
    const owner = try app.windowEntity(Shell, h);
    try app.update(owner, Shell.bootstrap, .{h});
    try wait(&app, owner, init.io, "editor");
    try app.update(owner, Ops.configure, .{std.mem.eql(u8, args[3], "wrap")});
    if (std.mem.eql(u8, mode, "git")) try app.update(owner, Ops.command, .{.git_diff_all});
    if (std.mem.eql(u8, mode, "search")) {
        try app.update(owner, Ops.command, .{.project_search});
        try app.update(owner, Ops.query, .{});
        try app.update(owner, Ops.command, .{.run_project_search});
    }
    try wait(&app, owner, init.io, mode);
    const key = if (std.mem.eql(u8, mode, "git")) "git-diff-lines" else if (std.mem.eql(u8, mode, "search")) "search-excerpts" else "primary-editor";
    const frame = &(try app.window(h)).frames.committed;
    const bounds = for (frame.nodes.items, 0..) |node, index| {
        if (node.key) |id| if (id == .string and std.mem.eql(u8, key, id.string)) break frame.bounds[index];
    } else return error.ScrollTargetMissing;
    const point: ui.Point = .{ .x = bounds.x + bounds.width / 2, .y = bounds.y + bounds.height / 2 };
    (try app.window(h)).profile_frames = true;
    var phases: [120]@FieldType(@TypeOf((try app.window(h)).*), "last_frame_timings") = undefined;
    var samples: [120]f64 = undefined;
    var dispatch_ms: [120]f64 = undefined;
    var nodes: [120]usize = undefined;
    var max_offset: f32 = 0;
    const frames_before = (try app.window(h)).frame_count;
    for (0..132) |i| {
        const before = ui.testing.native.now();
        try app.dispatch(h, .{ .scroll = .{ .position = point, .x = 0, .y = if (i < 66) -42 else 42 } });
        const dispatched = ui.testing.native.now();
        if (try app.step(dispatched) != 1) return error.ScrollFrameNotSubmitted;
        const end = ui.testing.native.now();
        max_offset = @max(max_offset, try app.read(owner, Ops.offset, .{mode}));
        if (i >= 12) {
            phases[i - 12] = (try app.window(h)).last_frame_timings;
            samples[i - 12] = (end - before) * 1000;
            dispatch_ms[i - 12] = (dispatched - before) * 1000;
            nodes[i - 12] = frame.nodes.items.len;
        }
    }
    if (max_offset < 1000) return error.ScrollDidNotMove;
    try app.read(owner, Ops.verify, .{});
    const output = try std.json.Stringify.valueAlloc(init.arena.allocator(), .{ .mode = mode, .wrap = std.mem.eql(u8, args[3], "wrap"), .scroll_to_submit_ms = samples, .dispatch_ms = dispatch_ms, .phases = phases, .nodes = nodes, .max_offset = max_offset, .frames = (try app.window(h)).frame_count - frames_before }, .{});
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = args[4], .data = output });
}
