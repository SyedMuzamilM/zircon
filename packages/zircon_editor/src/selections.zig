//! UTF-8 byte selections. Normalize before batch edits so overlapping cursors
//! cannot edit a range twice. The first normalized selection is primary.
const std = @import("std");
const text = @import("zircon_text");
pub const Selection = struct {
    anchor: usize,
    head: usize,
    pub fn range(self: Selection) text.Range {
        return .{ .start = @min(self.anchor, self.head), .end = @max(self.anchor, self.head) };
    }
    pub fn empty(self: Selection) bool {
        return self.anchor == self.head;
    }
};
pub const Set = struct {
    items: std.ArrayList(Selection) = .empty,
    pub fn init(a: std.mem.Allocator) !Set {
        var self: Set = .{};
        try self.items.append(a, .{ .anchor = 0, .head = 0 });
        return self;
    }
    pub fn deinit(self: *Set, a: std.mem.Allocator) void {
        self.items.deinit(a);
    }
    pub fn primary(self: *const Set) Selection {
        return self.items.items[0];
    }
    pub fn single(self: *Set, selection: Selection) void {
        self.items.items[0] = selection;
        self.items.items.len = 1;
    }
    pub fn normalize(self: *Set) void {
        std.mem.sort(Selection, self.items.items, {}, less);
        var count: usize = 0;
        for (self.items.items) |selection| {
            if (count > 0) {
                const last = &self.items.items[count - 1];
                if (selection.range().start <= last.range().end) {
                    last.* = .{ .anchor = @min(last.range().start, selection.range().start), .head = @max(last.range().end, selection.range().end) };
                    continue;
                }
            }
            self.items.items[count] = selection;
            count += 1;
        }
        self.items.items.len = count;
    }
    pub fn synchronize(self: *Set, snapshot: text.Snapshot) void {
        for (self.items.items) |*selection| {
            selection.anchor = clamp(snapshot, selection.anchor);
            selection.head = clamp(snapshot, selection.head);
        }
        self.normalize();
    }
    fn less(_: void, a: Selection, b: Selection) bool {
        return if (a.range().start == b.range().start) a.range().end < b.range().end else a.range().start < b.range().start;
    }
};
fn clamp(snapshot: text.Snapshot, offset: usize) usize {
    var result = @min(offset, snapshot.byteLen());
    while (!snapshot.isBoundary(result)) result -= 1;
    return result;
}
