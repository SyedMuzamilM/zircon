//! History owns content-state roots, not revisions. A revision is monotonic;
//! undo restores an old state identity so saved-state comparison stays exact.
const std = @import("std");
const rope = @import("rope.zig");
pub const State = struct { root: ?*rope.Node, id: u64 };
pub const History = struct {
    backward: std.ArrayList(State) = .empty,
    forward: std.ArrayList(State) = .empty,
    limit: usize = 512,
    last_group: u64 = 0,
    pub fn deinit(self: *History, a: std.mem.Allocator) void {
        self.clearForward(a);
        for (self.backward.items) |state| rope.release(a, state.root);
        self.backward.deinit(a);
        self.forward.deinit(a);
    }
    pub fn prepareEdit(self: *History, a: std.mem.Allocator, group: u64) !void {
        if (!self.coalesces(group) and self.limit > 0) try self.backward.ensureUnusedCapacity(a, 1);
    }
    fn coalesces(self: *const History, group: u64) bool {
        return group != 0 and self.last_group == group and self.forward.items.len == 0 and self.backward.items.len > 0;
    }
    /// Takes ownership of old.root; all allocation happened in prepareEdit.
    pub fn commitEdit(self: *History, a: std.mem.Allocator, old: State, group: u64) void {
        if (self.coalesces(group) or self.limit == 0) rope.release(a, old.root) else self.backward.appendAssumeCapacity(old);
        self.clearForward(a);
        self.last_group = group;
        while (self.backward.items.len > self.limit) {
            const oldest = self.backward.orderedRemove(0);
            rope.release(a, oldest.root);
        }
    }
    fn clearForward(self: *History, a: std.mem.Allocator) void {
        for (self.forward.items) |state| rope.release(a, state.root);
        self.forward.clearRetainingCapacity();
    }
    /// Returns a transferred root after preparing the reverse stack. Failure
    /// leaves both stacks and the caller's current root unchanged.
    pub fn undo(self: *History, a: std.mem.Allocator, current: State) !?State {
        if (self.backward.items.len == 0) return null;
        try self.forward.ensureUnusedCapacity(a, 1);
        const previous = self.backward.pop().?;
        self.forward.appendAssumeCapacity(current);
        self.last_group = 0;
        return previous;
    }
    pub fn redo(self: *History, a: std.mem.Allocator, current: State) !?State {
        if (self.forward.items.len == 0) return null;
        try self.backward.ensureUnusedCapacity(a, 1);
        const next = self.forward.pop().?;
        self.backward.appendAssumeCapacity(current);
        self.last_group = 0;
        return next;
    }
};
