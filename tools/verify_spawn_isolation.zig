//! Verifies that a child receives declared handles without leaking unrelated
//! pipes created concurrently by another service. Run through tools/zig.
const std = @import("std");
extern "c" fn pipe(*[2]c_int) c_int;
extern "c" fn close(c_int) c_int;
extern "c" fn fcntl(c_int, c_int, ...) c_int;

pub fn main(init: std.process.Init) !void {
    if (@import("builtin").os.tag != .macos) return error.RequiresMacOS;
    var ends: [2]c_int = undefined;
    if (pipe(&ends) != 0) return error.PipeFailed;
    defer _ = close(ends[0]);
    defer _ = close(ends[1]);
    // Model Darwin's pipe()/fcntl() window with stable high-numbered handles.
    const input = fcntl(ends[0], std.c.F.DUPFD, @as(c_int, 128));
    if (input < 0) return error.DuplicateFailed;
    defer _ = close(input);
    const output = fcntl(ends[1], std.c.F.DUPFD, @as(c_int, 129));
    if (output < 0) return error.DuplicateFailed;
    defer _ = close(output);
    const in_arg = try std.fmt.allocPrint(init.arena.allocator(), "{d}", .{input});
    const out_arg = try std.fmt.allocPrint(init.arena.allocator(), "{d}", .{output});
    const probe =
        \\import os, sys
        \\leaked = []
        \\for fd in map(int, sys.argv[1:]):
        \\    try:
        \\        os.fstat(fd)
        \\        leaked.append(fd)
        \\    except OSError:
        \\        pass
        \\print("unrelated pipe handles inherited:", leaked, flush=True)
        \\sys.exit(bool(leaked))
    ;
    const result = try std.process.run(init.gpa, init.io, .{ .argv = &.{ "python3", "-c", probe, in_arg, out_arg }, .timeout = .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } } });
    defer init.gpa.free(result.stdout);
    defer init.gpa.free(result.stderr);
    std.debug.print("{s}{s}", .{ result.stdout, result.stderr });
    if (!result.term.success()) return error.UnrelatedPipeInherited;
    var explicit = try std.process.spawn(init.io, .{
        .argv = &.{ "python3", "-c", "import os,sys; os.fstat(int(sys.argv[1])); print('explicit pipe handle preserved', flush=True)", out_arg },
        .inherit_files = &.{.{ .handle = output, .flags = .{ .nonblocking = false } }},
    });
    defer explicit.kill(init.io);
    if (!(try explicit.wait(init.io)).success()) return error.ExplicitHandleLost;
}
