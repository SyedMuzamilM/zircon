//! Multi-source edits retain source history identities and exact inverse maps.
const std = @import("std");
const text = @import("zircon_text");
const workspace = @import("zircon_workspace");
const multi = @import("root.zig");
const Direction = text.Document.HistoryDirection;
const Target = struct {
    source: multi.SourceId,
    before: u64,
    after: u64,
    forward: []text.Mapping,
    backward: []text.Mapping,
};
const Entry = struct {
    targets: []Target,
    fn deinit(self: Entry, a: std.mem.Allocator) void {
        for (self.targets) |target| {
            a.free(target.forward);
            a.free(target.backward);
        }
        a.free(self.targets);
    }
};
pub const Applied = struct { source: multi.SourceId, change: text.Change };
pub const Batch = struct {
    allocator: std.mem.Allocator,
    items: []Applied,
    pub fn deinit(self: *Batch) void {
        for (self.items) |*item| item.change.deinit();
        self.allocator.free(self.items);
    }
};
pub const Transactions = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,
    limit: usize = 128,

    pub fn init(a: std.mem.Allocator) Transactions {
        return .{ .allocator = a };
    }
    pub fn deinit(self: *Transactions) void {
        for (self.entries.items) |entry| entry.deinit(self.allocator);
        self.entries.deinit(self.allocator);
    }

    pub fn apply(self: *Transactions, ws: *workspace.Workspace, edits: []const multi.SourceEdit) !Batch {
        const a = self.allocator;
        const Prepared = struct { source: multi.SourceId, edit: text.Document.PreparedEdit };
        var prepared: std.ArrayList(Prepared) = .empty;
        defer {
            for (prepared.items) |*item| item.edit.deinit();
            prepared.deinit(a);
        }
        var targets: std.ArrayList(Target) = .empty;
        errdefer {
            for (targets.items) |target| {
                a.free(target.forward);
                a.free(target.backward);
            }
            targets.deinit(a);
        }
        var source_edits: std.ArrayList(text.Edit) = .empty;
        defer source_edits.deinit(a);
        for (edits, 0..) |edit, index| {
            const seen = for (edits[0..index]) |previous| {
                if (std.meta.eql(previous.source, edit.source)) break true;
            } else false;
            if (seen) continue;
            const doc = &(try ws.get(edit.source)).doc;
            source_edits.clearRetainingCapacity();
            for (edits[index..]) |item| if (std.meta.eql(item.source, edit.source)) {
                if (item.source_revision != edit.source_revision) return error.StaleSourceRevision;
                try source_edits.append(a, .{ .range = item.range, .text = item.replacement });
            };
            std.mem.sort(text.Edit, source_edits.items, {}, less);
            // The same source may be visible in overlapping excerpts. Delete
            // their union once, while preserving the first insertion.
            var count: usize = 0;
            for (source_edits.items) |item| {
                if (count > 0 and item.range.start <= source_edits.items[count - 1].range.end) {
                    const last = &source_edits.items[count - 1];
                    if (last.text.len > 0 and item.text.len > 0) return error.OverlappingEdits;
                    if (item.text.len > 0) last.text = item.text;
                    last.range.end = @max(last.range.end, item.range.end);
                } else {
                    source_edits.items[count] = item;
                    count += 1;
                }
            }
            var candidate = try doc.prepare(edit.source_revision, source_edits.items[0..count], 0);
            errdefer candidate.deinit();
            if (!candidate.changed) {
                candidate.deinit();
                continue;
            }
            const forward = try a.dupe(text.Mapping, candidate.change.mappings);
            errdefer a.free(forward);
            const backward = try a.alloc(text.Mapping, forward.len);
            errdefer a.free(backward);
            var removed: usize = 0;
            var inserted: usize = 0;
            for (forward, backward) |mapping, *inverse| {
                const start = mapping.range.start - removed + inserted;
                inverse.* = .{ .range = .{ .start = start, .end = start + mapping.inserted }, .inserted = mapping.range.end - mapping.range.start };
                removed += inverse.inserted;
                inserted += mapping.inserted;
            }
            try prepared.ensureUnusedCapacity(a, 1);
            try targets.append(a, .{ .source = edit.source, .before = doc.stateId(), .after = candidate.change.state, .forward = forward, .backward = backward });
            prepared.appendAssumeCapacity(.{ .source = edit.source, .edit = candidate });
        }
        const applied = try a.alloc(Applied, prepared.items.len);
        errdefer a.free(applied);
        try self.entries.ensureUnusedCapacity(a, 1);
        const owned = try targets.toOwnedSlice(a);
        // No allocations or callbacks occur between the first and last commit.
        for (prepared.items, applied) |*item, *output| output.* = .{ .source = item.source, .change = item.edit.commit(item.edit.document) catch unreachable };
        if (owned.len > 0) self.entries.appendAssumeCapacity(.{ .targets = owned }) else a.free(owned);
        while (self.entries.items.len > self.limit) self.entries.orderedRemove(0).deinit(a);
        return .{ .allocator = a, .items = applied };
    }

    /// Only claim a history step when the initiating document is at a retained
    /// transaction boundary. Diverged peers stop the whole group before travel.
    pub fn travel(self: *Transactions, ws: *workspace.Workspace, source: multi.SourceId, direction: Direction) !?Batch {
        const doc = &(try ws.get(source)).doc;
        var index = self.entries.items.len;
        while (index > 0) {
            index -= 1;
            const entry = self.entries.items[index];
            const found = for (entry.targets) |target| {
                const from = if (direction == .undo) target.after else target.before;
                const to = if (direction == .undo) target.before else target.after;
                if (std.meta.eql(target.source, source) and doc.stateId() == from and doc.historyTarget(direction) == to) break true;
            } else false;
            if (!found) continue;
            return try self.travelEntry(ws, entry, direction);
        }
        return null;
    }

    fn travelEntry(self: *Transactions, ws: *workspace.Workspace, entry: Entry, direction: Direction) !Batch {
        const a = self.allocator;
        const prepared = try a.alloc(text.Document.PreparedHistory, entry.targets.len);
        defer a.free(prepared);
        const applied = try a.alloc(Applied, entry.targets.len);
        var count: usize = 0;
        errdefer {
            for (applied[0..count]) |*item| item.change.deinit();
            a.free(applied);
        }
        for (entry.targets, prepared, applied) |target, *step, *output| {
            const doc = &(ws.get(target.source) catch return error.HistoryDiverged).doc;
            const from = if (direction == .undo) target.after else target.before;
            const to = if (direction == .undo) target.before else target.after;
            if (doc.stateId() != from or doc.historyTarget(direction) != to) return error.HistoryDiverged;
            step.* = try doc.prepareHistory(direction, to);
            const mappings = try a.dupe(text.Mapping, if (direction == .undo) target.backward else target.forward);
            output.* = .{ .source = target.source, .change = .{ .allocator = a, .before = doc.revision(), .after = doc.revision() + 1, .state = to, .mappings = mappings } };
            count += 1;
        }
        for (prepared) |*step| step.commit() catch unreachable;
        return .{ .allocator = a, .items = applied };
    }
};

fn less(_: void, first: text.Edit, second: text.Edit) bool {
    return first.range.start < second.range.start;
}
