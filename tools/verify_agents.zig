//! Connect to installed CLIs without sending a model prompt or changing files.
const std = @import("std");
const agent = @import("zircon_agent");
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const cwd = try std.process.currentPathAlloc(init.io, init.arena.allocator());
    const commands: []const []const u8 = if (args.len > 1) args[1..] else &.{ "codex", "opencode" };
    for (commands) |command| {
        const codex = std.mem.eql(u8, command, "codex");
        var c = agent.Conversation.init(init.gpa);
        defer c.deinit();
        try c.connect(init.io, .{ .command = command, .args = if (codex) &.{"app-server"} else &.{"acp"}, .cwd = cwd }, if (codex) .codex else .acp);
        const deadline = std.Io.Clock.awake.now(init.io).addDuration(.fromSeconds(25));
        while (c.state != .ready) {
            _ = try c.poll();
            if (c.state == .failed) {
                // Provider diagnostics may contain private paths/config; don't dump them.
                std.debug.print("{s}: protocol connection failed\n", .{command});
                return error.AgentConnectionFailed;
            }
            if (std.Io.Clock.awake.now(init.io).compare(.gte, deadline)) return error.AgentConnectionTimeout;
            try std.Io.sleep(init.io, .fromMilliseconds(2), .awake);
        }
        std.debug.print("{s}: session ready, {d} models, no prompt sent\n", .{ command, c.models.items.len });
    }
}
