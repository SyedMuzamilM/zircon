//! Owned process requests keep registry/network/grammar work off the UI thread.
const std = @import("std");
const ui = @import("zircon_ui");
const Shell = @import("../shell.zig").Shell;
const a = std.heap.page_allocator;
pub const Stamp = struct { generation: u64 = 0, index: usize = 0, document: ?@import("zircon_workspace").DocumentId = null, revision: u64 = 0 };
pub const Highlights = struct { spans: []const @import("zircon_editor").syntax.Span, bytes: usize };
pub const Result = struct {
    highlights: ?std.json.Parsed(Highlights) = null,
    stamp: Stamp,
    success: bool,
    stdout: []u8,
    stderr: []u8,
    pub fn deinit(self: *Result) void {
        if (self.highlights) |*parsed| parsed.deinit();
        a.free(self.stdout);
        a.free(self.stderr);
    }
};
pub const Box = @import("handoff.zig").Handoff(Result);
const Job = struct {
    pub const Output = *Box;
    io: std.Io,
    argv: [][]const u8,
    input: ?[]const u8,
    stamp: Stamp,
    pub fn run(self: *Job, cancel: *ui.tasks.Cancellation) !*Box {
        try cancel.check();
        var result = self.perform() catch |err| Result{ .stamp = self.stamp, .success = false, .stdout = try a.dupe(u8, ""), .stderr = try std.fmt.allocPrint(a, "Extension host: {s}", .{@errorName(err)}) };
        errdefer result.deinit();
        result.stamp = self.stamp;
        if (result.success and self.argv.len > 1 and std.mem.eql(u8, self.argv[1], "highlight")) {
            result.highlights = std.json.parseFromSlice(Highlights, a, result.stdout, .{ .allocate = .alloc_always }) catch |err| blk: {
                result.success = false;
                const message = try std.fmt.allocPrint(a, "Invalid grammar response: {s}", .{@errorName(err)});
                a.free(result.stderr);
                result.stderr = message;
                break :blk null;
            };
            a.free(result.stdout);
            result.stdout = &.{};
        }
        try cancel.check();
        return Box.create(a, result);
    }
    fn perform(self: *Job) !Result {
        if (self.input) |input| return runInput(self.io, self.argv, input);
        const output = try std.process.run(a, self.io, .{ .argv = self.argv, .stdout_limit = .limited(64 * 1024 * 1024), .stderr_limit = .limited(64 * 1024), .timeout = .{ .duration = .{ .raw = .fromSeconds(120), .clock = .awake } } });
        return .{ .stamp = self.stamp, .success = output.term.success(), .stdout = output.stdout, .stderr = output.stderr };
    }
    pub fn discard(_: *Job, result: *Box) void {
        result.destroy();
    }
    pub fn deinit(self: *Job, _: std.mem.Allocator) void {
        for (self.argv) |arg| a.free(arg);
        a.free(self.argv);
        if (self.input) |input| a.free(input);
    }
};
fn runInput(io: std.Io, argv: []const []const u8, input: []const u8) !Result {
    var child = try std.process.spawn(io, .{ .argv = argv, .stdin = .pipe, .stdout = .pipe, .stderr = .pipe });
    defer child.kill(io);
    try child.stdin.?.writeStreamingAll(io, input);
    child.stdin.?.close(io);
    child.stdin = null;
    var buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var reader: std.Io.File.MultiReader = undefined;
    reader.init(a, io, buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer reader.deinit();
    const timeout: std.Io.Timeout = .{ .deadline = .fromNow(io, .{ .raw = .fromSeconds(30), .clock = .awake }) };
    while (reader.fill(4096, timeout)) |_| {
        if (reader.reader(0).buffered().len > 64 * 1024 * 1024 or reader.reader(1).buffered().len > 64 * 1024) return error.StreamTooLong;
    } else |err| if (err != error.EndOfStream) return err;
    try reader.checkAnyError();
    const term = try child.wait(io);
    const stdout = try reader.toOwnedSlice(0);
    errdefer a.free(stdout);
    return .{ .stamp = .{}, .success = term.success(), .stdout = stdout, .stderr = try reader.toOwnedSlice(1) };
}
pub fn executable(self: *Shell) ![]u8 {
    if (self.extension_host_path) |path| return a.dupe(u8, path);
    const exe = try std.process.executablePathAlloc(self.workspace.io, a);
    defer a.free(exe);
    const sibling = try std.fs.path.join(a, &.{ std.fs.path.dirname(exe) orelse ".", "zircon-extension-host" });
    if (std.Io.Dir.cwd().statFile(self.workspace.io, sibling, .{})) |_| return sibling else |_| a.free(sibling);
    if (@import("builtin").is_test) return std.Io.Dir.cwd().realPathFileAlloc(self.workspace.io, "tools/zed-extension-host/target/release/zircon-extension-host", a);
    return error.ExtensionHostUnavailable;
}
pub fn start(self: *Shell, cx: *ui.Context(Shell), args: []const []const u8, input: ?[]const u8, stamp: Stamp, comptime callback: anytype) !void {
    var job: Job = .{ .io = self.workspace.io, .argv = try a.alloc([]const u8, args.len + 1), .input = null, .stamp = stamp };
    var count: usize = 0;
    errdefer {
        for (job.argv[0..count]) |arg| a.free(arg);
        a.free(job.argv);
        if (job.input) |bytes| a.free(bytes);
    }
    job.argv[0] = try executable(self);
    count = 1;
    for (args, 1..) |arg, i| {
        job.argv[i] = try a.dupe(u8, arg);
        count += 1;
    }
    if (input) |bytes| job.input = try a.dupe(u8, bytes);
    _ = try cx.spawn(Job, job, callback);
}
