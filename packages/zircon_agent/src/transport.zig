//! Bounded JSONL subprocess transport. Reader/writer threads own wire buffers;
//! callers own protocol state and poll messages on their application thread.
const std = @import("std");
const builtin = @import("builtin");
const lines = @import("lines.zig");
const transport_allocator = std.heap.page_allocator;
pub const Wake = struct { context: ?*anyopaque = null, notify: *const fn (?*anyopaque) void };
pub const Message = struct {
    arena: std.heap.ArenaAllocator,
    value: std.json.Value,
    pub fn deinit(self: *Message) void {
        self.arena.deinit();
    }
};
pub const Status = enum(u8) { running, failed, exited };
pub const Config = struct { command: []const u8, args: []const []const u8 = &.{}, cwd: []const u8, wake: ?Wake = null, environ_map: ?*const std.process.Environ.Map = null };
pub const Client = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    child: std.process.Child,
    wake: ?Wake,
    output_thread: ?std.Thread = null,
    error_thread: ?std.Thread = null,
    writer_thread: ?std.Thread = null,
    stopping: std.atomic.Value(bool) = .init(false),
    state: std.atomic.Value(Status) = .init(.running),
    lock: std.Io.Mutex = .init,
    changed: std.Io.Condition = .init,
    outgoing: std.ArrayList([]u8) = .empty,
    outgoing_bytes: usize = 0,
    incoming: std.ArrayList(Message) = .empty,
    incoming_bytes: usize = 0,
    stderr_bytes: std.ArrayList(u8) = .empty,
    pub fn start(a: std.mem.Allocator, io: std.Io, config: Config) !*Client {
        if (config.command.len == 0) return error.InvalidAgentCommand;
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(a);
        try argv.append(a, config.command);
        try argv.appendSlice(a, config.args);
        var child = try std.process.spawn(io, .{ .environ_map = config.environ_map, .argv = argv.items, .cwd = .{ .path = config.cwd }, .stdin = .pipe, .stdout = .pipe, .stderr = .pipe });
        errdefer forceKill(&child, io);
        const self = try a.create(Client);
        self.* = .{ .allocator = a, .io = io, .child = child, .wake = config.wake };
        errdefer {
            self.stopping.store(true, .release);
            self.changed.broadcast(io);
            signalKill(&self.child);
            if (self.writer_thread) |thread| thread.join();
            if (self.output_thread) |thread| thread.join();
            self.cleanup();
            a.destroy(self);
        }
        self.writer_thread = try std.Thread.spawn(.{}, writerMain, .{self});
        self.output_thread = try std.Thread.spawn(.{}, readMain, .{self});
        self.error_thread = try std.Thread.spawn(.{}, stderrMain, .{self});
        return self;
    }
    pub fn status(self: *const Client) Status {
        return self.state.load(.acquire);
    }
    pub fn deinit(self: *Client) void {
        self.stopping.store(true, .release);
        self.changed.broadcast(self.io);
        signalKill(&self.child);
        if (self.writer_thread) |thread| thread.join();
        if (self.output_thread) |thread| thread.join();
        if (self.error_thread) |thread| thread.join();
        forceKill(&self.child, self.io);
        const a = self.allocator;
        self.cleanup();
        a.destroy(self);
    }
    fn cleanup(self: *Client) void {
        for (self.outgoing.items) |bytes| transport_allocator.free(bytes);
        self.outgoing.deinit(transport_allocator);
        for (self.incoming.items) |*message| message.deinit();
        self.incoming.deinit(transport_allocator);
        self.stderr_bytes.deinit(transport_allocator);
    }
    pub fn send(self: *Client, value: anytype) !void {
        const json = try std.json.Stringify.valueAlloc(transport_allocator, value, .{});
        defer transport_allocator.free(json);
        if (json.len > 8 * 1024 * 1024) return error.MessageTooLarge;
        const bytes = try std.mem.concat(transport_allocator, u8, &.{ json, "\n" });
        errdefer transport_allocator.free(bytes);
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        if (self.stopping.load(.acquire)) return error.ClientClosing;
        if (self.outgoing_bytes + bytes.len > 16 * 1024 * 1024) return error.OutgoingQueueFull;
        try self.outgoing.append(transport_allocator, bytes);
        self.outgoing_bytes += bytes.len;
        self.changed.signal(self.io);
    }
    pub fn poll(self: *Client) ?Message {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        if (self.incoming.items.len == 0) return null;
        const message = self.incoming.orderedRemove(0);
        self.incoming_bytes -= message.arena.queryCapacity();
        return message;
    }
    fn publish(self: *Client, raw: Message) void {
        var message = raw;
        self.lock.lockUncancelable(self.io);
        if (self.incoming.items.len >= 2048 or self.incoming_bytes + message.arena.queryCapacity() > 32 * 1024 * 1024) {
            self.lock.unlock(self.io);
            message.deinit();
            self.fail(error.IncomingQueueFull);
            return;
        }
        self.incoming.append(transport_allocator, message) catch {
            self.lock.unlock(self.io);
            message.deinit();
            self.fail(error.OutOfMemory);
            return;
        };
        self.incoming_bytes += message.arena.queryCapacity();
        self.lock.unlock(self.io);
        self.notify();
    }
    fn notify(self: *Client) void {
        if (self.wake) |wake| wake.notify(wake.context);
    }
    fn fail(self: *Client, _: anyerror) void {
        if (!self.stopping.load(.acquire)) {
            self.state.store(.failed, .release);
            self.notify();
        }
    }
};
fn parse(self: *Client, bytes: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(transport_allocator);
    errdefer arena.deinit();
    const value = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), bytes, .{ .allocate = .alloc_always, .max_value_len = 8 * 1024 * 1024 });
    if (value != .object) return error.InvalidAgentMessage;
    self.publish(.{ .arena = arena, .value = value });
}
fn timeout(milliseconds: i64) std.Io.Timeout {
    return .{ .duration = .{ .raw = .fromMilliseconds(milliseconds), .clock = .awake } };
}
fn signalKill(child: *std.process.Child) void {
    if (child.id) |id| switch (builtin.os.tag) {
        .windows => {},
        .wasi => {},
        else => {
            _ = std.posix.system.kill(id, .KILL);
        },
    };
}
fn forceKill(child: *std.process.Child, io: std.Io) void {
    if (child.id == null) return;
    signalKill(child);
    _ = child.wait(io) catch {
        child.kill(io);
    };
}
fn writerMain(self: *Client) void {
    while (true) {
        self.lock.lockUncancelable(self.io);
        while (self.outgoing.items.len == 0 and !self.stopping.load(.acquire)) self.changed.wait(self.io, &self.lock) catch {};
        if (self.stopping.load(.acquire)) {
            self.lock.unlock(self.io);
            return;
        }
        const bytes = self.outgoing.orderedRemove(0);
        self.outgoing_bytes -= bytes.len;
        self.lock.unlock(self.io);
        defer transport_allocator.free(bytes);
        var at: usize = 0;
        while (at < bytes.len and !self.stopping.load(.acquire)) {
            const result = self.io.operateTimeout(.{ .file_write_streaming = .{ .file = self.child.stdin.?, .data = &.{bytes[at..]} } }, timeout(100)) catch |err| {
                if (err == error.Timeout) continue;
                self.fail(err);
                return;
            };
            const count = result.file_write_streaming catch |err| {
                self.fail(err);
                return;
            };
            if (count == 0) {
                self.fail(error.ServerClosedInput);
                return;
            }
            at += count;
        }
    }
}
fn readMain(self: *Client) void {
    var decoder = lines.Decoder.init(transport_allocator);
    defer decoder.deinit();
    var buffer: [8192]u8 = undefined;
    defer {
        self.changed.broadcast(self.io);
        if (!self.stopping.load(.acquire)) {
            self.state.store(.exited, .release);
            self.notify();
        }
    }
    while (!self.stopping.load(.acquire)) {
        const result = self.io.operateTimeout(.{ .file_read_streaming = .{ .file = self.child.stdout.?, .data = &.{&buffer} } }, timeout(100)) catch |err| {
            if (err == error.Timeout) continue;
            self.fail(err);
            return;
        };
        const count = result.file_read_streaming catch |err| {
            if (err != error.EndOfStream) self.fail(err);
            return;
        };
        if (count == 0) continue;
        decoder.feed(buffer[0..count]) catch |err| {
            self.fail(err);
            return;
        };
        while (decoder.next() catch |err| {
            self.fail(err);
            return;
        }) |body| parse(self, body) catch |err| {
            self.fail(err);
            return;
        };
    }
}
fn stderrMain(self: *Client) void {
    var buffer: [2048]u8 = undefined;
    while (!self.stopping.load(.acquire)) {
        const result = self.io.operateTimeout(.{ .file_read_streaming = .{ .file = self.child.stderr.?, .data = &.{&buffer} } }, timeout(100)) catch |err| {
            if (err == error.Timeout) continue;
            return;
        };
        const count = result.file_read_streaming catch return;
        if (count == 0) continue;
        self.lock.lockUncancelable(self.io);
        const available = 64 * 1024 - @min(64 * 1024, self.stderr_bytes.items.len);
        self.stderr_bytes.appendSlice(transport_allocator, buffer[0..@min(count, available)]) catch {};
        self.lock.unlock(self.io);
    }
}
