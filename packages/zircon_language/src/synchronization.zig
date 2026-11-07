//! Incremental ranges refer to the last enqueued snapshot. Reverse ordered
//! disjoint edits leave the coordinates of earlier ranges unchanged.
const std = @import("std");
const text = @import("zircon_text");
const model = @import("model.zig");
pub const Kind = enum { none, full, incremental };
pub const Options = struct {
    kind: Kind = .none,
    open_close: bool = false,
    pub fn parse(capabilities: std.json.Value) !Options {
        if (capabilities != .object) return error.InvalidInitializeResult;
        if (capabilities.object.get("positionEncoding")) |encoding| {
            if (encoding != .string or !std.mem.eql(u8, encoding.string, "utf-16")) return error.UnsupportedPositionEncoding;
        }
        const value = capabilities.object.get("textDocumentSync") orelse return .{};
        if (value == .null) return .{};
        if (value == .integer) {
            const kind = try parseKind(value);
            return .{ .kind = kind, .open_close = kind != .none };
        }
        if (value != .object) return error.InvalidSynchronizationOptions;
        var options: Options = .{};
        if (value.object.get("change")) |change| options.kind = try parseKind(change);
        if (value.object.get("openClose")) |open_close| {
            if (open_close != .bool) return error.InvalidSynchronizationOptions;
            options.open_close = open_close.bool;
        }
        return options;
    }
};
fn parseKind(value: std.json.Value) !Kind {
    if (value != .integer) return error.InvalidSynchronizationOptions;
    return switch (value.integer) {
        0 => .none,
        1 => .full,
        2 => .incremental,
        else => error.InvalidSynchronizationOptions,
    };
}
pub const ContentChange = struct { range: model.Range, text: []const u8 };
pub fn replacement(a: std.mem.Allocator, before: text.Snapshot, after: text.Snapshot) ![]ContentChange {
    const changes = try a.alloc(ContentChange, 1);
    changes[0] = .{ .range = .{ .start = .{ .line = 0, .character = 0 }, .end = try model.positionAt(before, before.byteLen()) }, .text = try after.copy(a, .{ .start = 0, .end = after.byteLen() }) };
    return changes;
}
fn splitsLineEnding(snapshot: text.Snapshot, offset: usize) bool {
    return offset > 0 and offset < snapshot.byteLen() and (snapshot.byteAt(offset - 1) catch unreachable) == '\r' and (snapshot.byteAt(offset) catch unreachable) == '\n';
}
/// The supplied allocator owns the changes and text; callers use a scratch arena.
pub fn edits(a: std.mem.Allocator, before: text.Snapshot, after: text.Snapshot, mappings: []const text.Mapping) ![]ContentChange {
    if (mappings.len == 0) return replacement(a, before, after);
    const changes = try a.alloc(ContentChange, mappings.len);
    var old_end: usize = 0;
    var new_end: usize = 0;
    for (mappings, 0..) |mapping, index| {
        try before.validateRange(mapping.range);
        if (mapping.range.start < old_end or (index > 0 and mapping.range.start == mappings[index - 1].range.start)) return error.InvalidChangeMappings;
        const start = std.math.add(usize, new_end, mapping.range.start - old_end) catch return error.InvalidChangeMappings;
        const end = std.math.add(usize, start, mapping.inserted) catch return error.InvalidChangeMappings;
        try after.validateRange(.{ .start = start, .end = end });
        if (splitsLineEnding(before, mapping.range.start) or splitsLineEnding(before, mapping.range.end)) return replacement(a, before, after);
        changes[mappings.len - 1 - index] = .{ .range = .{ .start = try model.positionAt(before, mapping.range.start), .end = try model.positionAt(before, mapping.range.end) }, .text = try after.copy(a, .{ .start = start, .end = end }) };
        old_end = mapping.range.end;
        new_end = end;
    }
    if (before.byteLen() - old_end != after.byteLen() - new_end) return error.InvalidChangeMappings;
    return changes;
}
