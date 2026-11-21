//! Multi-buffer/project literal search. Open snapshots override disk files;
//! outputs retain source identities so UI activation can refuse stale offsets.
const std = @import("std");
const text = @import("zircon_text");
const excerpts = @import("excerpts.zig");
const files = @import("files.zig");
const matcher_module = @import("matcher.zig");
const types = @import("types.zig");
const Matcher = matcher_module.Matcher;
pub const Query = types.Query;
pub const Buffer = types.Buffer;
pub const Limits = types.Limits;
pub const Request = types.Request;
pub const Cancellation = types.Cancellation;
pub const DiskStamp = types.DiskStamp;
pub const Source = types.Source;
pub const Match = types.Match;
pub const Excerpt = types.Excerpt;
pub const Group = types.Group;
pub const SourceError = types.SourceError;
pub const Results = types.Results;
pub fn search(allocator: std.mem.Allocator, io: std.Io, request: Request, cancel: Cancellation) !Results {
    try cancel.check();
    if (request.query.text.len == 0 or request.query.text.len > request.limits.query_bytes or !std.unicode.utf8ValidateSlice(request.query.text)) return error.InvalidQuery;
    if (request.limits.file_bytes == 0 or request.limits.total_bytes == 0 or request.limits.sources == 0 or request.limits.matches == 0) return error.InvalidLimits;
    var result: Results = .{ .arena = .init(allocator), .generation = request.generation, .groups = &.{}, .errors = &.{}, .truncated = false, .total_matches = 0, .searched_bytes = 0, .searched_sources = 0 };
    errdefer result.deinit();
    const a = result.arena.allocator();
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const scratch_a = scratch.allocator();
    var bookkeeping = std.heap.ArenaAllocator.init(allocator);
    defer bookkeeping.deinit();
    const keys = bookkeeping.allocator();
    const matcher = try Matcher.init(keys, request.query);
    const cwd = try std.process.currentPathAlloc(io, keys);
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var ids: std.AutoHashMapUnmanaged(u64, void) = .empty;
    var groups: std.ArrayList(Group) = .empty;
    var errors: std.ArrayList(SourceError) = .empty;
    var examined: usize = 0;
    for (request.open_buffers) |buffer| {
        try cancel.check();
        if (examined >= request.limits.sources) {
            result.truncated = true;
            break;
        }
        examined += 1;
        if (ids.contains(buffer.document_id)) continue;
        try ids.put(keys, buffer.document_id, {});
        _ = scratch.reset(.retain_capacity);
        const path = if (buffer.path) |p| files.canonical(scratch_a, io, cwd, p) catch |err| {
            if (err == error.OutOfMemory) return err;
            try addError(a, &errors, p, err);
            continue;
        } else null;
        if (path) |p| {
            if (seen.contains(p)) continue;
            try seen.put(keys, try keys.dupe(u8, p), {});
        }
        if (!try budget(a, &result, &errors, buffer.title, buffer.snapshot.byteLen(), request.limits)) continue;
        const found = try matcher.collect(a, buffer.snapshot, request.limits.matches - result.total_matches, cancel);
        result.truncated = result.truncated or found.truncated;
        result.total_matches += found.matches.len;
        if (found.matches.len > 0) try groups.append(a, .{ .source = .{ .buffer = .{ .document_id = buffer.document_id, .revision = buffer.snapshot.revision(), .state = buffer.snapshot.stateId(), .path = if (path) |p| try a.dupe(u8, p) else null } }, .title = try a.dupe(u8, buffer.title), .matches = found.matches, .excerpts = try excerpts.build(a, buffer.snapshot, found.matches, request.limits.context_lines, cancel) });
        if (result.total_matches == request.limits.matches) {
            result.truncated = true;
            break;
        }
    }
    if (result.total_matches < request.limits.matches) for (request.files) |path_input| {
        try cancel.check();
        if (examined >= request.limits.sources) {
            result.truncated = true;
            break;
        }
        examined += 1;
        _ = scratch.reset(.retain_capacity);
        const path = files.canonical(scratch_a, io, cwd, path_input) catch |err| {
            if (err == error.OutOfMemory) return err;
            try addError(a, &errors, path_input, err);
            continue;
        };
        if (seen.contains(path)) continue;
        try seen.put(keys, try keys.dupe(u8, path), {});
        const remaining = request.limits.total_bytes - result.searched_bytes;
        if (remaining == 0) {
            result.truncated = true;
            try addError(a, &errors, path, error.SearchByteLimit);
            break;
        }
        const loaded = files.read(scratch_a, io, path, @min(request.limits.file_bytes, remaining), cancel) catch |err| {
            if (err == error.OutOfMemory or err == error.Canceled) return err;
            try addError(a, &errors, path, if (err == error.FileTooLarge and remaining < request.limits.file_bytes) error.SearchByteLimit else err);
            if (err == error.FileTooLarge) result.truncated = true;
            continue;
        };
        if (!try budget(a, &result, &errors, path, loaded.bytes.len, request.limits)) continue;
        if (!std.unicode.utf8ValidateSlice(loaded.bytes)) {
            try addError(a, &errors, path, error.InvalidUtf8);
            continue;
        }
        if (std.mem.indexOfScalar(u8, loaded.bytes, 0) != null) {
            try addError(a, &errors, path, error.BinaryFile);
            continue;
        }
        if (!try matcher.contains(loaded.bytes, cancel)) continue;
        var document = try text.Document.init(scratch_a, loaded.bytes);
        defer document.deinit();
        var snapshot = document.snapshot();
        defer snapshot.deinit();
        const found = try matcher.collect(a, snapshot, request.limits.matches - result.total_matches, cancel);
        result.truncated = result.truncated or found.truncated;
        result.total_matches += found.matches.len;
        if (found.matches.len > 0) try groups.append(a, .{ .source = .{ .disk = .{ .path = try a.dupe(u8, path), .stamp = loaded.stamp } }, .title = try a.dupe(u8, std.fs.path.basename(path)), .matches = found.matches, .excerpts = try excerpts.build(a, snapshot, found.matches, request.limits.context_lines, cancel) });
        if (result.total_matches == request.limits.matches) {
            result.truncated = true;
            break;
        }
    };
    std.mem.sort(Group, groups.items, {}, struct {
        fn less(_: void, x: Group, y: Group) bool {
            return std.ascii.orderIgnoreCase(x.path() orelse x.title, y.path() orelse y.title) == .lt;
        }
    }.less);
    result.groups = groups.items;
    result.errors = errors.items;
    try cancel.check();
    return result;
}
fn addError(a: std.mem.Allocator, errors: *std.ArrayList(SourceError), source: []const u8, err: anyerror) !void {
    try errors.append(a, .{ .source = try a.dupe(u8, source), .reason = err });
}
fn budget(a: std.mem.Allocator, result: *Results, errors: *std.ArrayList(SourceError), name: []const u8, size: usize, limits: Limits) !bool {
    if (size > limits.file_bytes) {
        result.truncated = true;
        try addError(a, errors, name, error.FileTooLarge);
        return false;
    }
    if (size > limits.total_bytes - result.searched_bytes) {
        result.truncated = true;
        try addError(a, errors, name, error.SearchByteLimit);
        return false;
    }
    result.searched_bytes += size;
    result.searched_sources += 1;
    return true;
}
