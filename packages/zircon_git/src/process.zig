//! Finite Git processes only. argv is never interpreted by a shell; output and
//! runtime are bounded. Persistent protocols belong in another package.
const std = @import("std");
pub const output_limit = 64 * 1024 * 1024;
pub fn run(a: std.mem.Allocator, io: std.Io, root: []const u8, args: []const []const u8) !std.process.RunResult {
    const prefix = &[_][]const u8{ "git", "--no-pager", "--literal-pathspecs", "-c", "core.quotepath=false", "-c", "color.ui=false", "-C", root };
    const argv = try a.alloc([]const u8, prefix.len + args.len);
    defer a.free(argv);
    @memcpy(argv[0..prefix.len], prefix);
    @memcpy(argv[prefix.len..], args);
    return std.process.run(a, io, .{ .argv = argv, .stdout_limit = .limited(output_limit), .stderr_limit = .limited(1024 * 1024), .timeout = .{ .duration = .{ .raw = .fromSeconds(30), .clock = .awake } } });
}
pub fn success(result: std.process.RunResult) bool {
    return result.term == .exited and result.term.exited == 0;
}
pub fn release(a: std.mem.Allocator, result: std.process.RunResult) void {
    a.free(result.stdout);
    a.free(result.stderr);
}
