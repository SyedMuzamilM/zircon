//! Owned process requests keep registry/network/grammar work off the UI thread.
const std = @import("std");
const builtin = @import("builtin");
const zircon_editor = @import("zircon_editor");
const ui = @import("zircon_ui");
const zircon_workspace = @import("zircon_workspace");
const shell = @import("../shell.zig");
const handoff = @import("handoff.zig");
const Shell = shell.Shell;
const a = std.heap.page_allocator;
pub const Stamp = struct { generation: u64 = 0, epoch: u64 = 0, index: usize = 0, document: ?zircon_workspace.DocumentId = null, revision: u64 = 0 };
pub const SearchMatch = struct { start: usize, end: usize, replacement: []const u8 };
pub const SearchResult = struct { matches: []const SearchMatch, truncated: bool };
pub const Highlights = struct { spans: []const zircon_editor.syntax.Span, bytes: usize };
pub const Result = struct {
    highlights: ?std.json.Parsed(Highlights) = null,
    search: ?std.json.Parsed(SearchResult) = null,
    stamp: Stamp,
    success: bool,
    stdout: []u8,
    stderr: []u8,
    pub fn deinit(self: *Result) void {
        if (self.highlights) |*parsed| parsed.deinit();
        if (self.search) |*parsed| parsed.deinit();
        a.free(self.stdout);
        a.free(self.stderr);
    }
};
pub const Box = handoff.Handoff(Result);

/// One isolated highlighter per window. Jobs serialize exchanges on the pipe;
/// losing a process drops that exchange and the next retry starts a fresh one.
pub const HighlightSession = struct {
    io: std.Io,
    refs: usize = 1,
    mutex: std.Io.Mutex = .init,
    child: ?std.process.Child = null,

    fn create(io: std.Io) !*HighlightSession {
        const self = try a.create(HighlightSession);
        self.* = .{ .io = io };
        return self;
    }

    fn retain(self: *HighlightSession) *HighlightSession {
        self.refs += 1;
        return self;
    }

    pub fn release(self: *HighlightSession) void {
        self.refs -= 1;
        if (self.refs == 0) {
            self.close();
            a.destroy(self);
        }
    }

    fn close(self: *HighlightSession) void {
        if (self.child) |*child| child.kill(self.io);
        self.child = null;
    }

    fn run(self: *HighlightSession, path: []const u8, grammar: []const []const u8, source: []const u8, cancel: *ui.tasks.Cancellation) !Result {
        const metadata = try std.json.Stringify.valueAlloc(a, grammar, .{});
        defer a.free(metadata);
        if (metadata.len > 64 * 1024 or source.len > 8 * 1024 * 1024) return error.StreamTooLong;
        var header: [8]u8 = undefined;
        std.mem.writeInt(u32, header[0..4], @intCast(metadata.len), .little);
        std.mem.writeInt(u32, header[4..8], @intCast(source.len), .little);

        const io = self.io;
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        try cancel.check();
        if (self.child == null) self.child = try std.process.spawn(io, .{
            .argv = &.{ path, "highlight-session" },
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .ignore,
        });
        errdefer self.close();
        const child = &self.child.?;
        try child.stdin.?.writeStreamingAll(io, &header);
        try child.stdin.?.writeStreamingAll(io, metadata);
        try child.stdin.?.writeStreamingAll(io, source);

        var buffer: std.Io.File.MultiReader.Buffer(1) = undefined;
        var reader: std.Io.File.MultiReader = undefined;
        reader.init(a, io, buffer.toStreams(), &.{child.stdout.?});
        defer reader.deinit();
        const timeout: std.Io.Timeout = .{ .deadline = .fromNow(io, .{ .raw = .fromSeconds(30), .clock = .awake }) };
        const stream = reader.reader(0);
        while (stream.bufferedLen() < 5) try reader.fill(5, timeout);
        const response_header = stream.buffered()[0..5];
        const status = response_header[0];
        if (status > 1) return error.InvalidHighlightFrame;
        const size = std.mem.readInt(u32, response_header[1..5], .little);
        if (size > (if (status == 1) @as(u32, 64 * 1024 * 1024) else 64 * 1024)) return error.StreamTooLong;
        const frame_size: usize = 5 + size;
        while (stream.bufferedLen() < frame_size) try reader.fill(4096, timeout);
        if (stream.bufferedLen() != frame_size) return error.InvalidHighlightFrame;
        const body = try a.dupe(u8, stream.buffered()[5..]);
        return .{ .stamp = .{}, .success = status == 1, .stdout = if (status == 1) body else &.{}, .stderr = if (status == 0) body else &.{} };
    }
};

const Job = struct {
    pub const Output = *Box;
    io: std.Io,
    argv: [][]const u8,
    input: ?[]const u8,
    stamp: Stamp,
    highlight_session: ?*HighlightSession = null,
    pub fn run(self: *Job, cancel: *ui.tasks.Cancellation) !*Box {
        try cancel.check();
        var result = self.perform(cancel) catch |err| Result{ .stamp = self.stamp, .success = false, .stdout = &.{}, .stderr = try std.fmt.allocPrint(a, "Extension host: {s}", .{@errorName(err)}) };
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
        if (result.success and self.argv.len > 1 and std.mem.eql(u8, self.argv[1], "search")) {
            result.search = std.json.parseFromSlice(SearchResult, a, result.stdout, .{ .allocate = .alloc_always }) catch |err| blk: {
                result.success = false;
                const message = try std.fmt.allocPrint(a, "Invalid search response: {s}", .{@errorName(err)});
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
    fn perform(self: *Job, cancel: *ui.tasks.Cancellation) !Result {
        if (self.highlight_session) |session| return session.run(self.argv[0], self.argv[2..], self.input.?, cancel);
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
        if (self.highlight_session) |session| session.release();
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
    if (builtin.is_test) return std.Io.Dir.cwd().realPathFileAlloc(self.workspace.io, "tools/zed-extension-host/target/release/zircon-extension-host", a);
    return error.ExtensionHostUnavailable;
}

pub fn start(self: *Shell, cx: *ui.Context(Shell), args: []const []const u8, input: ?[]const u8, stamp: Stamp, comptime callback: anytype) !void {
    var job: Job = .{ .io = self.workspace.io, .argv = try a.alloc([]const u8, args.len + 1), .input = null, .stamp = stamp };
    var count: usize = 0;
    errdefer {
        for (job.argv[0..count]) |arg| a.free(arg);
        a.free(job.argv);
        if (job.input) |bytes| a.free(bytes);
        if (job.highlight_session) |session| session.release();
    }
    job.argv[0] = try executable(self);
    count = 1;
    for (args, 1..) |arg, i| {
        job.argv[i] = try a.dupe(u8, arg);
        count += 1;
    }
    if (input) |bytes| job.input = try a.dupe(u8, bytes);
    if (self.extension_host_path == null and job.input != null and args.len == 4 and std.mem.eql(u8, args[0], "highlight")) {
        if (self.highlight_session == null) self.highlight_session = try HighlightSession.create(job.io);
        job.highlight_session = self.highlight_session.?.retain();
    }
    _ = try cx.spawn(Job, job, callback);
}
