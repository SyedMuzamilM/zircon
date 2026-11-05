//! Worker jobs own their inputs and never borrow entity state. Workers publish
//! results with a release/acquire handoff; only the creator thread delivers
//! completions and releases job storage. Cancellation is cooperative.
const std = @import("std");
var next_queue = std.atomic.Value(u64).init(1);

pub const Handle = struct { queue: u64, slot: u32, generation: u32 };
/// A job must check this token while doing interruptible work. Cancellation
/// cannot terminate a blocking system call or forcibly stop a worker thread.
pub const Cancellation = struct {
    canceled: std.atomic.Value(bool) = .init(false),
    pub fn isCanceled(token: *const Cancellation) bool {
        return token.canceled.load(.acquire);
    }
    pub fn check(token: *const Cancellation) !void {
        if (token.isCanceled()) return error.Canceled;
    }
};
const Entry = struct {
    cancellation: Cancellation = .{},
    done: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,
    finish: *const fn (*Entry, std.mem.Allocator, bool) anyerror!void,
};
const Slot = struct { entry: ?*Entry = null, generation: u32 = 1, retired: bool = false };

pub const Queue = struct {
    allocator: std.mem.Allocator,
    owner: std.Thread.Id,
    identity: u64,
    slots: std.ArrayList(Slot) = .empty,
    draining: bool = false,
    shutting_down: bool = false,
    pub fn init(allocator: std.mem.Allocator) Queue {
        const identity = next_queue.fetchAdd(1, .monotonic);
        std.debug.assert(identity != 0 and identity != std.math.maxInt(u64));
        return .{ .allocator = allocator, .owner = std.Thread.getCurrentId(), .identity = identity };
    }
    /// Cancels and joins every worker. Shutdown discards results without calling
    /// completion handlers, then runs each job's optional deinit on this thread.
    /// A job that ignores cancellation can delay shutdown until run returns.
    pub fn deinit(queue: *Queue) void {
        std.debug.assert(queue.owner == std.Thread.getCurrentId() and !queue.draining);
        queue.shutting_down = true;
        for (queue.slots.items) |slot| if (slot.entry) |entry| entry.cancellation.canceled.store(true, .release);
        for (queue.slots.items) |slot| if (slot.entry) |entry| {
            entry.thread.?.join();
            entry.finish(entry, queue.allocator, false) catch unreachable;
        };
        queue.slots.deinit(queue.allocator);
        queue.* = undefined;
    }
    fn check(queue: *const Queue) !void {
        if (queue.owner != std.Thread.getCurrentId()) return error.WrongThread;
        if (queue.shutting_down) return error.TaskQueueClosing;
    }
    /// On success the queue takes ownership of job. On failure ownership stays
    /// with the caller. Job.run executes on a worker. Job.complete executes on
    /// the creator thread and BORROWS the output only for that callback. The
    /// queue always calls Job.discard afterwards, even if completion fails or
    /// cancellation won the race with successful work. Copy output to retain it.
    ///
    /// Job declares Output, run(*Job,*Cancellation)!Output,
    /// complete(*Job,anyerror!Output)!void, discard(*Job,Output)void and optionally
    /// deinit(*Job,Allocator)void. Job's run implementation must not call UI APIs.
    pub fn spawn(queue: *Queue, comptime Job: type, job: Job) !Handle {
        try queue.check();
        comptime {
            for (.{ "Output", "run", "complete", "discard" }) |name| if (!@hasDecl(Job, name)) @compileError("background job requires " ++ name);
        }
        var index: ?u32 = null;
        for (queue.slots.items, 0..) |slot, i| if (slot.entry == null and !slot.retired) {
            index = @intCast(i);
            break;
        };
        if (index == null) {
            if (queue.slots.items.len >= std.math.maxInt(u32)) return error.TaskCapacityExceeded;
            try queue.slots.append(queue.allocator, .{});
            index = @intCast(queue.slots.items.len - 1);
        }
        const Box = struct {
            entry: Entry = .{ .finish = finish },
            job: Job,
            result: anyerror!Job.Output = undefined,
            fn work(self: *@This()) void {
                self.result = self.job.run(&self.entry.cancellation);
                self.entry.done.store(true, .release);
            }
            fn finish(entry: *Entry, allocator: std.mem.Allocator, deliver: bool) !void {
                const self: *@This() = @fieldParentPtr("entry", entry);
                defer allocator.destroy(self);
                defer if (@hasDecl(Job, "deinit")) self.job.deinit(allocator);
                // The callback borrows output. Disposal also runs after a
                // callback error, canceled delivery and application shutdown.
                defer if (self.result) |output| self.job.discard(output) else |_| {};
                if (deliver) {
                    const result: anyerror!Job.Output = if (entry.cancellation.isCanceled()) error.Canceled else self.result;
                    try self.job.complete(result);
                }
            }
        };
        const box = try queue.allocator.create(Box);
        errdefer queue.allocator.destroy(box);
        box.* = .{ .job = job };
        box.entry.thread = try std.Thread.spawn(.{}, Box.work, .{box});
        queue.slots.items[index.?].entry = &box.entry;
        return .{ .queue = queue.identity, .slot = index.?, .generation = queue.slots.items[index.?].generation };
    }
    pub fn cancel(queue: *Queue, handle: Handle) !void {
        try queue.check();
        const entry = try queue.resolve(handle);
        entry.cancellation.canceled.store(true, .release);
    }
    pub fn contains(queue: *Queue, handle: Handle) bool {
        queue.check() catch return false;
        _ = queue.resolve(handle) catch return false;
        return true;
    }
    fn resolve(queue: *Queue, handle: Handle) !*Entry {
        if (handle.queue != queue.identity) return error.WrongTaskQueue;
        if (handle.slot >= queue.slots.items.len) return error.TaskNotFound;
        const slot = queue.slots.items[handle.slot];
        if (slot.generation != handle.generation) return error.TaskNotFound;
        return slot.entry orelse error.TaskNotFound;
    }
    /// Delivers jobs complete at the start of their scan. A callback may spawn
    /// more jobs; those jobs can be delivered on a later drain. A callback error
    /// stops this drain after releasing that job; remaining jobs stay queued.
    pub fn drain(queue: *Queue) !usize {
        try queue.check();
        if (queue.draining) return error.TaskDrainActive;
        queue.draining = true;
        defer queue.draining = false;
        const limit = queue.slots.items.len;
        var count: usize = 0;
        for (0..limit) |index| {
            const entry = queue.slots.items[index].entry orelse continue;
            if (!entry.done.load(.acquire)) continue;
            entry.thread.?.join();
            queue.slots.items[index].entry = null;
            if (queue.slots.items[index].generation == std.math.maxInt(u32)) queue.slots.items[index].retired = true else queue.slots.items[index].generation += 1;
            count += 1;
            try entry.finish(entry, queue.allocator, true);
        }
        return count;
    }
    pub fn pending(queue: *const Queue) bool {
        std.debug.assert(queue.owner == std.Thread.getCurrentId());
        for (queue.slots.items) |slot| if (slot.entry != null) return true;
        return false;
    }
};
