//! Owned messages and UTF-16 protocol coordinates. The editor validates source
//! revision and converts these coordinates against its exact retained snapshot.
const std = @import("std");
const text = @import("zircon_text");
pub const Position = struct { line: usize, character: usize };
pub const Range = struct { start: Position, end: Position };
pub const Diagnostic = struct { range: Range, severity: enum { error_value, warning, information, hint } = .error_value, message: []const u8, source: ?[]const u8 = null };
pub const TextEdit = struct { range: Range, new_text: []const u8 };
pub const Completion = struct { label: []const u8, insert_text: []const u8, detail: ?[]const u8 = null, text_edit: ?TextEdit = null, additional_edits: []const TextEdit = &.{}, snippet: bool = false };
pub const Message = struct {
    arena: std.heap.ArenaAllocator,
    data: union(enum) {
        initialized,
        diagnostics: struct { uri: []const u8, version: ?u64, items: []const Diagnostic },
        completion: struct { id: u64, uri: []const u8, version: u64, items: []const Completion, incomplete: bool = false },
        log: struct { message: []const u8, severity: u8 = 3 },
        failure: struct { message: []const u8, request_id: ?u64 = null },
        exited,
    },
    pub fn deinit(self: *Message) void {
        self.arena.deinit();
        self.* = undefined;
    }
};
pub fn deinitMessages(a: std.mem.Allocator, messages: []Message) void {
    for (messages) |*message| message.deinit();
    a.free(messages);
}
pub fn positionAt(snapshot: text.Snapshot, offset: usize) !Position {
    const point = try snapshot.pointAt(offset);
    const start = try snapshot.lineStart(point.line);
    return .{ .line = point.line, .character = (try snapshot.utf16Offset(offset)) - (try snapshot.utf16Offset(start)) };
}
pub fn offsetAt(snapshot: text.Snapshot, position: Position) !usize {
    const line = try snapshot.lineRange(position.line);
    const base = try snapshot.utf16Offset(line.start);
    const absolute = std.math.add(usize, base, position.character) catch return error.InvalidPosition;
    const at = try snapshot.byteOffsetFromUtf16(absolute);
    if (at > line.end) return error.InvalidPosition;
    return at;
}
pub fn fileUri(a: std.mem.Allocator, path: []const u8) ![]u8 {
    if (!std.fs.path.isAbsolute(path)) return error.ExpectedAbsolutePath;
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(a);
    try result.appendSlice(a, "file://");
    const digits = "0123456789ABCDEF";
    for (path) |byte| {
        if (std.ascii.isAlphanumeric(byte) or std.mem.indexOfScalar(u8, "/-._~:", byte) != null) try result.append(a, byte) else {
            try result.appendSlice(a, &.{ '%', digits[byte >> 4], digits[byte & 15] });
        }
    }
    return result.toOwnedSlice(a);
}
