//! One owner publishes immutable contribution generations. Readers retain a
//! Snapshot; failed loading/persistence never replaces the effective generation.
const std = @import("std");
const files = @import("filesystem.zig");
const manifest = @import("manifest.zig");
const m = @import("model.zig");
const ActivationEntry = struct { id: []const u8, enabled: bool };
const Activation = struct { schema_version: u32, extensions: []const ActivationEntry = &.{} };
const State = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    owner: std.Thread.Id,
    refs: usize = 1,
    entries: []const m.Extension = &.{},
    generation: u64 = 0,
    fn retain(s: *State) void {
        std.debug.assert(s.owner == std.Thread.getCurrentId() and s.refs < std.math.maxInt(usize));
        s.refs += 1;
    }
    fn release(s: *State) void {
        std.debug.assert(s.owner == std.Thread.getCurrentId() and s.refs > 0);
        s.refs -= 1;
        if (s.refs == 0) {
            const a = s.allocator;
            s.arena.deinit();
            a.destroy(s);
        }
    }
};
pub const Snapshot = struct {
    state: *State,
    pub fn clone(snapshot: Snapshot) Snapshot {
        snapshot.state.retain();
        return snapshot;
    }
    pub fn deinit(snapshot: *Snapshot) void {
        snapshot.state.release();
        snapshot.* = undefined;
    }
    pub fn revision(snapshot: Snapshot) u64 {
        return snapshot.state.generation;
    }
    pub fn installed(snapshot: Snapshot) []const m.Extension {
        return snapshot.state.entries;
    }
    pub fn extension(snapshot: Snapshot, id: []const u8) ?*const m.Extension {
        for (snapshot.state.entries) |*entry| if (std.mem.eql(u8, entry.id, id)) return entry;
        return null;
    }
    pub fn resolveTheme(snapshot: Snapshot, id: []const u8) ?*const m.Theme {
        for (snapshot.state.entries) |*entry| if (entry.enabled) {
            for (entry.themes) |*theme| if (std.mem.eql(u8, theme.id, id)) return theme;
        };
        return null;
    }
    pub fn resolveIconTheme(snapshot: Snapshot, id: []const u8) ?*const m.IconTheme {
        for (snapshot.state.entries) |*entry| if (entry.enabled) {
            for (entry.icon_themes) |*theme| if (std.mem.eql(u8, theme.id, id)) return theme;
        };
        return null;
    }
    pub fn languageForPath(snapshot: Snapshot, path: []const u8) ?*const m.Language {
        for (snapshot.state.entries) |*entry| if (entry.enabled) {
            for (entry.languages) |*language| if (language.matches(path)) return language;
        };
        return null;
    }
    pub fn serverForLanguage(snapshot: Snapshot, id: []const u8) ?*const m.Server {
        for (snapshot.state.entries) |*entry| if (entry.enabled) {
            for (entry.language_servers) |*server| for (server.languages) |language| if (std.mem.eql(u8, language, id)) return server;
        };
        return null;
    }
};
pub const Registry = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    home: []u8,
    current: *State,
    owner: std.Thread.Id,
    serial: u64 = 0,
    pub fn init(a: std.mem.Allocator, io: std.Io, home: []const u8) !Registry {
        try std.Io.Dir.cwd().createDirPath(io, home);
        const canonical = try std.Io.Dir.cwd().realPathFileAlloc(io, home, a);
        defer a.free(canonical);
        const owned = try a.dupe(u8, canonical);
        errdefer a.free(owned);
        return .{ .allocator = a, .io = io, .home = owned, .current = try load(a, io, owned, null, 0), .owner = std.Thread.getCurrentId() };
    }
    fn check(registry: *const Registry) void {
        std.debug.assert(registry.owner == std.Thread.getCurrentId());
    }
    pub fn deinit(registry: *Registry) void {
        registry.check();
        registry.current.release();
        registry.allocator.free(registry.home);
        registry.* = undefined;
    }
    pub fn snapshot(registry: *const Registry) Snapshot {
        registry.check();
        registry.current.retain();
        return .{ .state = registry.current };
    }
    pub fn install(registry: *Registry, source_directory: []const u8) ![]const u8 {
        registry.check();
        try registry.validateSource(source_directory);
        var arena = std.heap.ArenaAllocator.init(registry.allocator);
        defer arena.deinit();
        const validation = try manifest.load(arena.allocator(), registry.io, source_directory, true);
        if (find(registry.current, validation.id) != null) return error.ExtensionAlreadyInstalled;
        const destination = try std.fs.path.join(registry.allocator, &.{ registry.home, validation.id });
        defer registry.allocator.free(destination);
        const stage = try registry.temporary("install");
        defer registry.allocator.free(stage);
        errdefer std.Io.Dir.cwd().deleteTree(registry.io, stage) catch {};
        try files.copyBundle(registry.allocator, registry.io, source_directory, stage);
        // Revalidate the copied package before publishing managed files.
        const copied = try manifest.load(arena.allocator(), registry.io, stage, true);
        if (!std.mem.eql(u8, copied.id, validation.id)) return error.BundleChangedDuringInstall;
        try std.Io.Dir.cwd().renamePreserve(stage, std.Io.Dir.cwd(), destination, registry.io);
        errdefer std.Io.Dir.cwd().deleteTree(registry.io, destination) catch {};
        const candidate = try load(registry.allocator, registry.io, registry.home, .{ .id = validation.id, .enabled = true }, try registry.nextGeneration());
        errdefer candidate.release();
        try registry.persist(candidate);
        registry.publish(candidate);
        return find(registry.current, validation.id).?.id;
    }
    /// Replace a package transactionally while preserving activation and retained snapshots.
    pub fn upgrade(registry: *Registry, source_directory: []const u8) !void {
        registry.check();
        try registry.validateSource(source_directory);
        var arena = std.heap.ArenaAllocator.init(registry.allocator);
        defer arena.deinit();
        const validation = try manifest.load(arena.allocator(), registry.io, source_directory, true);
        const previous = find(registry.current, validation.id) orelse return error.ExtensionNotFound;
        const enabled = previous.enabled;
        const destination = try std.fs.path.join(registry.allocator, &.{ registry.home, validation.id });
        defer registry.allocator.free(destination);
        const stage = try registry.temporary("upgrade");
        defer registry.allocator.free(stage);
        defer std.Io.Dir.cwd().deleteTree(registry.io, stage) catch {};
        try files.copyBundle(registry.allocator, registry.io, source_directory, stage);
        const copied = try manifest.load(arena.allocator(), registry.io, stage, enabled);
        if (!std.mem.eql(u8, copied.id, validation.id)) return error.BundleChangedDuringInstall;
        const backup = try registry.temporary("backup");
        defer registry.allocator.free(backup);
        try std.Io.Dir.cwd().rename(destination, std.Io.Dir.cwd(), backup, registry.io);
        errdefer std.Io.Dir.cwd().rename(backup, std.Io.Dir.cwd(), destination, registry.io) catch {};
        try std.Io.Dir.cwd().renamePreserve(stage, std.Io.Dir.cwd(), destination, registry.io);
        errdefer std.Io.Dir.cwd().deleteTree(registry.io, destination) catch {};
        const candidate = try load(registry.allocator, registry.io, registry.home, .{ .id = validation.id, .enabled = enabled }, try registry.nextGeneration());
        errdefer candidate.release();
        try registry.persist(candidate);
        registry.publish(candidate);
        std.Io.Dir.cwd().deleteTree(registry.io, backup) catch {};
    }
    pub fn setEnabled(registry: *Registry, id: []const u8, enabled: bool) !void {
        registry.check();
        const old = find(registry.current, id) orelse return error.ExtensionNotFound;
        if (old.enabled == enabled) return;
        const candidate = try load(registry.allocator, registry.io, registry.home, .{ .id = id, .enabled = enabled }, try registry.nextGeneration());
        errdefer candidate.release();
        try registry.persist(candidate);
        registry.publish(candidate);
    }
    pub fn remove(registry: *Registry, id: []const u8) !void {
        registry.check();
        _ = find(registry.current, id) orelse return error.ExtensionNotFound;
        if (!manifest.validId(id)) return error.InvalidExtensionId;
        const source = try std.fs.path.join(registry.allocator, &.{ registry.home, id });
        defer registry.allocator.free(source);
        const trash = try registry.temporary("removed");
        defer registry.allocator.free(trash);
        try std.Io.Dir.cwd().renamePreserve(source, std.Io.Dir.cwd(), trash, registry.io);
        errdefer std.Io.Dir.cwd().rename(trash, std.Io.Dir.cwd(), source, registry.io) catch {};
        const candidate = try load(registry.allocator, registry.io, registry.home, null, try registry.nextGeneration());
        errdefer candidate.release();
        try registry.persist(candidate);
        registry.publish(candidate);
        // A retained snapshot already owns its manifest and asset bytes. Leftover
        // hidden trash after a cleanup error is inert and is never discovered.
        std.Io.Dir.cwd().deleteTree(registry.io, trash) catch {};
    }
    fn validateSource(registry: *Registry, source: []const u8) !void {
        const canonical = try std.Io.Dir.cwd().realPathFileAlloc(registry.io, source, registry.allocator);
        defer registry.allocator.free(canonical);
        if (std.mem.eql(u8, canonical, registry.home) or (std.mem.startsWith(u8, registry.home, canonical) and registry.home.len > canonical.len and registry.home[canonical.len] == std.fs.path.sep)) return error.SourceContainsRegistryHome;
    }
    fn temporary(registry: *Registry, kind: []const u8) ![]u8 {
        registry.serial = std.math.add(u64, registry.serial, 1) catch return error.RegistryGenerationExhausted;
        const name = try std.fmt.allocPrint(registry.allocator, ".{s}-{d}-{d}", .{ kind, @intFromPtr(registry), registry.serial });
        defer registry.allocator.free(name);
        return std.fs.path.join(registry.allocator, &.{ registry.home, name });
    }
    fn nextGeneration(registry: *Registry) !u64 {
        return std.math.add(u64, registry.current.generation, 1) catch error.RegistryGenerationExhausted;
    }
    fn persist(registry: *Registry, candidate: *State) !void {
        const values = try registry.allocator.alloc(ActivationEntry, candidate.entries.len);
        defer registry.allocator.free(values);
        for (candidate.entries, 0..) |entry, i| values[i] = .{ .id = entry.id, .enabled = entry.enabled };
        try files.persist(registry.allocator, registry.io, registry.home, values);
    }
    fn publish(registry: *Registry, candidate: *State) void {
        const old = registry.current;
        registry.current = candidate;
        old.release();
    }
};
fn find(state: *const State, id: []const u8) ?*const m.Extension {
    for (state.entries) |*entry| if (std.mem.eql(u8, entry.id, id)) return entry;
    return null;
}
fn load(a: std.mem.Allocator, io: std.Io, home: []const u8, override: ?ActivationEntry, generation: u64) !*State {
    const state = try a.create(State);
    state.* = .{ .allocator = a, .arena = .init(a), .owner = std.Thread.getCurrentId(), .generation = generation };
    errdefer state.release();
    const arena = state.arena.allocator();
    const activation_path = try std.fs.path.join(arena, &.{ home, "state.json" });
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, activation_path, arena, .limited(manifest.max_json_bytes)) catch |err| if (err == error.FileNotFound) null else return err;
    const activation = if (bytes) |data| try std.json.parseFromSliceLeaky(Activation, arena, data, .{ .allocate = .alloc_always }) else Activation{ .schema_version = 1 };
    if (activation.schema_version != 1) return error.UnsupportedRegistrySchema;
    for (activation.extensions, 0..) |entry, i| {
        if (!manifest.validId(entry.id)) return error.InvalidExtensionId;
        for (activation.extensions[0..i]) |old| if (std.mem.eql(u8, entry.id, old.id)) return error.DuplicateExtension;
    }
    const dir = try std.Io.Dir.cwd().openDir(io, home, .{ .iterate = true });
    defer dir.close(io);
    var names: std.ArrayList([]const u8) = .empty;
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.name.len == 0 or entry.name[0] == '.' or std.mem.eql(u8, entry.name, "state.json")) continue;
        if (entry.kind == .sym_link) return error.SymlinkNotAllowed;
        if (entry.kind != .directory) continue;
        if (!manifest.validId(entry.name)) return error.InvalidExtensionId;
        if (names.items.len >= 2048) return error.TooManyExtensions;
        try names.append(arena, try arena.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn less(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.less);
    const entries = try arena.alloc(m.Extension, names.items.len);
    for (names.items, 0..) |name, i| {
        var enabled = true;
        for (activation.extensions) |entry| if (std.mem.eql(u8, entry.id, name)) {
            enabled = entry.enabled;
            break;
        };
        if (override) |entry| if (std.mem.eql(u8, entry.id, name)) {
            enabled = entry.enabled;
        };
        const directory = try std.fs.path.join(arena, &.{ home, name });
        entries[i] = try manifest.load(arena, io, directory, enabled);
        if (!std.mem.eql(u8, name, entries[i].id)) return error.InstalledIdentityMismatch;
    }
    try manifest.validateUnique(entries);
    state.entries = entries;
    return state;
}
