//! Connects worker ownership to generational entities. Workers see only the job;
//! completion resolves the owner anew on the UI thread and borrows its output.
const std = @import("std");
const identities = @import("../entity/entity.zig");
const runtime = @import("app.zig");
const tasks = @import("tasks.zig");
const OwnerTask = struct { owner: identities.Token, handle: tasks.Handle };
pub const OwnedTasks = struct {
    queue: tasks.Queue,
    owners: std.ArrayList(OwnerTask) = .empty,
    pub fn init(a: std.mem.Allocator) OwnedTasks {
        return .{ .queue = .init(a) };
    }
    pub fn deinit(jobs: *OwnedTasks) void {
        const a = jobs.queue.allocator;
        jobs.queue.deinit();
        jobs.owners.deinit(a);
    }
    pub fn spawn(jobs: *OwnedTasks, app: *runtime.App, owner: anytype, comptime Job: type, job: Job, comptime callback: anytype) !tasks.Handle {
        _ = try app.rawVersion(owner.token());
        try jobs.owners.ensureUnusedCapacity(jobs.queue.allocator, 1);
        const Owner = @TypeOf(owner).State;
        const Bound = struct {
            pub const Output = Job.Output;
            app: runtime.App,
            owner: identities.Entity(Owner),
            job: Job,
            pub fn run(self: *@This(), cancel: *tasks.Cancellation) !Output {
                return self.job.run(cancel);
            }
            pub fn complete(self: *@This(), result: anyerror!Output) !void {
                if (!self.app.isAlive(self.owner.token())) return;
                try self.app.update(self.owner, deliver, .{result});
            }
            fn deliver(value: *Owner, cx: *runtime.Context(Owner), result: anyerror!Output) !void {
                return @call(.auto, callback, .{ value, cx, result });
            }
            pub fn discard(self: *@This(), result: Output) void {
                self.job.discard(result);
            }
            pub fn deinit(self: *@This(), a: std.mem.Allocator) void {
                if (@hasDecl(Job, "deinit")) self.job.deinit(a);
            }
        };
        const handle = try jobs.queue.spawn(Bound, .{ .app = app.*, .owner = owner, .job = job });
        jobs.owners.appendAssumeCapacity(.{ .owner = owner.token(), .handle = handle });
        return handle;
    }
    pub fn cancelDead(jobs: *OwnedTasks, app: *runtime.App) void {
        var i: usize = 0;
        while (i < jobs.owners.items.len) {
            const item = jobs.owners.items[i];
            if (!app.isAlive(item.owner)) jobs.queue.cancel(item.handle) catch |err| {
                if (err == error.TaskNotFound) {
                    _ = jobs.owners.swapRemove(i);
                    continue;
                }
            };
            i += 1;
        }
    }
    pub fn drain(jobs: *OwnedTasks, app: *runtime.App) !void {
        jobs.cancelDead(app);
        _ = try jobs.queue.drain();
        // Remove completed handle metadata without retaining dead windows/jobs.
        var i: usize = 0;
        while (i < jobs.owners.items.len) {
            if (!jobs.queue.contains(jobs.owners.items[i].handle)) {
                _ = jobs.owners.swapRemove(i);
                continue;
            }
            i += 1;
        }
    }
};
