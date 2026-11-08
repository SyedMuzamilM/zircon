//! Workspace identity and disk policy. Documents are heap-stable; returned
//! pointers are scoped to the caller's model operation and become invalid on
//! close. This package has no UI or native-window dependency.
const std = @import("std");
const text = @import("zircon_text");
pub const permissions = @import("permissions.zig");
const persistence = @import("persistence.zig");
pub const recovery = @import("recovery.zig");
const tree = @import("tree.zig");
pub const Entry = tree.Entry;
pub const deinitEntries = tree.deinitEntries;
pub const DiskStamp = persistence.DiskStamp;
pub const max_file_bytes = persistence.max_file_bytes;
pub const DocumentId = struct { workspace: u64, slot: u32, generation: u32 };
var next_workspace = std.atomic.Value(u64).init(1);
pub const CloseDecision = enum { if_clean, cancel, discard, save };
pub const ChangeOrigin = enum { typing, undo, redo, completion, formatting, agent, external_reload, project_edit, recovery_restore };
pub const DocumentChange = struct {
    document: DocumentId,
    origin: ChangeOrigin,
    before: u64,
    after: u64,
    state: u64,
    mappings: []const text.Mapping,
    allocator: std.mem.Allocator,
    /// Takes the transaction's existing mapping buffer without allocating.
    pub fn take(id: DocumentId, origin: ChangeOrigin, change: text.Change) DocumentChange {
        return .{ .allocator = change.allocator, .document = id, .origin = origin, .before = change.before, .after = change.after, .state = change.state, .mappings = change.mappings };
    }
    pub fn deinit(self: *DocumentChange) void {
        // The mapping buffer is owned by the workspace/application event.
        self.allocator.free(self.mappings);
        self.* = undefined;
    }
};
/// Bounded recent edit history. Missing entries require consumers to resync
/// from current text. Insertion takes ownership and cannot fail after an edit.
pub const ChangeLog = struct {
    pub const capacity = 128;
    pub const max_mapping_bytes = 1024 * 1024;
    entries: [capacity]?DocumentChange = @splat(null),
    first: usize = 0,
    len: usize = 0,
    mapping_bytes: usize = 0,
    pub fn get(self: *const ChangeLog, index: usize) ?*const DocumentChange {
        if (index >= self.len) return null;
        return &self.entries[(self.first + index) % capacity].?;
    }
    fn evict(self: *ChangeLog) void {
        const entry = &self.entries[self.first].?;
        self.mapping_bytes -= entry.mappings.len * @sizeOf(text.Mapping);
        entry.deinit();
        self.entries[self.first] = null;
        self.first = (self.first + 1) % capacity;
        self.len -= 1;
    }
    pub fn clear(self: *ChangeLog) void {
        while (self.len > 0) self.evict();
    }
    pub fn push(self: *ChangeLog, value: DocumentChange) void {
        var event = value;
        const bytes = event.mappings.len * @sizeOf(text.Mapping);
        if (event.before == event.after or bytes > max_mapping_bytes) {
            event.deinit();
            return;
        }
        while (self.len == capacity or self.mapping_bytes > max_mapping_bytes - bytes) self.evict();
        self.entries[(self.first + self.len) % capacity] = event;
        self.mapping_bytes += bytes;
        self.len += 1;
    }
};
pub const Record = struct {
    doc: text.Document,
    path: ?[]u8,
    saved_state: ?u64,
    disk: ?DiskStamp,
    untitled_name: []u8 = &.{},
    pub fn title(record: *const Record) []const u8 {
        return if (record.path) |path| std.fs.path.basename(path) else record.untitled_name;
    }
    pub fn dirty(record: *const Record) bool {
        return if (record.saved_state) |saved| saved != record.doc.stateId() else true;
    }
    fn deinit(record: *Record, a: std.mem.Allocator) void {
        record.doc.deinit();
        if (record.path) |path| a.free(path);
        a.free(record.untitled_name);
        a.destroy(record);
    }
};
const Slot = struct { record: ?*Record = null, generation: u32 = 1, retired: bool = false };
pub const Workspace = struct {
    allocator: std.mem.Allocator,
    identity: u64,
    io: std.Io,
    root_path: []u8,
    slots: std.ArrayList(Slot) = .empty,
    next_untitled: u64 = 1,
    pub fn init(a: std.mem.Allocator, io: std.Io, root_path: []const u8) !Workspace {
        const root = try canonicalPath(a, io, root_path);
        errdefer a.free(root);
        const dir = try std.Io.Dir.cwd().openDir(io, root, .{});
        dir.close(io);
        return .{ .allocator = a, .identity = try reserveIdentity(), .io = io, .root_path = root };
    }
    pub fn deinit(workspace: *Workspace) void {
        for (workspace.slots.items) |slot| if (slot.record) |record| record.deinit(workspace.allocator);
        workspace.slots.deinit(workspace.allocator);
        workspace.allocator.free(workspace.root_path);
        workspace.* = undefined;
    }
    pub fn get(workspace: *Workspace, id: DocumentId) !*Record {
        return (try workspace.resolve(id)).record.?;
    }
    pub fn getConst(workspace: *const Workspace, id: DocumentId) !*const Record {
        if (id.workspace != workspace.identity) return error.WrongWorkspace;
        if (id.slot >= workspace.slots.items.len) return error.DocumentNotFound;
        const slot = workspace.slots.items[id.slot];
        if (slot.generation != id.generation) return error.DocumentNotFound;
        return slot.record orelse error.DocumentNotFound;
    }
    pub fn snapshot(workspace: *const Workspace, id: DocumentId) !text.Snapshot {
        return (try workspace.getConst(id)).doc.snapshot();
    }
    pub fn dirty(workspace: *const Workspace, id: DocumentId) !bool {
        return (try workspace.getConst(id)).dirty();
    }
    /// Apply one ordered edit transaction through the workspace owner. The
    /// returned change carries identity, revisions and origin for later
    /// subscribers such as recovery, Git, language services and views.
    pub fn apply(workspace: *Workspace, id: DocumentId, expected: u64, edits: []const text.Edit, group: u64, origin: ChangeOrigin) !DocumentChange {
        const record = try workspace.get(id);
        return DocumentChange.take(id, origin, try record.doc.apply(expected, edits, group));
    }
    pub fn open(workspace: *Workspace, path: []const u8) !DocumentId {
        const absolute = try workspace.absolutePath(path);
        defer workspace.allocator.free(absolute);
        const canonical = try canonicalPath(workspace.allocator, workspace.io, absolute);
        errdefer workspace.allocator.free(canonical);
        for (workspace.slots.items, 0..) |slot, i| if (slot.record) |record| if (record.path) |existing| {
            if (std.mem.eql(u8, existing, canonical)) {
                workspace.allocator.free(canonical);
                return .{ .workspace = workspace.identity, .slot = @intCast(i), .generation = slot.generation };
            }
        };
        const loaded = try persistence.read(workspace.allocator, workspace.io, canonical);
        defer workspace.allocator.free(loaded.bytes);
        try validateText(loaded.bytes);
        var document = try text.Document.init(workspace.allocator, loaded.bytes);
        errdefer document.deinit();
        const record = try workspace.allocator.create(Record);
        errdefer workspace.allocator.destroy(record);
        record.* = .{ .doc = document, .path = canonical, .saved_state = document.stateId(), .disk = loaded.stamp };
        return workspace.insert(record);
    }
    pub fn untitled(workspace: *Workspace, initial: []const u8) !DocumentId {
        try validateText(initial);
        if (initial.len > max_file_bytes) return error.FileTooLarge;
        if (workspace.next_untitled == std.math.maxInt(u64)) return error.DocumentCapacityExceeded;
        var document = try text.Document.init(workspace.allocator, initial);
        errdefer document.deinit();
        const label = try std.fmt.allocPrint(workspace.allocator, "Untitled {d}", .{workspace.next_untitled});
        errdefer workspace.allocator.free(label);
        const record = try workspace.allocator.create(Record);
        errdefer workspace.allocator.destroy(record);
        record.* = .{ .doc = document, .path = null, .disk = null, .saved_state = if (initial.len == 0) document.stateId() else null, .untitled_name = label };
        const id = try workspace.insert(record);
        workspace.next_untitled += 1;
        return id;
    }
    /// Restore checkpoint bytes without adopting the current disk stamp. The
    /// original baseline keeps later external writes protected by save conflicts.
    pub fn restore(workspace: *Workspace, bytes: []const u8, path: ?[]const u8, dirty_value: bool, disk: ?DiskStamp, untitled_name: []const u8) !DocumentId {
        try validateText(bytes);
        if (bytes.len > max_file_bytes) return error.FileTooLarge;
        if (path) |value| {
            if (!std.fs.path.isAbsolute(value) or std.mem.indexOfScalar(u8, value, 0) != null or !std.unicode.utf8ValidateSlice(value)) return error.InvalidPath;
            for (workspace.slots.items) |slot| if (slot.record) |record| if (record.path) |existing| if (std.mem.eql(u8, existing, value)) return error.DocumentAlreadyOpen;
        }
        var document = try text.Document.init(workspace.allocator, bytes);
        errdefer document.deinit();
        const owned_path = if (path) |value| try workspace.allocator.dupe(u8, value) else null;
        errdefer if (owned_path) |value| workspace.allocator.free(value);
        const title = try workspace.allocator.dupe(u8, untitled_name);
        errdefer workspace.allocator.free(title);
        const record = try workspace.allocator.create(Record);
        errdefer workspace.allocator.destroy(record);
        record.* = .{ .doc = document, .path = owned_path, .saved_state = if (dirty_value) null else document.stateId(), .disk = disk, .untitled_name = title };
        return workspace.insert(record);
    }
    pub fn save(workspace: *Workspace, id: DocumentId, save_as: ?[]const u8) !void {
        const record = try workspace.get(id);
        const destination = if (save_as) |path| try workspace.destinationPath(path) else try workspace.allocator.dupe(u8, record.path orelse return error.SavePathRequired);
        errdefer workspace.allocator.free(destination);
        for (workspace.slots.items, 0..) |slot, i| if (slot.record) |other| if (i != id.slot) if (other.path) |path| if (std.mem.eql(u8, path, destination)) return error.DocumentAlreadyOpen;
        const same_path = if (record.path) |current| std.mem.eql(u8, current, destination) else false;
        var captured = record.doc.snapshot();
        defer captured.deinit();
        if (captured.byteLen() > max_file_bytes) return error.FileTooLarge;
        const bytes = try captured.copy(workspace.allocator, .{ .start = 0, .end = captured.byteLen() });
        defer workspace.allocator.free(bytes);
        try validateText(bytes);
        const content_state = record.doc.stateId();
        const stamp = try persistence.save(workspace.io, destination, bytes, if (same_path) record.disk else null);
        // Disk publication succeeded. All ownership preparation happened first.
        if (record.path) |old| workspace.allocator.free(old);
        record.path = destination;
        workspace.allocator.free(record.untitled_name);
        record.untitled_name = &.{};
        record.disk = stamp;
        record.saved_state = content_state;
    }
    /// Refresh a clean open buffer after a Git worktree mutation. Recheck dirty
    /// state at completion so edits made while Git ran are never overwritten.
    pub fn reloadClean(workspace: *Workspace, id: DocumentId) !bool {
        const record = try workspace.get(id);
        if (record.dirty() or record.path == null) return false;
        const loaded = persistence.read(workspace.allocator, workspace.io, record.path.?) catch |err| {
            if (err == error.FileNotFound) {
                record.saved_state = null;
                record.disk = null;
                return false;
            }
            return err;
        };
        defer workspace.allocator.free(loaded.bytes);
        try validateText(loaded.bytes);
        if (record.disk != null and std.meta.eql(record.disk.?, loaded.stamp)) return false;
        var snapshot_value = record.doc.snapshot();
        defer snapshot_value.deinit();
        var change = try record.doc.apply(record.doc.revision(), &.{.{ .range = .{ .start = 0, .end = snapshot_value.byteLen() }, .text = loaded.bytes }}, 0);
        change.deinit();
        record.saved_state = record.doc.stateId();
        record.disk = loaded.stamp;
        return true;
    }
    pub fn close(workspace: *Workspace, id: DocumentId, decision: CloseDecision) !bool {
        const record = try workspace.get(id);
        if (decision == .cancel) return false;
        if (record.dirty()) switch (decision) {
            .if_clean => return error.UnsavedChanges,
            .save => try workspace.save(id, null),
            .discard => {},
            .cancel => unreachable,
        };
        const slot = try workspace.resolve(id);
        slot.record = null;
        if (slot.generation == std.math.maxInt(u32)) slot.retired = true else slot.generation += 1;
        record.deinit(workspace.allocator);
        return true;
    }
    pub fn children(workspace: *const Workspace, directory: []const u8, a: std.mem.Allocator) ![]Entry {
        const absolute = try workspace.absolutePath(directory);
        defer workspace.allocator.free(absolute);
        return tree.children(a, workspace.io, absolute);
    }
    fn resolve(workspace: *Workspace, id: DocumentId) !*Slot {
        if (id.workspace != workspace.identity) return error.WrongWorkspace;
        if (id.slot >= workspace.slots.items.len) return error.DocumentNotFound;
        const slot = &workspace.slots.items[id.slot];
        if (slot.generation != id.generation or slot.record == null) return error.DocumentNotFound;
        return slot;
    }
    fn insert(workspace: *Workspace, record: *Record) !DocumentId {
        for (workspace.slots.items, 0..) |*slot, i| if (slot.record == null and !slot.retired) {
            slot.record = record;
            return .{ .workspace = workspace.identity, .slot = @intCast(i), .generation = slot.generation };
        };
        if (workspace.slots.items.len >= std.math.maxInt(u32)) return error.DocumentCapacityExceeded;
        try workspace.slots.append(workspace.allocator, .{ .record = record });
        return .{ .workspace = workspace.identity, .slot = @intCast(workspace.slots.items.len - 1), .generation = 1 };
    }
    fn absolutePath(workspace: *const Workspace, path: []const u8) ![]u8 {
        if (path.len == 0) return error.InvalidPath;
        if (std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;
        return std.fs.path.resolve(workspace.allocator, &.{ workspace.root_path, path });
    }
    fn destinationPath(workspace: *const Workspace, path: []const u8) ![]u8 {
        const absolute_path = try workspace.absolutePath(path);
        defer workspace.allocator.free(absolute_path);
        if (canonicalPath(workspace.allocator, workspace.io, absolute_path)) |canonical| return canonical else |err| if (err != error.FileNotFound) return err;
        const parent = std.fs.path.dirname(absolute_path) orelse return error.InvalidPath;
        const name = std.fs.path.basename(absolute_path);
        const canonical_parent = try canonicalPath(workspace.allocator, workspace.io, parent);
        defer workspace.allocator.free(canonical_parent);
        return std.fs.path.join(workspace.allocator, &.{ canonical_parent, name });
    }
};
fn validateText(bytes: []const u8) !void {
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
    if (std.mem.indexOfScalar(u8, bytes, 0) != null) return error.BinaryFile;
}

fn canonicalPath(a: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    const value = try std.Io.Dir.cwd().realPathFileAlloc(io, path, a);
    defer a.free(value);
    return a.dupe(u8, value);
}

fn reserveIdentity() !u64 {
    var current = next_workspace.load(.monotonic);
    while (true) {
        if (current == std.math.maxInt(u64)) return error.WorkspaceIdentityExhausted;
        if (next_workspace.cmpxchgWeak(current, current + 1, .monotonic, .monotonic)) |actual| current = actual else return current;
    }
}
