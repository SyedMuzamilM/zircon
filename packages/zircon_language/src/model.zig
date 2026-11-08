//! Owned messages and UTF-16 protocol coordinates. The editor validates source
//! revision and converts these coordinates against its exact retained snapshot.
const std = @import("std");
const text = @import("zircon_text");
pub const Position = struct { line: usize, character: usize };
pub const Range = struct { start: Position, end: Position };
pub const Diagnostic = struct { range: Range, severity: enum { error_value, warning, information, hint } = .error_value, message: []const u8, source: ?[]const u8 = null };
pub const TextEdit = struct { range: Range, new_text: []const u8 };
pub const Location = struct { uri: []const u8, range: Range };
pub const LocationsKind = enum { definition, references };
pub const FileEdits = struct { uri: []const u8, edits: []const TextEdit, version: ?u64 = null };
pub const CodeAction = struct { title: []const u8, files: []const FileEdits, disabled_reason: ?[]const u8 = null };
pub const Completion = struct { label: []const u8, insert_text: []const u8, detail: ?[]const u8 = null, text_edit: ?TextEdit = null, additional_edits: []const TextEdit = &.{}, snippet: bool = false };
pub const Message = struct {
    arena: std.heap.ArenaAllocator,
    data: union(enum) {
        initialized,
        diagnostics: struct { uri: []const u8, version: ?u64, items: []const Diagnostic },
        completion: struct { id: u64, uri: []const u8, version: u64, items: []const Completion, incomplete: bool = false },
        hover: struct { id: u64, uri: []const u8, version: u64, contents: []const u8 },
        locations: struct { id: u64, uri: []const u8, version: u64, kind: LocationsKind, items: []const Location },
        workspace_edit: struct { id: u64, uri: []const u8, version: u64, files: []const FileEdits },
        edits: struct { id: u64, uri: []const u8, version: u64, items: []const TextEdit },
        signature_help: struct { id: u64, uri: []const u8, version: u64, contents: []const u8 },
        code_actions: struct { id: u64, uri: []const u8, version: u64, items: []const CodeAction },
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
    if (!snapshot.isBoundary(offset)) return error.InvalidOffset;
    if (offset > 0 and offset < snapshot.byteLen() and (try snapshot.byteAt(offset - 1)) == '\r' and (try snapshot.byteAt(offset)) == '\n') return error.InvalidPosition;
    if (!snapshot.hasBareCarriageReturn()) {
        const point = try snapshot.pointAt(offset);
        const start = try snapshot.lineStart(point.line);
        return .{ .line = point.line, .character = (try snapshot.utf16Offset(offset)) - (try snapshot.utf16Offset(start)) };
    }
    var result: Position = .{ .line = 0, .character = 0 };
    var previous_cr = false;
    var chunks = try snapshot.chunks(.{ .start = 0, .end = offset });
    while (chunks.next()) |part| for (part) |byte| {
        if (byte == '\r' or byte == '\n') {
            if (byte != '\n' or !previous_cr) result.line += 1;
            result.character = 0;
        } else if (byte & 0xc0 != 0x80) result.character += if (byte >= 0xf0) @as(usize, 2) else 1;
        previous_cr = byte == '\r';
    };
    return result;
}
pub fn offsetAt(snapshot: text.Snapshot, position: Position) !usize {
    var line: text.Range = undefined;
    if (!snapshot.hasBareCarriageReturn()) {
        line = try snapshot.lineRange(position.line);
    } else {
        var row: usize = 0;
        var at: usize = 0;
        var start: usize = 0;
        var end: ?usize = null;
        var previous_cr = false;
        var chunks = try snapshot.chunks(.{ .start = 0, .end = snapshot.byteLen() });
        outer: while (chunks.next()) |part| for (part) |byte| {
            defer at += 1;
            if (byte == '\n' and previous_cr) {
                start = at + 1;
                previous_cr = false;
                continue;
            }
            if (byte == '\r' or byte == '\n') {
                if (row == position.line) {
                    end = at;
                    break :outer;
                }
                row += 1;
                start = at + 1;
            }
            previous_cr = byte == '\r';
        };
        if (row != position.line) return error.InvalidPosition;
        line = .{ .start = start, .end = end orelse snapshot.byteLen() };
    }
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

/// Local file URIs accept uppercase and lowercase percent escapes.
pub fn filePath(a: std.mem.Allocator, uri: []const u8) ![]u8 {
    if (!std.mem.startsWith(u8, uri, "file://")) return error.UnsupportedLocationUri;
    var encoded = uri[7..];
    if (std.mem.startsWith(u8, encoded, "localhost/")) encoded = encoded[9..];
    if (encoded.len == 0 or encoded[0] != '/') return error.InvalidFileUri;
    var path: std.ArrayList(u8) = .empty;
    errdefer path.deinit(a);
    var i: usize = 0;
    while (i < encoded.len) : (i += 1) {
        const byte = if (encoded[i] == '%') blk: {
            if (i + 2 >= encoded.len) return error.InvalidFileUri;
            const hi = std.fmt.charToDigit(encoded[i + 1], 16) catch return error.InvalidFileUri;
            const lo = std.fmt.charToDigit(encoded[i + 2], 16) catch return error.InvalidFileUri;
            i += 2;
            break :blk hi * 16 + lo;
        } else encoded[i];
        if (byte == 0 or encoded[i] == '?' or encoded[i] == '#') return error.InvalidFileUri;
        try path.append(a, byte);
    }
    if (!std.unicode.utf8ValidateSlice(path.items)) return error.InvalidFileUri;
    return path.toOwnedSlice(a);
}
