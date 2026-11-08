//! Search inputs borrow immutable snapshots. Results own all strings/context.
const std = @import("std");
const text = @import("zircon_text");
const files_module = @import("files.zig");
pub const Query = struct { text: []const u8, case_sensitive: bool = true, whole_word: bool = false };
pub const Buffer = struct { document_id: u64, path: ?[]const u8 = null, title: []const u8, snapshot: text.Snapshot };
pub const Limits = struct {
    file_bytes: usize = 8 * 1024 * 1024,
    total_bytes: usize = 128 * 1024 * 1024,
    matches: usize = 10_000,
    sources: usize = 20_000,
    context_lines: usize = 2,
    query_bytes: usize = 64 * 1024,
};
pub const Request = struct { generation: u64, query: Query, open_buffers: []const Buffer = &.{}, files: []const []const u8 = &.{}, limits: Limits = .{} };
pub const Cancellation = struct {
    context: ?*anyopaque = null,
    is_canceled: ?*const fn (?*anyopaque) bool = null,
    pub fn check(self: Cancellation) !void {
        if (self.is_canceled) |f| if (f(self.context)) return error.Canceled;
    }
};
pub const DiskStamp = struct { inode: std.Io.File.INode, size: u64, modified: i96, fingerprint: [32]u8 };
pub const Source = union(enum) {
    buffer: struct { document_id: u64, revision: u64, state: u64, path: ?[]const u8 },
    disk: struct { path: []const u8, stamp: DiskStamp },
};
pub const Match = struct { range: text.Range, line: usize, column: usize };
pub const Excerpt = struct {
    start_line: usize,
    end_line: usize,
    source_range: text.Range,
    bytes: []const u8,
    /// Match ranges relative to bytes, retaining their exact UTF-8 boundaries.
    match_ranges: []const text.Range,
};
pub const Group = struct {
    source: Source,
    title: []const u8,
    matches: []const Match,
    excerpts: []const Excerpt,
    pub fn isCurrentBuffer(self: Group, document_id: u64, snapshot: text.Snapshot) bool {
        return self.source == .buffer and self.source.buffer.document_id == document_id and self.source.buffer.revision == snapshot.revision() and self.source.buffer.state == snapshot.stateId();
    }
    pub fn isCurrentDisk(self: Group, io: std.Io) !bool {
        if (self.source != .disk) return false;
        return files_module.isCurrent(io, self.source.disk.path, self.source.disk.stamp);
    }
    pub fn path(self: Group) ?[]const u8 {
        return switch (self.source) {
            .buffer => |b| b.path,
            .disk => |d| d.path,
        };
    }
};
pub const SourceError = struct { source: []const u8, reason: anyerror };
pub const Results = struct {
    arena: std.heap.ArenaAllocator,
    generation: u64,
    groups: []const Group,
    errors: []const SourceError,
    truncated: bool,
    total_matches: usize,
    searched_bytes: usize,
    searched_sources: usize,
    pub fn deinit(self: *Results) void {
        self.arena.deinit();
        self.* = undefined;
    }
};
