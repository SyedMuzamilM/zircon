//! Event-driven PTY transport with lock-free byte rings and a control pipe
//! for queued input, output backpressure and reader shutdown.

const std = @import("std");
const builtin = @import("builtin");
pub const ShellOptions = struct {
    command: ?[]const u8 = null,
    args: []const []const u8 = &.{"-l"},
    extra_env: []const [2][]const u8 = &.{},
    max_history: usize = 10_000,
};

pub const WakeFn = *const fn () void;

/// Single-producer (PTY reader thread), single-consumer (UI thread) byte ring.
pub const ByteRing = struct {
    pub const capacity = 256 * 1024;
    const mask = capacity - 1;

    buf: [capacity]u8 = undefined,
    read_pos: std.atomic.Value(usize) = .init(0),
    write_pos: std.atomic.Value(usize) = .init(0),

    pub fn availableRead(self: *const ByteRing) usize {
        const w = self.write_pos.load(.acquire);
        const r = self.read_pos.load(.monotonic);
        return w -% r;
    }

    pub fn availableWrite(self: *const ByteRing) usize {
        const w = self.write_pos.load(.monotonic);
        const r = self.read_pos.load(.acquire);
        return capacity - (w -% r);
    }

    /// Producer pushes up to `data.len` bytes; returns bytes pushed and whether ring was empty.
    pub fn push(self: *ByteRing, data: []const u8) struct { written: usize, was_empty: bool } {
        const r = self.read_pos.load(.acquire);
        const w = self.write_pos.load(.monotonic);
        const used = w -% r;
        const space = capacity - used;
        const n = @min(data.len, space);
        if (n == 0) return .{ .written = 0, .was_empty = false };
        const start = w & mask;
        const first = @min(n, capacity - start);
        @memcpy(self.buf[start .. start + first], data[0..first]);
        if (n > first) @memcpy(self.buf[0 .. n - first], data[first..n]);
        self.write_pos.store(w +% n, .release);
        return .{ .written = n, .was_empty = used == 0 };
    }

    /// The consumer may write this contiguous segment directly to a descriptor
    /// before advancing the cursor by the number of bytes accepted.
    fn peek(self: *const ByteRing) []const u8 {
        const start = self.read_pos.load(.monotonic) & mask;
        return self.buf[start..][0..@min(self.availableRead(), capacity - start)];
    }

    fn consume(self: *ByteRing, count: usize) void {
        const position = self.read_pos.load(.monotonic);
        self.read_pos.store(position +% count, .release);
    }

    /// Consumer drains into `out`, returning the slice of drained bytes.
    pub fn pop(self: *ByteRing, out: []u8) []u8 {
        const w = self.write_pos.load(.acquire);
        const r = self.read_pos.load(.monotonic);
        const avail = w -% r;
        const n = @min(out.len, avail);
        if (n == 0) return out[0..0];
        const start = r & mask;
        const first = @min(n, capacity - start);
        @memcpy(out[0..first], self.buf[start .. start + first]);
        if (n > first) @memcpy(out[first..n], self.buf[0 .. n - first]);
        self.read_pos.store(r +% n, .release);
        return out[0..n];
    }
};

const c = std.c;
pub const supported = builtin.link_libc and (builtin.os.tag == .macos or builtin.os.tag == .linux);
const Winsize = extern struct { row: u16, col: u16, xpixel: u16 = 0, ypixel: u16 = 0 };
const set_controlling_tty: c_ulong = if (builtin.os.tag == .macos) 0x20007461 else std.os.linux.T.IOCSCTTY;
const set_window_size: c_ulong = if (builtin.os.tag == .macos) 0x80087467 else std.os.linux.T.IOCSWINSZ;
extern "c" fn openpty(*c_int, *c_int, ?*anyopaque, ?*anyopaque, *const Winsize) c_int;
extern "c" fn ioctl(c_int, c_ulong, ...) c_int;
extern "c" fn _NSGetEnviron() *[*:null]?[*:0]u8;

pub const Pty = struct {
    allocator: std.mem.Allocator,
    master: c_int,
    pid: c_int,
    control: [2]c_int,
    output: ByteRing = .{},
    input: ByteRing = .{},
    ended: std.atomic.Value(bool) = .init(false),
    stopping: std.atomic.Value(bool) = .init(false),
    wake_pending: std.atomic.Value(bool) = .init(false),
    wake: ?WakeFn,
    reader: std.Thread = undefined,

    pub fn spawn(a: std.mem.Allocator, root: []const u8, cols: usize, rows: usize, options: ShellOptions, wake: ?WakeFn) !*Pty {
        if (comptime !supported) return error.TerminalUnavailable;
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const temp = arena.allocator();
        const cwd = try temp.dupeSentinel(u8, root, 0);
        const fallback = if (builtin.os.tag == .macos) "/bin/zsh" else "/bin/sh";
        const command = options.command orelse if (c.getenv("SHELL")) |path| std.mem.span(path) else fallback;
        var vars: std.StringHashMapUnmanaged([]const u8) = .empty;
        const inherited = if (builtin.os.tag == .macos) _NSGetEnviron().* else c.environ;
        var i: usize = 0;
        while (inherited[i]) |entry| : (i += 1) {
            const pair = std.mem.span(entry);
            const equal = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
            try vars.put(temp, pair[0..equal], pair[equal + 1 ..]);
        }
        for (options.extra_env) |pair| {
            if (pair[0].len == 0 or std.mem.indexOfAny(u8, pair[0], "=\x00") != null or std.mem.indexOfScalar(u8, pair[1], 0) != null) return error.InvalidTerminalEnvironment;
            try vars.put(temp, pair[0], pair[1]);
        }
        try vars.put(temp, "TERM", "xterm-256color");
        try vars.put(temp, "COLORTERM", "truecolor");
        try vars.put(temp, "TERM_PROGRAM", "Zircon");
        try vars.put(temp, "PWD", root);
        const shell_path = try resolveProgram(temp, root, command, vars.get("PATH") orelse "/usr/bin:/bin");
        const argv = try temp.allocSentinel(?[*:0]const u8, options.args.len + 1, null);
        argv[0] = shell_path;
        for (options.args, argv[1..]) |arg, *slot| {
            if (std.mem.indexOfScalar(u8, arg, 0) != null) return error.InvalidTerminalCommand;
            slot.* = try temp.dupeSentinel(u8, arg, 0);
        }
        const env = try temp.allocSentinel(?[*:0]const u8, vars.count(), null);
        var entries = vars.iterator();
        var index: usize = 0;
        while (entries.next()) |entry| : (index += 1) {
            env[index] = try std.fmt.allocPrintSentinel(temp, "{s}={s}", .{ entry.key_ptr.*, entry.value_ptr.* }, 0);
        }

        var control: [2]c_int = undefined;
        if (c.pipe(&control) != 0) return error.TerminalOpenFailed;
        errdefer {
            for (control) |fd| _ = c.close(fd);
        }
        for (control) |fd| try configureFd(fd);

        var master: c_int = undefined;
        var slave: c_int = undefined;
        const size = windowSize(cols, rows);
        if (openpty(&master, &slave, null, null, &size) != 0) return error.TerminalOpenFailed;
        errdefer _ = c.close(master);
        defer _ = c.close(slave);
        try configureFd(master);
        if (c.fcntl(slave, c.F.SETFD, @as(c_int, c.FD_CLOEXEC)) < 0) return error.TerminalOpenFailed;

        const self = try a.create(Pty);
        errdefer a.destroy(self);
        const pid = c.fork();
        if (pid < 0) return error.TerminalSpawnFailed;
        if (pid == 0) {
            _ = c.close(master);
            for (control) |fd| _ = c.close(fd);
            if (c.setsid() < 0 or ioctl(slave, set_controlling_tty, @as(c_int, 0)) < 0) c._exit(126);
            for (0..3) |stdio_index| {
                const fd: c_int = @intCast(stdio_index);
                if (c.dup2(slave, fd) < 0 or c.fcntl(fd, c.F.SETFD, @as(c_int, 0)) < 0) c._exit(126);
            }
            if (slave > 2) _ = c.close(slave);
            if (c.chdir(cwd) != 0) c._exit(126);
            _ = c.execve(shell_path, argv.ptr, env.ptr);
            c._exit(127);
        }
        errdefer terminate(pid);
        self.* = .{ .allocator = a, .master = master, .pid = pid, .control = control, .wake = wake };
        self.reader = try std.Thread.spawn(.{}, readerMain, .{self});
        return self;
    }

    pub fn destroy(self: *Pty) void {
        if (comptime supported) {
            self.stopping.store(true, .release);
            self.signalWorker();
            self.reader.join();
            _ = c.close(self.master);
            for (self.control) |fd| _ = c.close(fd);
            if (self.pid > 0) terminate(self.pid);
        }
        self.allocator.destroy(self);
    }

    pub fn send(self: *Pty, bytes: []const u8) !void {
        if (comptime !supported) return error.TerminalUnavailable;
        if (bytes.len == 0 or self.ended.load(.acquire)) return;
        if (self.input.availableWrite() < bytes.len) return error.TerminalInputFull;
        const result = self.input.push(bytes);
        std.debug.assert(result.written == bytes.len);
        self.signalWorker();
    }

    pub fn resize(self: *Pty, cols: usize, rows: usize) void {
        if (comptime supported) {
            const size = windowSize(cols, rows);
            _ = ioctl(self.master, set_window_size, &size);
        }
    }

    pub fn hasData(self: *const Pty) bool {
        return self.output.availableRead() != 0;
    }

    pub fn drain(self: *Pty, out: []u8) []u8 {
        const bytes = self.output.pop(out);
        if (comptime supported) if (bytes.len != 0) self.signalWorker();
        return bytes;
    }

    /// Rearm wakeups after a UI drain. A racing publisher is covered by the
    /// flag exchange or this check, even when the ring never looked empty to it.
    pub fn acknowledge(self: *Pty) void {
        _ = self.wake_pending.swap(false, .acq_rel);
        if (self.hasData()) self.signalUi();
    }

    pub fn isExited(self: *Pty) bool {
        if (!self.ended.load(.acquire)) return false;
        if (comptime supported) if (self.pid > 0) {
            const result = c.waitpid(self.pid, null, c.W.NOHANG);
            if (result == self.pid or c.errno(result) == .CHILD) self.pid = -1;
        };
        return true;
    }

    fn signalWorker(self: *const Pty) void {
        const marker = [_]u8{1};
        while (c.errno(c.write(self.control[1], &marker, marker.len)) == .INTR) {}
    }

    fn signalUi(self: *Pty) void {
        if (self.wake) |notify| {
            if (!self.wake_pending.swap(true, .acq_rel)) notify();
        }
    }

    fn readerMain(self: *Pty) void {
        defer {
            self.ended.store(true, .release);
            self.signalUi();
        }
        var buffer: [16384]u8 = undefined;
        while (!self.stopping.load(.acquire)) {
            const writable = self.output.availableWrite();
            const input = self.input.peek();
            const master_events = @as(c_short, if (writable != 0) c.POLL.IN else 0) |
                @as(c_short, if (input.len != 0) c.POLL.OUT else 0);
            var fds = [_]c.pollfd{
                .{ .fd = if (master_events != 0) self.master else -1, .events = master_events, .revents = 0 },
                .{ .fd = self.control[0], .events = c.POLL.IN, .revents = 0 },
            };
            const result = c.poll(&fds, fds.len, -1);
            switch (c.errno(result)) {
                .SUCCESS => {},
                .INTR => continue,
                else => return,
            }
            if (self.stopping.load(.acquire)) return;
            if (fds[1].revents & c.POLL.IN != 0) {
                var markers: [128]u8 = undefined;
                _ = c.read(self.control[0], &markers, markers.len);
            }
            const events = fds[0].revents;
            const closed = events & (c.POLL.HUP | c.POLL.ERR | c.POLL.NVAL) != 0;
            if (writable != 0 and (events & c.POLL.IN != 0 or closed)) {
                const count = c.read(self.master, &buffer, @min(buffer.len, writable));
                switch (c.errno(count)) {
                    .SUCCESS => {
                        if (count == 0) return;
                        const bytes = buffer[0..@intCast(count)];
                        const published = self.output.push(bytes);
                        std.debug.assert(published.written == bytes.len);
                        self.signalUi();
                    },
                    .INTR => continue,
                    .AGAIN => if (closed) return,
                    else => return,
                }
            }
            if (input.len != 0 and events & c.POLL.OUT != 0 and !closed) {
                const count = c.write(self.master, input.ptr, input.len);
                switch (c.errno(count)) {
                    .SUCCESS => self.input.consume(@intCast(count)),
                    .INTR, .AGAIN => {},
                    else => return,
                }
            }
            if (closed and writable == 0) {
                // Keep the descriptor out of poll until the UI makes room
                // for the remaining output preceding the hangup.
                self.input.consume(input.len);
            }
        }
    }
};

fn resolveProgram(a: std.mem.Allocator, root: []const u8, command: []const u8, path: []const u8) ![:0]const u8 {
    if (command.len == 0 or std.mem.indexOfScalar(u8, command, 0) != null) return error.InvalidTerminalCommand;
    if (std.fs.path.isAbsolute(command)) return a.dupeSentinel(u8, command, 0);
    if (std.mem.indexOfScalar(u8, command, '/') != null) {
        const resolved = try std.fs.path.resolve(a, &.{ root, command });
        return a.dupeSentinel(u8, resolved, 0);
    }
    var dirs = std.mem.splitScalar(u8, path, ':');
    while (dirs.next()) |dir| {
        const resolved = if (std.fs.path.isAbsolute(dir))
            try std.fs.path.resolve(a, &.{ dir, command })
        else
            try std.fs.path.resolve(a, &.{ root, dir, command });
        const candidate = try a.dupeSentinel(u8, resolved, 0);
        if (c.access(candidate, c.X_OK) == 0) return candidate;
    }
    return error.TerminalCommandNotFound;
}

fn windowSize(cols: usize, rows: usize) Winsize {
    return .{ .row = @intCast(std.math.clamp(rows, 1, std.math.maxInt(u16))), .col = @intCast(std.math.clamp(cols, 1, std.math.maxInt(u16))) };
}

fn configureFd(fd: c_int) !void {
    const flags: c.O = .{ .NONBLOCK = true };
    if (c.fcntl(fd, c.F.SETFD, @as(c_int, c.FD_CLOEXEC)) < 0 or
        c.fcntl(fd, c.F.SETFL, @as(c_int, @bitCast(flags))) < 0) return error.TerminalOpenFailed;
}

fn terminate(pid: c_int) void {
    _ = c.kill(-pid, .HUP);
    _ = c.kill(pid, .KILL);
    while (c.errno(c.waitpid(pid, null, 0)) == .INTR) {}
}
