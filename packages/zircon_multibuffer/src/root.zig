//! Source-backed editable excerpts for Git, search and diagnostics views.
const std = @import("std");
const text = @import("zircon_text");
const workspace = @import("zircon_workspace");

pub const SourceId = workspace.DocumentId;
pub const Bias = enum { before, after };
pub const Anchor = struct { source: SourceId, offset: usize, bias: Bias = .after };
pub const ExcerptId = struct { value: u64, generation: u64 };
pub const Excerpt = struct { id: ExcerptId, source: SourceId, source_range: text.Range };
pub const ProjectedRange = struct { start: usize, end: usize };
pub const SourceEdit = struct { source: SourceId, range: text.Range, replacement: []const u8 };
pub const SourceSnapshot = struct { source: SourceId, revision: u64, snapshot: text.Snapshot };

const StoredSource = struct { id: SourceId, snapshot: text.Snapshot };
pub const ExcerptView = struct { value: Excerpt, projection_start: usize, projection_end: usize };

pub const MultiBuffer = struct {
    allocator: std.mem.Allocator,
    sources: std.ArrayList(StoredSource) = .empty,
    excerpts: std.ArrayList(ExcerptView) = .empty,
    next_excerpt: u64 = 1,
    generation: u64 = 1,
    separator: []const u8 = "\n",

    pub fn init(a: std.mem.Allocator) MultiBuffer {
        return .{ .allocator = a };
    }
    pub fn deinit(self: *MultiBuffer) void {
        for (self.sources.items) |*source| source.snapshot.deinit();
        self.sources.deinit(self.allocator);
        self.excerpts.deinit(self.allocator);
        self.* = undefined;
    }
    pub fn addSource(self: *MultiBuffer, id: SourceId, snapshot: text.Snapshot) !void {
        if (self.sourceIndex(id) != null) return error.SourceAlreadyPresent;
        try self.sources.append(self.allocator, .{ .id = id, .snapshot = snapshot.clone() });
        self.generation +%= 1;
    }
    pub fn removeSource(self: *MultiBuffer, id: SourceId) !void {
        const index = self.sourceIndex(id) orelse return error.SourceNotFound;
        var removed = self.sources.orderedRemove(index);
        removed.snapshot.deinit();
        var i: usize = self.excerpts.items.len;
        while (i > 0) {
            i -= 1;
            if (std.meta.eql(self.excerpts.items[i].value.source, id)) _ = self.excerpts.orderedRemove(i);
        }
        self.generation +%= 1;
    }
    pub fn setExcerpts(self: *MultiBuffer, source: SourceId, ranges: []const text.Range) !void {
        const stored = self.sourceFor(source) orelse return error.SourceNotFound;
        for (ranges) |range| try stored.snapshot.validateRange(range);
        var next: std.ArrayList(ExcerptView) = .empty;
        errdefer next.deinit(self.allocator);
        try next.ensureTotalCapacity(self.allocator, self.excerpts.items.len + ranges.len);
        for (self.excerpts.items) |excerpt| if (!std.meta.eql(excerpt.value.source, source)) next.appendAssumeCapacity(excerpt);
        for (ranges) |range| {
            const id = ExcerptId{ .value = self.next_excerpt, .generation = self.generation };
            self.next_excerpt +%= 1;
            next.appendAssumeCapacity(.{ .value = .{ .id = id, .source = source, .source_range = range }, .projection_start = 0, .projection_end = 0 });
        }
        self.excerpts.deinit(self.allocator);
        self.excerpts = next;
        self.generation +%= 1;
        self.reindex();
    }
    pub fn updateSource(self: *MultiBuffer, id: SourceId, change: *const text.Change, after: text.Snapshot) !void {
        const source = self.sourceFor(id) orelse return error.SourceNotFound;
        if (source.snapshot.revision() != change.before or after.revision() != change.after) return error.StaleSourceRevision;
        for (self.excerpts.items) |*excerpt| if (std.meta.eql(excerpt.value.source, id)) {
            excerpt.value.source_range.start = change.map(excerpt.value.source_range.start, .before);
            excerpt.value.source_range.end = change.map(excerpt.value.source_range.end, .after);
            try after.validateRange(excerpt.value.source_range);
        };
        var old = source.snapshot;
        source.snapshot = after.clone();
        old.deinit();
        self.generation +%= 1;
        self.reindex();
    }
    pub fn sourceAnchor(self: *const MultiBuffer, anchor: Anchor) !Anchor {
        const source = self.sourceConst(anchor.source) orelse return error.SourceNotFound;
        if (anchor.offset > source.snapshot.byteLen()) return error.InvalidAnchor;
        return anchor;
    }
    pub fn mapAnchor(self: *const MultiBuffer, anchor: Anchor, change: *const text.Change) !Anchor {
        _ = self.sourceConst(anchor.source) orelse return error.SourceNotFound;
        return .{ .source = anchor.source, .offset = change.map(anchor.offset, switch (anchor.bias) {
            .before => .before,
            .after => .after,
        }), .bias = anchor.bias };
    }
    pub fn read(self: *const MultiBuffer, a: std.mem.Allocator) ![]u8 {
        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(a);
        for (self.excerpts.items, 0..) |excerpt, index| {
            const source = self.sourceConst(excerpt.value.source) orelse return error.SourceNotFound;
            const bytes = try source.snapshot.copy(a, excerpt.value.source_range);
            defer a.free(bytes);
            try result.appendSlice(a, bytes);
            if (index + 1 < self.excerpts.items.len) try result.appendSlice(a, self.separator);
        }
        return result.toOwnedSlice(a);
    }
    pub fn projectedRange(self: *const MultiBuffer, id: ExcerptId) !ProjectedRange {
        for (self.excerpts.items) |excerpt| if (std.meta.eql(excerpt.value.id, id)) return .{ .start = excerpt.projection_start, .end = excerpt.projection_end };
        return error.ExcerptNotFound;
    }
    pub fn sourceRange(self: *const MultiBuffer, range: ProjectedRange) !struct { source: SourceId, range: text.Range } {
        if (range.start > range.end) return error.InvalidProjectedRange;
        for (self.excerpts.items) |excerpt| if (range.start >= excerpt.projection_start and range.end <= excerpt.projection_end) return .{ .source = excerpt.value.source, .range = .{ .start = excerpt.value.source_range.start + range.start - excerpt.projection_start, .end = excerpt.value.source_range.start + range.end - excerpt.projection_start } };
        return error.CrossExcerptEdit;
    }
    pub fn edit(self: *const MultiBuffer, range: ProjectedRange, replacement: []const u8) !SourceEdit {
        const mapped = try self.sourceRange(range);
        if (!std.unicode.utf8ValidateSlice(replacement)) return error.InvalidUtf8;
        return .{ .source = mapped.source, .range = mapped.range, .replacement = replacement };
    }
    pub fn excerptList(self: *const MultiBuffer) []const ExcerptView {
        return self.excerpts.items;
    }
    fn sourceIndex(self: *const MultiBuffer, id: SourceId) ?usize {
        for (self.sources.items, 0..) |source, i| if (std.meta.eql(source.id, id)) return i;
        return null;
    }
    fn sourceFor(self: *MultiBuffer, id: SourceId) ?*StoredSource {
        return if (self.sourceIndex(id)) |i| &self.sources.items[i] else null;
    }
    fn sourceConst(self: *const MultiBuffer, id: SourceId) ?*const StoredSource {
        return if (self.sourceIndex(id)) |i| &self.sources.items[i] else null;
    }
    fn reindex(self: *MultiBuffer) void {
        var offset: usize = 0;
        for (self.excerpts.items, 0..) |*excerpt, index| {
            const length = excerpt.value.source_range.end - excerpt.value.source_range.start;
            excerpt.projection_start = offset;
            excerpt.projection_end = offset + length;
            offset += length;
            if (index + 1 < self.excerpts.items.len) offset += self.separator.len;
        }
    }
};
