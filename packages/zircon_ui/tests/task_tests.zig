const std = @import("std");
const tasks = @import("zircon_ui").tasks;
const t = std.testing;
const Log = struct {
    worker: ?std.Thread.Id = null,
    completion: ?std.Thread.Id = null,
    worker_finished: std.atomic.Value(bool) = .init(false),
    completed: usize = 0,
    discarded: usize = 0,
    released: usize = 0,
    canceled: bool = false,
    failure: ?anyerror = null,
    text: [16]u8 = @splat(0),
    length: usize = 0,
};
const Job = struct {
    pub const Output = []u8;
    log: *Log,
    mode: enum { success, wait_cancel, fail } = .success,
    completion_fails: bool = false,
    pub fn run(job: *Job, cancellation: *tasks.Cancellation) ![]u8 {
        job.log.worker = std.Thread.getCurrentId();
        defer job.log.worker_finished.store(true, .release);
        if (job.mode == .wait_cancel) {
            while (!cancellation.isCanceled()) std.atomic.spinLoopHint();
            try cancellation.check();
        }
        if (job.mode == .fail) return error.WorkRefused;
        return std.heap.page_allocator.dupe(u8, "worker result");
    }
    pub fn complete(job: *Job, result: anyerror![]u8) !void {
        job.log.completion = std.Thread.getCurrentId();
        job.log.completed += 1;
        if (result) |bytes| {
            @memcpy(job.log.text[0..bytes.len], bytes);
            job.log.length = bytes.len;
        } else |err| {
            job.log.failure = err;
            job.log.canceled = err == error.Canceled;
        }
        if (job.completion_fails) return error.CompletionRefused;
    }
    pub fn discard(job: *Job, output: []u8) void {
        job.log.discarded += 1;
        std.heap.page_allocator.free(output);
    }
    pub fn deinit(job: *Job, _: std.mem.Allocator) void {
        job.log.released += 1;
    }
};
fn finish(queue: *tasks.Queue) !void {
    while (queue.pending()) {
        _ = try queue.drain();
        std.atomic.spinLoopHint();
    }
}
fn workerFinished(log: *Log) void {
    while (!log.worker_finished.load(.acquire)) std.atomic.spinLoopHint();
}
test "background work runs off thread and completion borrows output on creator thread" {
    var queue = tasks.Queue.init(t.allocator);
    defer queue.deinit();
    var log: Log = .{};
    _ = try queue.spawn(Job, .{ .log = &log });
    try finish(&queue);
    try t.expect(log.worker.? != std.Thread.getCurrentId());
    try t.expectEqual(std.Thread.getCurrentId(), log.completion.?);
    try t.expectEqualStrings("worker result", log.text[0..log.length]);
    try t.expectEqual(@as(usize, 1), log.completed);
    try t.expectEqual(@as(usize, 1), log.discarded);
    try t.expectEqual(@as(usize, 1), log.released);
    try t.expect(!queue.pending());
    try t.expectEqual(@as(usize, 0), try queue.drain());
}
test "canceling completed work delivers cancellation and still disposes its result" {
    var queue = tasks.Queue.init(t.allocator);
    defer queue.deinit();
    var log: Log = .{};
    const handle = try queue.spawn(Job, .{ .log = &log });
    workerFinished(&log);
    try queue.cancel(handle);
    try queue.cancel(handle);
    try finish(&queue);
    try t.expect(log.canceled);
    try t.expectEqual(@as(usize, 1), log.completed);
    try t.expectEqual(@as(usize, 1), log.discarded);
    try t.expectEqual(@as(usize, 1), log.released);
    try t.expectError(error.TaskNotFound, queue.cancel(handle));
}
test "cooperative cancellation reaches a running worker" {
    var queue = tasks.Queue.init(t.allocator);
    defer queue.deinit();
    var log: Log = .{};
    const handle = try queue.spawn(Job, .{ .log = &log, .mode = .wait_cancel });
    try queue.cancel(handle);
    try finish(&queue);
    try t.expect(log.canceled);
    try t.expectEqual(@as(usize, 0), log.discarded);
    try t.expectEqual(@as(usize, 1), log.released);
}
test "worker errors and completion errors release job storage exactly once" {
    var queue = tasks.Queue.init(t.allocator);
    defer queue.deinit();
    var first: Log = .{};
    _ = try queue.spawn(Job, .{ .log = &first, .mode = .fail });
    try finish(&queue);
    try t.expectEqual(error.WorkRefused, first.failure.?);
    try t.expectEqual(@as(usize, 0), first.discarded);
    try t.expectEqual(@as(usize, 1), first.released);
    var second: Log = .{};
    _ = try queue.spawn(Job, .{ .log = &second, .completion_fails = true });
    workerFinished(&second);
    while (true) {
        _ = queue.drain() catch |err| {
            try t.expectEqual(error.CompletionRefused, err);
            break;
        };
        std.atomic.spinLoopHint();
    }
    try t.expect(!queue.pending());
    try t.expectEqual(@as(usize, 1), second.discarded);
    try t.expectEqual(@as(usize, 1), second.released);
}
test "shutdown cancels joins and discards without invoking UI completion" {
    var first: Log = .{};
    var second: Log = .{};
    var queue = tasks.Queue.init(t.allocator);
    _ = try queue.spawn(Job, .{ .log = &first });
    _ = try queue.spawn(Job, .{ .log = &second, .mode = .wait_cancel });
    queue.deinit();
    try t.expect(first.worker_finished.load(.acquire));
    try t.expect(second.worker_finished.load(.acquire));
    try t.expectEqual(@as(usize, 0), first.completed);
    try t.expectEqual(@as(usize, 0), second.completed);
    try t.expectEqual(@as(usize, 1), first.discarded);
    try t.expectEqual(@as(usize, 1), first.released);
    try t.expectEqual(@as(usize, 1), second.released);
}
test "task generations and queue identity reject stale foreign and cross-thread access" {
    var queue = tasks.Queue.init(t.allocator);
    defer queue.deinit();
    var other = tasks.Queue.init(t.allocator);
    defer other.deinit();
    var first: Log = .{};
    const old = try queue.spawn(Job, .{ .log = &first });
    try t.expectError(error.WrongTaskQueue, other.cancel(old));
    try finish(&queue);
    var second: Log = .{};
    const replacement = try queue.spawn(Job, .{ .log = &second });
    try t.expectEqual(old.slot, replacement.slot);
    try t.expect(old.generation != replacement.generation);
    try t.expectError(error.TaskNotFound, queue.cancel(old));
    const Probe = struct {
        fn run(target: *tasks.Queue, handle: tasks.Handle, refusal: *bool) void {
            target.cancel(handle) catch |err| {
                refusal.* = err == error.WrongThread;
            };
        }
    };
    var refused = false;
    const thread = try std.Thread.spawn(.{}, Probe.run, .{ &queue, replacement, &refused });
    thread.join();
    try t.expect(refused);
    try finish(&queue);
}
test "completion may enqueue follow-up work but cannot recursively drain" {
    var queue = tasks.Queue.init(t.allocator);
    defer queue.deinit();
    var log: Log = .{};
    var recursive_refused = false;
    const Chained = struct {
        pub const Output = void;
        queue: *tasks.Queue,
        log: *Log,
        refused: *bool,
        pub fn run(_: *@This(), _: *tasks.Cancellation) !void {}
        pub fn complete(job: *@This(), result: anyerror!void) !void {
            try result;
            _ = job.queue.drain() catch |err| {
                job.refused.* = err == error.TaskDrainActive;
            };
            _ = try job.queue.spawn(Job, .{ .log = job.log });
        }
        pub fn discard(_: *@This(), _: void) void {}
    };
    _ = try queue.spawn(Chained, .{ .queue = &queue, .log = &log, .refused = &recursive_refused });
    try finish(&queue);
    try t.expect(recursive_refused);
    try t.expectEqual(@as(usize, 1), log.completed);
}
test "allocation failure leaves caller-owned job intact and closes queued workers" {
    try t.checkAllAllocationFailures(t.allocator, allocationCase, .{});
}
fn allocationCase(a: std.mem.Allocator) !void {
    var queue = tasks.Queue.init(a);
    defer queue.deinit();
    var log: Log = .{};
    _ = try queue.spawn(Job, .{ .log = &log });
    try finish(&queue);
}
