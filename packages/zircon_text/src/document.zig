//! Transactional document edits. Validation and candidate allocation complete
//! before current text, revision, state identity or history are changed.
const std = @import("std");
const rope = @import("rope.zig");
const history = @import("history.zig");
const types = @import("types.zig");
const Snapshot = @import("snapshot.zig").Snapshot;
pub const Mapping = struct { range: types.Range, inserted: usize };
pub const Change = struct {
    allocator: std.mem.Allocator,
    before: u64,
    after: u64,
    state: u64,
    mappings: []const Mapping,
    pub fn deinit(self: *Change) void {
        self.allocator.free(self.mappings);
        self.* = undefined;
    }
    pub fn map(self: *const Change, offset: usize, affinity: types.Affinity) usize {
        var mapped = offset;
        for (self.mappings) |edit| {
            if (offset < edit.range.start) break;
            const removed = edit.range.end - edit.range.start;
            if (offset > edit.range.end or (offset == edit.range.end and removed > 0)) {
                mapped = mapped - removed + edit.inserted;
                continue;
            }
            const start = mapped - (offset - edit.range.start);
            return start + if (affinity == .after) edit.inserted else @as(usize, 0);
        }
        return mapped;
    }
};
pub const Document = struct {
    allocator: std.mem.Allocator,
    root: ?*rope.Node,
    owner: std.Thread.Id,
    revision_value: u64 = 0,
    state_value: u64 = 1,
    next_state: u64 = 2,
    history: history.History = .{},
    pub fn init(a: std.mem.Allocator, bytes: []const u8) !Document {
        if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
        return .{ .allocator = a, .root = try rope.fromBytes(a, bytes), .owner = std.Thread.getCurrentId() };
    }
    fn check(self: *const Document) void {
        std.debug.assert(self.owner == std.Thread.getCurrentId());
    }
    pub fn deinit(self: *Document) void {
        self.check();
        rope.release(self.allocator, self.root);
        self.history.deinit(self.allocator);
        self.* = undefined;
    }
    pub fn snapshot(self: *const Document) Snapshot {
        self.check();
        return .{ .allocator = self.allocator, .root = rope.retain(self.root), .revision_value = self.revision_value, .state_value = self.state_value, .owner = self.owner };
    }
    pub fn revision(self: *const Document) u64 {
        self.check();
        return self.revision_value;
    }
    pub fn stateId(self: *const Document) u64 {
        self.check();
        return self.state_value;
    }
    pub fn breakHistoryGroup(self: *Document) void {
        self.check();
        self.history.last_group = 0;
    }
    pub fn setHistoryLimit(self: *Document, limit: usize) void {
        self.check();
        self.history.limit = limit;
        while (self.history.backward.items.len > limit) {
            const old = self.history.backward.orderedRemove(0);
            rope.release(self.allocator, old.root);
        }
        // The combined retained entry count is bounded, including redo states.
        while (self.history.forward.items.len + self.history.backward.items.len > limit and self.history.forward.items.len > 0) {
            const old = self.history.forward.orderedRemove(0);
            rope.release(self.allocator, old.root);
        }
        self.history.last_group = 0;
    }
    pub fn apply(self: *Document, expected: u64, edits: []const types.Edit, group: u64) !Change {
        self.check();
        if (expected != self.revision_value) return error.StaleRevision;
        var source = self.snapshot();
        defer source.deinit();
        var size = source.byteLen();
        var count: usize = 0;
        for (edits, 0..) |edit, i| {
            try source.validateRange(edit.range);
            if (!std.unicode.utf8ValidateSlice(edit.text)) return error.InvalidUtf8;
            if (i > 0) {
                const previous = edits[i - 1].range;
                if (edit.range.start < previous.end or edit.range.start == previous.start) return error.OverlappingEdits;
            }
            const removed = edit.range.end - edit.range.start;
            size = std.math.add(usize, size - removed, edit.text.len) catch return error.DocumentTooLarge;
            if (!sameText(source, edit)) count += 1;
        }
        if (count == 0) return .{ .allocator = self.allocator, .before = self.revision_value, .after = self.revision_value, .state = self.state_value, .mappings = &.{} };
        if (self.revision_value == std.math.maxInt(u64)) return error.RevisionExhausted;
        if (self.next_state == std.math.maxInt(u64)) return error.StateIdentityExhausted;
        const mappings = try self.allocator.alloc(Mapping, count);
        errdefer self.allocator.free(mappings);
        var m: usize = 0;
        for (edits) |edit| if (!sameText(source, edit)) {
            mappings[m] = .{ .range = edit.range, .inserted = edit.text.len };
            m += 1;
        };
        try self.history.prepareEdit(self.allocator, group);
        var candidate = rope.retain(self.root);
        errdefer rope.release(self.allocator, candidate);
        var i = edits.len;
        while (i > 0) {
            i -= 1;
            const edit = edits[i];
            if (sameText(source, edit)) continue;
            const next = try rope.replace(self.allocator, candidate, edit.range.start, edit.range.end, edit.text);
            rope.release(self.allocator, candidate);
            candidate = next;
        }
        std.debug.assert(rope.summary(candidate).bytes == size);
        self.history.commitEdit(self.allocator, .{ .root = self.root, .id = self.state_value }, group);
        const before = self.revision_value;
        self.root = candidate;
        self.revision_value += 1;
        self.state_value = self.next_state;
        self.next_state += 1;
        return .{ .allocator = self.allocator, .before = before, .after = self.revision_value, .state = self.state_value, .mappings = mappings };
    }
    pub fn undo(self: *Document) !bool {
        self.check();
        if (self.history.backward.items.len == 0) return false;
        if (self.revision_value == std.math.maxInt(u64)) return error.RevisionExhausted;
        const previous = (try self.history.undo(self.allocator, .{ .root = self.root, .id = self.state_value })).?;
        self.root = previous.root;
        self.state_value = previous.id;
        self.revision_value += 1;
        return true;
    }
    pub fn redo(self: *Document) !bool {
        self.check();
        if (self.history.forward.items.len == 0) return false;
        if (self.revision_value == std.math.maxInt(u64)) return error.RevisionExhausted;
        const next = (try self.history.redo(self.allocator, .{ .root = self.root, .id = self.state_value })).?;
        self.root = next.root;
        self.state_value = next.id;
        self.revision_value += 1;
        return true;
    }
};
fn sameText(snapshot: Snapshot, edit: types.Edit) bool {
    if (edit.range.end - edit.range.start != edit.text.len) return false;
    var iterator = snapshot.chunks(edit.range) catch unreachable;
    var offset: usize = 0;
    while (iterator.next()) |part| {
        if (!std.mem.eql(u8, part, edit.text[offset..][0..part.len])) return false;
        offset += part.len;
    }
    return true;
}
