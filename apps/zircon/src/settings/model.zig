//! Settings are application-owned; closing a preferences window releases its
//! view, while effective values continue to serve every editor window.
const std = @import("std");
const ui = @import("zircon_ui");
const store = @import("store.zig");
pub const Patch = store.Patch;
pub const Values = store.Values;
pub const Settings = struct {
    store: store.Store,
    pub fn init(a: std.mem.Allocator, io: std.Io, path: ?[]const u8) !Settings {
        return .{ .store = try store.Store.init(a, io, path) };
    }
    pub fn deinit(self: *Settings, _: std.mem.Allocator) void {
        self.store.deinit();
    }
    pub fn copy(self: *const Settings, a: std.mem.Allocator, output: *Values) !void {
        const value = self.store.values();
        const theme = try a.dupe(u8, value.theme);
        errdefer a.free(theme);
        output.* = value;
        output.theme = theme;
        output.icon_theme = try a.dupe(u8, value.icon_theme);
    }
    pub fn apply(self: *Settings, cx: *ui.Context(Settings), patch: Patch) !void {
        try self.store.update(patch);
        cx.notify();
    }
};
