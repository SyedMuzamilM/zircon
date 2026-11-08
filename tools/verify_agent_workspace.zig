//! Native installed-provider smoke journey. It sends no model prompt.
const std = @import("std");
const zircon = @import("zircon");
const ui = @import("zircon_ui");
const Shell = zircon.Shell;
const Ops = struct {
    fn start(self: *Shell, cx: *ui.Context(Shell), provider: []const u8) !void {
        var e: ui.Event(ui.Click) = .{ .data = .{} };
        try self.onCommand(&e, cx, .agent_mode);
        for (self.agents.config.?.value.providers, 0..) |entry, index| if (std.mem.eql(u8, entry.name, provider)) {
            self.agents.provider = index;
            break;
        };
        try self.onCommand(&e, cx, .agent_connect);
    }
    fn ready(self: *const Shell) bool {
        const s = self.agents.current() orelse return false;
        return s.conversation.state == .ready;
    }
    fn failed(self: *const Shell) bool {
        const s = self.agents.current() orelse return false;
        return s.conversation.state == .failed;
    }
    fn models(self: *const Shell) usize {
        const s = self.agents.current() orelse return 0;
        var count: usize = 0;
        for (s.conversation.models.items) |m| if (std.mem.startsWith(u8, m.id, "cli-proxy/")) {
            count += 1;
        };
        return count;
    }
};
pub fn main(init: std.process.Init) !void {
    const a = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3) return error.ExpectedConfigAndOutput;
    const root = args[2];
    try std.Io.Dir.cwd().createDirPath(init.io, root);
    const target = try std.fs.path.join(init.arena.allocator(), &.{ root, "agents.json" });
    const config = try std.Io.Dir.cwd().readFileAlloc(init.io, args[1], a, .limited(1024 * 1024));
    defer a.free(config);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = target, .data = config });
    var app = try ui.App.init(.{ .allocator = a });
    defer app.deinit();
    const h = try app.openWindow(Shell, .{ .visible = false, .chrome = .integrated, .width = 1240, .height = 820 }, try Shell.init(a, init.io, root, null));
    const owner = try app.windowEntity(Shell, h);
    try app.update(owner, Shell.configureAgents, .{ root, @as(?*const std.process.Environ.Map, init.environ_map) });
    try app.update(owner, Shell.bootstrap, .{h});
    try app.update(owner, Ops.start, .{"CLI Proxy"});
    const deadline = std.Io.Clock.awake.now(init.io).addDuration(.fromSeconds(30));
    while (!try app.read(owner, Ops.ready, .{})) {
        _ = try app.step(0);
        if (try app.read(owner, Ops.failed, .{})) return error.AgentFailed;
        if (std.Io.Clock.awake.now(init.io).compare(.gte, deadline)) return error.Timeout;
        try std.Io.sleep(init.io, .fromMilliseconds(2), .awake);
    }
    _ = try app.step(0);
    const count = try app.read(owner, Ops.models, .{});
    if (count == 0) return error.ProxyModelsMissing;
    const screenshot = try std.fs.path.join(init.arena.allocator(), &.{ root, "proxy-native.png" });
    try (try app.window(h)).snapshot(screenshot);
    std.debug.print("Native CLI Proxy profile ready: {d} proxy models; credential-file loading verified; no prompt sent.\n", .{count});
}
