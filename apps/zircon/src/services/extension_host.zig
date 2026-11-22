//! Owned process requests keep registry/network/grammar work off the UI thread.
const std = @import("std");
const builtin = @import("builtin");
const zircon_editor = @import("zircon_editor");
const text = @import("zircon_text");
const ui = @import("zircon_ui");
const zircon_workspace = @import("zircon_workspace");
const shell = @import("../shell.zig");
const handoff = @import("handoff.zig");
const Shell = shell.Shell;
const a = if (builtin.single_threaded) std.heap.page_allocator else std.heap.smp_allocator;
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

const Input = union(enum) {
    bytes: []const u8,
    snapshot: text.Snapshot,

    fn len(self: Input) usize {
        return switch (self) {
            .bytes => |bytes| bytes.len,
            .snapshot => |snapshot| snapshot.byteLen(),
        };
    }

    fn write(self: Input, io: std.Io, file: std.Io.File, cancel: *ui.tasks.Cancellation) !void {
        switch (self) {
            .bytes => |bytes| try file.writeStreamingAll(io, bytes),
            .snapshot => |snapshot| {
                // Buffer small rope leaves so pipe writes do not scale with leaf count.
                var buffer: [64 * 1024]u8 = undefined;
                var writer = file.writerStreaming(io, &buffer);
                var chunks = try snapshot.chunks(.{ .start = 0, .end = snapshot.byteLen() });
                while (chunks.next()) |chunk| {
                    try cancel.check();
                    try writer.interface.writeAll(chunk);
                }
                try writer.interface.flush();
            },
        }
    }
};

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

    fn run(self: *HighlightSession, path: []const u8, grammar: []const []const u8, source: Input, cancel: *ui.tasks.Cancellation) !Result {
        const metadata = try std.json.Stringify.valueAlloc(a, grammar, .{});
        defer a.free(metadata);
        if (metadata.len > 64 * 1024 or source.len() > 8 * 1024 * 1024) return error.StreamTooLong;
        var header: [8]u8 = undefined;
        std.mem.writeInt(u32, header[0..4], @intCast(metadata.len), .little);
        std.mem.writeInt(u32, header[4..8], @intCast(source.len()), .little);

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
        try source.write(io, child.stdin.?, cancel);

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
        while (stream.bufferedLen() < frame_size) {
            try cancel.check();
            try reader.fill(@min(64 * 1024, frame_size - stream.bufferedLen()), timeout);
        }
        if (stream.bufferedLen() != frame_size) return error.InvalidHighlightFrame;
        const body = try a.dupe(u8, stream.buffered()[5..]);
        return .{ .stamp = .{}, .success = status == 1, .stdout = if (status == 1) body else &.{}, .stderr = if (status == 0) body else &.{} };
    }
};

const Job = struct {
    pub const Output = *Box;
    io: std.Io,
    arena: std.heap.ArenaAllocator = .init(a),
    argv: [][]const u8 = &.{},
    input: ?Input = null,
    stamp: Stamp,
    environment: [][2][]const u8 = &.{},
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
        if (self.input) |input| return runInput(self.io, self.argv, input, cancel);
        var environment = std.process.Environ.Map.init(a);
        defer environment.deinit();
        for (self.environment) |pair| try environment.put(pair[0], pair[1]);
        const output = try std.process.run(a, self.io, .{ .argv = self.argv, .environ_map = if (self.environment.len != 0) &environment else null, .stdout_limit = .limited(64 * 1024 * 1024), .stderr_limit = .limited(64 * 1024), .timeout = .{ .duration = .{ .raw = .fromSeconds(120), .clock = .awake } } });
        return .{ .stamp = self.stamp, .success = output.term.success(), .stdout = output.stdout, .stderr = output.stderr };
    }
    pub fn discard(_: *Job, result: *Box) void {
        result.destroy();
    }
    pub fn deinit(self: *Job, _: std.mem.Allocator) void {
        if (self.input) |*input| switch (input.*) {
            .snapshot => |*snapshot| snapshot.deinit(),
            .bytes => {},
        };
        self.arena.deinit();
        if (self.highlight_session) |session| session.release();
    }
};
fn runInput(io: std.Io, argv: []const []const u8, input: Input, cancel: *ui.tasks.Cancellation) !Result {
    var child = try std.process.spawn(io, .{ .argv = argv, .stdin = .pipe, .stdout = .pipe, .stderr = .pipe });
    defer child.kill(io);
    try input.write(io, child.stdin.?, cancel);
    child.stdin.?.close(io);
    child.stdin = null;
    var buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var reader: std.Io.File.MultiReader = undefined;
    reader.init(a, io, buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer reader.deinit();
    const timeout: std.Io.Timeout = .{ .deadline = .fromNow(io, .{ .raw = .fromSeconds(30), .clock = .awake }) };
    while (reader.fill(16 * 1024, timeout)) |_| {
        try cancel.check();
        if (reader.reader(0).buffered().len > 64 * 1024 * 1024 or reader.reader(1).buffered().len > 64 * 1024) return error.StreamTooLong;
    } else |err| if (err != error.EndOfStream) return err;
    try reader.checkAnyError();
    const term = try child.wait(io);
    const stdout = try reader.toOwnedSlice(0);
    errdefer a.free(stdout);
    return .{ .stamp = .{}, .success = term.success(), .stdout = stdout, .stderr = try reader.toOwnedSlice(1) };
}

fn executable(self: *Shell) ![]const u8 {
    if (self.extension_host_path) |path| return path;
    if (self.extension_host_cached) |path| return path;
    const allocator = self.allocator;
    const exe = try std.process.executablePathAlloc(self.workspace.io, allocator);
    defer allocator.free(exe);
    const sibling = try std.fs.path.join(allocator, &.{ std.fs.path.dirname(exe) orelse ".", "zircon-extension-host" });
    const resolved = if (std.Io.Dir.cwd().statFile(self.workspace.io, sibling, .{})) |_| sibling else |_| blk: {
        allocator.free(sibling);
        if (builtin.is_test) {
            const path = try std.Io.Dir.cwd().realPathFileAlloc(self.workspace.io, "tools/zed-extension-host/target/release/zircon-extension-host", allocator);
            defer allocator.free(path);
            break :blk try allocator.dupe(u8, path);
        }
        return error.ExtensionHostUnavailable;
    };
    self.extension_host_cached = resolved;
    return resolved;
}

pub fn start(self: *Shell, cx: *ui.Context(Shell), args: []const []const u8, input: ?[]const u8, stamp: Stamp, comptime callback: anytype) !void {
    return spawn(self, cx, args, if (input) |bytes| .{ .bytes = bytes } else null, stamp, callback);
}

pub fn startSnapshot(self: *Shell, cx: *ui.Context(Shell), args: []const []const u8, snapshot: text.Snapshot, stamp: Stamp, comptime callback: anytype) !void {
    return spawn(self, cx, args, .{ .snapshot = snapshot }, stamp, callback);
}

fn spawn(self: *Shell, cx: *ui.Context(Shell), args: []const []const u8, input: ?Input, stamp: Stamp, comptime callback: anytype) !void {
    var job: Job = .{ .io = self.workspace.io, .stamp = stamp };
    errdefer job.deinit(a);
    const owned = job.arena.allocator();
    job.argv = try owned.alloc([]const u8, args.len + 1);
    job.argv[0] = try owned.dupe(u8, try executable(self));
    for (args, job.argv[1..]) |arg, *dest| dest.* = try owned.dupe(u8, arg);
    if (args.len > 0 and self.shell_env.entries.len != 0 and
        (std.mem.eql(u8, args[0], "resolve") or std.mem.eql(u8, args[0], "resolve-builtin")))
    {
        job.environment = try owned.alloc([2][]const u8, self.shell_env.entries.len);
        for (self.shell_env.entries, job.environment) |pair, *target| {
            target.* = .{ try owned.dupe(u8, pair[0]), try owned.dupe(u8, pair[1]) };
        }
    }

    if (input) |source| {
        job.input = switch (source) {
            .bytes => |bytes| .{ .bytes = try owned.dupe(u8, bytes) },
            .snapshot => |snapshot| .{ .snapshot = snapshot.clone() },
        };
        if (self.extension_host_path == null and args.len == 4 and std.mem.eql(u8, args[0], "highlight")) {
            if (self.highlight_session == null) self.highlight_session = try HighlightSession.create(job.io);
            job.highlight_session = self.highlight_session.?.retain();
        }
    }
    _ = try cx.spawn(Job, job, callback);
}
