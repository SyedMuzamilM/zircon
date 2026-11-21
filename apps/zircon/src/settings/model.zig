//! User settings are shared across windows. Each workspace root has its own
//! project layer, also shared by windows opened on that same root.
const std = @import("std");
const ui = @import("zircon_ui");
const store = @import("store.zig");
pub const Patch = store.Patch;
pub const Values = store.Values;
pub const Scope = store.Scope;
pub const BufferSettings = store.BufferSettings;
pub const FormatOnSave = store.FormatOnSave;
pub const Autosave = store.Autosave;

pub const Settings = struct {
    store: store.Store,
    projects: std.StringHashMapUnmanaged(store.Store) = .empty,

    pub fn init(a: std.mem.Allocator, io: std.Io, path: ?[]const u8) !Settings {
        return .{ .store = try store.Store.init(a, io, path) };
    }

    pub fn deinit(self: *Settings, _: std.mem.Allocator) void {
        const a = self.store.allocator;
        var projects = self.projects.iterator();
        while (projects.next()) |entry| {
            a.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }
        self.projects.deinit(a);
        self.store.deinit();
    }

    pub fn loadProject(self: *Settings, cx: *ui.Context(Settings), root: []const u8) !void {
        if (self.projects.contains(root)) return;
        const a = self.store.allocator;
        const key = try a.dupe(u8, root);
        var owned = true;
        errdefer if (owned) a.free(key);
        try self.projects.ensureUnusedCapacity(a, 1);
        var project = try store.Store.init(a, self.store.io, null);
        const loaded = project.setProjectRoot(root);
        self.projects.putAssumeCapacityNoClobber(key, project);
        owned = false;
        cx.notify();
        loaded catch |err| return err;
    }

    pub fn copy(self: *const Settings, a: std.mem.Allocator, output: *Values) !void {
        try self.copyResolved(null, a, output);
    }

    pub fn copyResolved(self: *const Settings, root: ?[]const u8, a: std.mem.Allocator, output: *Values) !void {
        const value = self.store.valuesWithProject(if (root) |project| self.projects.getPtr(project) else null);
        const theme = try a.dupe(u8, value.theme);
        errdefer a.free(theme);
        const icon_theme = try a.dupe(u8, value.icon_theme);
        output.* = value;
        output.theme = theme;
        output.icon_theme = icon_theme;
    }

    pub fn bufferSettings(self: *const Settings, root: []const u8, id: []const u8, name: []const u8) BufferSettings {
        return self.store.bufferWithProject(self.projects.getPtr(root), id, name);
    }

    pub fn apply(self: *Settings, cx: *ui.Context(Settings), patch: Patch) !void {
        try self.store.update(patch);
        cx.notify();
    }

    pub fn applyScoped(self: *Settings, cx: *ui.Context(Settings), root: ?[]const u8, scope: Scope, patch: Patch) !void {
        if (scope == .user) return self.apply(cx, patch);
        const project = self.projects.getPtr(root orelse return error.NoProjectSettings) orelse return error.NoProjectSettings;
        try project.updateScope(.project, patch);
        cx.notify();
    }

    pub fn clearProjectKey(self: *Settings, cx: *ui.Context(Settings), root: []const u8, key: []const u8) !void {
        const project = self.projects.getPtr(root) orelse return error.NoProjectSettings;
        try project.clearProjectKey(key);
        cx.notify();
    }

    pub fn hasProjectOverride(self: *const Settings, root: []const u8, key: []const u8) bool {
        const project = self.projects.getPtr(root) orelse return false;
        return project.hasProjectOverride(key);
    }

    pub fn ignoredProjectKeys(self: *const Settings, root: []const u8) usize {
        const project = self.projects.getPtr(root) orelse return 0;
        return project.ignored_project_keys;
    }

    pub fn reloadSavedPath(self: *Settings, cx: *ui.Context(Settings), path: []const u8) !bool {
        var projects = self.projects.valueIterator();
        var matched = try self.store.reloadSavedPath(path);
        while (projects.next()) |project| {
            if (try project.reloadSavedPath(path)) matched = true;
        }
        if (matched) cx.notify();
        return matched;
    }

    pub fn copyPath(self: *const Settings, a: std.mem.Allocator, output: *?[]u8) !void {
        output.* = if (self.store.path) |path| try a.dupe(u8, path) else null;
    }

    pub fn copyProjectPath(self: *const Settings, root: []const u8, a: std.mem.Allocator, output: *?[]u8) !void {
        output.* = null;
        const project = self.projects.getPtr(root) orelse return;
        if (project.project_path) |path| output.* = try a.dupe(u8, path);
    }

    pub fn prepareFile(self: *Settings, _: *ui.Context(Settings)) !void {
        try self.store.ensureFile();
    }

    pub fn prepareScopeFile(self: *Settings, cx: *ui.Context(Settings), root: ?[]const u8, scope: Scope) !void {
        if (scope == .user) return self.prepareFile(cx);
        const project = self.projects.getPtr(root orelse return error.NoProjectSettings) orelse return error.NoProjectSettings;
        try project.ensureScopeFile(.project);
    }
};
