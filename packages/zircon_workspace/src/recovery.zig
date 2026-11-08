//! Process-crash checkpoints. A session lock has one owner; callers serialize
//! publish, exclude and discard. Immutable text is published before its index.
//! File sync is used, but this module does not promise power-loss durability.
const std = @import("std");
const permissions = @import("permissions.zig");
const persistence = @import("persistence.zig");
const DiskStamp = persistence.DiskStamp;
const max_index_bytes = 8 * 1024 * 1024;
const max_documents = 2048;
const max_session_bytes = 256 * 1024 * 1024;

pub const View = struct { anchor: usize = 0, head: usize = 0, scroll: f32 = 0, horizontal: f32 = 0 };
pub const ContentRef = struct { digest: [32]u8, bytes: usize };
pub const Content = struct { id: u64, bytes: []const u8 };
pub const Document = struct {
    id: u64,
    path: ?[]const u8 = null,
    untitled_name: []const u8 = "",
    dirty: bool = true,
    disk: ?DiskStamp = null,
    primary: bool = true,
    secondary: bool = false,
    view: View = .{},
    secondary_view: ?View = null,
    language_path: ?[]const u8 = null,
    language_name: ?[]const u8 = null,
    content: ?ContentRef = null,
};
pub const Index = struct {
    version: u32 = 1,
    next_document_id: u64 = 1,
    root: []const u8,
    documents: []const Document,
    active: ?u64 = null,
    secondary_active: ?u64 = null,
    focus_secondary: bool = false,
    split_vertical: bool = false,
    split_reverse: bool = false,
    split_ratio: f32 = 0.5,
};
pub const Loaded = struct {
    arena: std.heap.ArenaAllocator,
    index: Index,
    contents: []const Content,
    warnings: usize = 0,
    pub fn deinit(self: *Loaded) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub fn reference(bytes: []const u8) ContentRef {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return .{ .digest = digest, .bytes = bytes.len };
}

pub const Store = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []u8,
    root: []u8,
    lock: std.Io.File,

    /// Reuse the newest unlocked committed session. A live window's lock is
    /// never taken over, including when several windows open the same root.
    pub fn init(a: std.mem.Allocator, io: std.Io, home: []const u8, root: []const u8) !Store {
        return open(a, io, home, root, true);
    }
    /// Create a distinct session without consuming another window's abandoned
    /// backup. Use after discarding this window's prior session.
    pub fn initFresh(a: std.mem.Allocator, io: std.Io, home: []const u8, root: []const u8) !Store {
        return open(a, io, home, root, false);
    }
    fn open(a: std.mem.Allocator, io: std.Io, home: []const u8, root: []const u8, reuse_existing: bool) !Store {
        const root_digest = reference(root).digest;
        const hex = std.fmt.bytesToHex(root_digest, .lower);
        const project = try std.fs.path.join(a, &.{ home, &hex });
        defer a.free(project);
        _ = try std.Io.Dir.cwd().createDirPathStatus(io, project, permissions.dir(0o700));
        const dir = try std.Io.Dir.cwd().openDir(io, project, .{ .iterate = true });
        defer dir.close(io);
        const owned_root = try a.dupe(u8, root);
        errdefer a.free(owned_root);
        var selected_path: ?[]u8 = null;
        var selected_lock: ?std.Io.File = null;
        errdefer {
            if (selected_path) |path| a.free(path);
            if (selected_lock) |file| file.close(io);
        }
        var newest: i96 = std.math.minInt(i96);
        var iterator = dir.iterate();
        while (try iterator.next(io)) |entry| {
            if (!reuse_existing) break;
            if (entry.kind != .directory or !sessionName(entry.name)) continue;
            const session = try std.fs.path.join(a, &.{ project, entry.name });
            var keep = false;
            defer if (!keep) a.free(session);
            const session_dir = try std.Io.Dir.cwd().openDir(io, session, .{});
            defer session_dir.close(io);
            if (try exists(session_dir, io, "discarded")) continue;
            const stat = session_dir.statFile(io, "index.json", .{}) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => return err,
            };
            if (stat.kind != .file or stat.mtime.nanoseconds <= newest) continue;
            const file = session_dir.createFile(io, "lock", .{ .truncate = false, .lock = .exclusive, .lock_nonblocking = true, .permissions = permissions.file(0o600) }) catch |err| switch (err) {
                error.WouldBlock => continue,
                else => return err,
            };
            if (selected_lock) |old| old.close(io);
            if (selected_path) |old| a.free(old);
            selected_path = session;
            selected_lock = file;
            newest = stat.mtime.nanoseconds;
            keep = true;
        }
        if (selected_path) |path| return .{ .allocator = a, .io = io, .path = path, .root = owned_root, .lock = selected_lock.? };
        var random: [16]u8 = undefined;
        io.random(&random);
        const id = std.fmt.bytesToHex(random, .lower);
        const name = try std.fmt.allocPrint(a, "session-{s}", .{id});
        defer a.free(name);
        const path = try std.fs.path.join(a, &.{ project, name });
        errdefer a.free(path);
        try std.Io.Dir.cwd().createDir(io, path, permissions.dir(0o700));
        const fresh = try std.Io.Dir.cwd().openDir(io, path, .{});
        defer fresh.close(io);
        const file = try fresh.createFile(io, "lock", .{ .exclusive = true, .lock = .exclusive, .lock_nonblocking = true, .permissions = permissions.file(0o600) });
        return .{ .allocator = a, .io = io, .path = path, .root = owned_root, .lock = file };
    }
    pub fn deinit(self: *Store) void {
        self.lock.close(self.io);
        self.allocator.free(self.path);
        self.allocator.free(self.root);
        self.* = undefined;
    }
    /// Content may be omitted for unchanged documents carrying a prior
    /// ContentRef. No arbitrary filenames are accepted from persisted metadata.
    pub fn publish(self: *Store, a: std.mem.Allocator, index: Index, contents: []const Content) !void {
        try validateIndex(index, self.root);
        const dir = try std.Io.Dir.cwd().openDir(self.io, self.path, .{ .iterate = true });
        defer dir.close(self.io);
        if (try exists(dir, self.io, "discarded")) return error.RecoverySessionDiscarded;
        var documents: std.ArrayList(Document) = .empty;
        defer documents.deinit(a);
        var total: usize = 0;
        for (index.documents) |value| {
            var doc = value;
            var tombstone: [64]u8 = undefined;
            if (try exists(dir, self.io, try exclusionName(&tombstone, doc.id))) continue;
            var supplied: ?[]const u8 = null;
            for (contents) |content| if (content.id == doc.id) {
                if (supplied != null) return error.DuplicateRecoveryContent;
                supplied = content.bytes;
            };
            if (supplied) |bytes| {
                try validateText(bytes);
                const ref = reference(bytes);
                if (doc.content) |expected| if (!std.meta.eql(ref, expected)) return error.InvalidRecoveryContent;
                doc.content = ref;
            }
            const ref = doc.content orelse return error.MissingRecoveryContent;
            if (ref.bytes > persistence.max_file_bytes or ref.bytes > max_session_bytes - total) return error.RecoveryTooLarge;
            total += ref.bytes;
            var buffer: [128]u8 = undefined;
            const name = try contentName(&buffer, doc.id, ref);
            if (try exists(dir, self.io, name)) {
                if (supplied != null) {
                    _ = try readContent(a, self.io, dir, doc.id, ref, false);
                } else {
                    const stat = try dir.statFile(self.io, name, .{});
                    if (stat.kind != .file or stat.size != ref.bytes) return error.CorruptRecoveryContent;
                }
            } else if (supplied) |bytes| try atomicWrite(dir, self.io, name, bytes, false) else return error.MissingRecoveryContent;
            try documents.append(a, doc);
        }
        var published = index;
        published.documents = documents.items;
        for (index.documents) |doc| published.next_document_id = @max(published.next_document_id, doc.id + 1);
        const json = try std.json.Stringify.valueAlloc(a, published, .{});
        defer a.free(json);
        if (json.len > max_index_bytes) return error.RecoveryTooLarge;
        try atomicWrite(dir, self.io, "index.json", json, true);
        // Cleanup follows the commit. Failed cleanup cannot invalidate a backup.
        collect(dir, self.io, published.documents) catch {};
    }
    pub fn load(self: *Store, a: std.mem.Allocator) !?Loaded {
        const dir = try std.Io.Dir.cwd().openDir(self.io, self.path, .{});
        defer dir.close(self.io);
        if (try exists(dir, self.io, "discarded")) return null;
        var arena = std.heap.ArenaAllocator.init(a);
        errdefer arena.deinit();
        const aa = arena.allocator();
        const bytes = dir.readFileAlloc(self.io, "index.json", aa, .limited(max_index_bytes)) catch |err| switch (err) {
            error.FileNotFound => {
                arena.deinit();
                return null;
            },
            else => return err,
        };
        var index = std.json.parseFromSliceLeaky(Index, aa, bytes, .{ .allocate = .alloc_always }) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return self.corruptIndex(dir, bytes),
        };
        validateIndex(index, self.root) catch return self.corruptIndex(dir, bytes);
        // Excluded or corrupt documents still reserve their persistent IDs.
        for (index.documents) |doc| index.next_document_id = @max(index.next_document_id, doc.id + 1);
        var documents: std.ArrayList(Document) = .empty;
        var contents: std.ArrayList(Content) = .empty;
        var warnings: usize = 0;
        var total: usize = 0;
        for (index.documents) |doc| {
            var tombstone: [64]u8 = undefined;
            if (try exists(dir, self.io, try exclusionName(&tombstone, doc.id))) continue;
            const ref = doc.content orelse {
                warnings += 1;
                continue;
            };
            if (ref.bytes > persistence.max_file_bytes or ref.bytes > max_session_bytes - total) {
                warnings += 1;
                continue;
            }
            const content = readContent(aa, self.io, dir, doc.id, ref, true) catch |err| switch (err) {
                error.OutOfMemory, error.Canceled => return err,
                else => {
                    var marker: [64]u8 = undefined;
                    const name = try std.fmt.bufPrint(&marker, "corrupt-doc-{d}", .{doc.id});
                    // Retain the original raw bytes for manual salvage even if a
                    // later index omits this document after a partial restore.
                    try atomicWrite(dir, self.io, name, "corrupt\n", true);
                    warnings += 1;
                    continue;
                },
            };
            total += ref.bytes;
            try documents.append(aa, doc);
            try contents.append(aa, .{ .id = doc.id, .bytes = content.? });
        }
        index.documents = documents.items;
        return .{ .arena = arena, .index = index, .contents = contents.items, .warnings = warnings };
    }
    fn corruptIndex(self: *Store, dir: std.Io.Dir, bytes: []const u8) error{CorruptRecoveryIndex} {
        var random: [8]u8 = undefined;
        self.io.random(&random);
        var name_buffer: [80]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buffer, "corrupt-index-{s}.json", .{std.fmt.bytesToHex(random, .lower)}) catch unreachable;
        atomicWrite(dir, self.io, name, bytes, false) catch {};
        return error.CorruptRecoveryIndex;
    }
    /// Acknowledged discard is a durable process-crash exclusion. Callers join
    /// the outstanding writer before invoking this operation.
    pub fn exclude(self: *Store, id: u64) !void {
        const dir = try std.Io.Dir.cwd().openDir(self.io, self.path, .{});
        defer dir.close(self.io);
        var buffer: [64]u8 = undefined;
        try atomicWrite(dir, self.io, try exclusionName(&buffer, id), "discarded\n", true);
    }
    pub fn discard(self: *Store) !void {
        const dir = try std.Io.Dir.cwd().openDir(self.io, self.path, .{});
        defer dir.close(self.io);
        try atomicWrite(dir, self.io, "discarded", "discarded\n", true);
    }
};

fn collect(dir: std.Io.Dir, io: std.Io, documents: []const Document) !void {
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.startsWith(u8, entry.name, "doc-") or !std.mem.endsWith(u8, entry.name, ".text")) continue;
        const separator = std.mem.indexOfScalarPos(u8, entry.name, 4, '-') orelse continue;
        if (entry.name.len != separator + 1 + 64 + 5) continue;
        const id = std.fmt.parseInt(u64, entry.name[4..separator], 10) catch continue;
        var valid = true;
        for (entry.name[separator + 1 ..][0..64]) |char| if (!std.ascii.isHex(char)) {
            valid = false;
            break;
        };
        if (!valid) continue;
        var marker: [64]u8 = undefined;
        if (try exists(dir, io, try std.fmt.bufPrint(&marker, "corrupt-doc-{d}", .{id}))) continue;
        var referenced = false;
        for (documents) |doc| if (doc.id == id) {
            var buffer: [128]u8 = undefined;
            if (doc.content) |ref| referenced = std.mem.eql(u8, entry.name, try contentName(&buffer, id, ref));
            break;
        };
        if (!referenced) try dir.deleteFile(io, entry.name);
    }
}

fn sessionName(name: []const u8) bool {
    if (name.len != 40 or !std.mem.startsWith(u8, name, "session-")) return false;
    for (name[8..]) |char| if (!std.ascii.isHex(char)) return false;
    return true;
}
fn exclusionName(buffer: []u8, id: u64) ![]u8 {
    return std.fmt.bufPrint(buffer, "discard-doc-{d}", .{id});
}
fn contentName(buffer: []u8, id: u64, ref: ContentRef) ![]u8 {
    return std.fmt.bufPrint(buffer, "doc-{d}-{s}.text", .{ id, std.fmt.bytesToHex(ref.digest, .lower) });
}
fn exists(dir: std.Io.Dir, io: std.Io, name: []const u8) !bool {
    _ = dir.statFile(io, name, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}
fn atomicWrite(dir: std.Io.Dir, io: std.Io, name: []const u8, bytes: []const u8, replace: bool) !void {
    var atomic = try dir.createFileAtomic(io, name, .{ .replace = replace, .permissions = permissions.file(0o600) });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, bytes);
    try atomic.file.sync(io);
    if (replace) try atomic.replace(io) else try atomic.link(io);
}
fn readContent(a: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, id: u64, ref: ContentRef, keep: bool) !?[]u8 {
    var buffer: [128]u8 = undefined;
    const name = try contentName(&buffer, id, ref);
    const bytes = try dir.readFileAlloc(io, name, a, .limited(persistence.max_file_bytes));
    errdefer a.free(bytes);
    if (!std.meta.eql(reference(bytes), ref)) return error.CorruptRecoveryContent;
    try validateText(bytes);
    if (keep) return bytes;
    a.free(bytes);
    return null;
}
fn validString(value: []const u8) bool {
    return value.len <= 32 * 1024 and std.unicode.utf8ValidateSlice(value) and std.mem.indexOfScalar(u8, value, 0) == null;
}
fn validateIndex(index: Index, root: []const u8) !void {
    if (index.version != 1 or !std.mem.eql(u8, index.root, root) or index.documents.len > max_documents or !std.math.isFinite(index.split_ratio) or index.split_ratio < 0.1 or index.split_ratio > 0.9) return error.InvalidRecoveryIndex;
    for (index.documents, 0..) |doc, i| {
        if (doc.id == 0 or doc.id == std.math.maxInt(u64) or !validString(doc.untitled_name)) return error.InvalidRecoveryIndex;
        for (index.documents[0..i]) |previous| if (previous.id == doc.id) return error.InvalidRecoveryIndex;
        if (doc.path) |path| if (!validString(path) or !std.fs.path.isAbsolute(path)) return error.InvalidRecoveryIndex;
        if (doc.language_path) |path| if (!validString(path)) return error.InvalidRecoveryIndex;
        if (doc.language_name) |name| if (!validString(name)) return error.InvalidRecoveryIndex;
        try validateView(doc.view);
        if (doc.secondary_view) |view| try validateView(view);
    }
}
fn validateView(view: View) !void {
    if (!std.math.isFinite(view.scroll) or view.scroll < 0 or !std.math.isFinite(view.horizontal) or view.horizontal < 0) return error.InvalidRecoveryIndex;
}
fn validateText(bytes: []const u8) !void {
    if (bytes.len > persistence.max_file_bytes) return error.RecoveryTooLarge;
    if (!std.unicode.utf8ValidateSlice(bytes) or std.mem.indexOfScalar(u8, bytes, 0) != null) return error.InvalidRecoveryContent;
}
