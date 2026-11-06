//! Decode each active icon asset once. Frames retain image pixels, so replacing
//! the selected theme does not invalidate images already submitted to Metal.
const std = @import("std");
const ui = @import("zircon_ui");
const ext = @import("zircon_extensions");
pub const Cache = struct {
    entries: std.ArrayList(struct { path: []u8, image: ui.graphics.images.Image }) = .empty,
    pub fn deinit(self: *Cache, a: std.mem.Allocator) void {
        for (self.entries.items) |*entry| {
            a.free(entry.path);
            entry.image.deinit();
        }
        self.entries.deinit(a);
        self.* = .{};
    }
    pub fn init(a: std.mem.Allocator, theme: *const ext.IconTheme) !Cache {
        var self: Cache = .{};
        errdefer self.deinit(a);
        for (theme.files) |entry| try self.add(a, entry.icon);
        for (theme.folders) |entry| try self.add(a, entry.icon);
        for (theme.extensions) |entry| try self.add(a, entry.icon);
        for (theme.stems) |entry| try self.add(a, entry.icon);
        try self.add(a, theme.default_file);
        try self.add(a, theme.default_folder);
        return self;
    }
    fn add(self: *Cache, a: std.mem.Allocator, icon: ext.Icon) !void {
        if (icon != .png) return;
        if (self.find(icon.png.path) != null) return;
        var image = decode(a, icon.png.bytes) catch |err| {
            if (err == error.OutOfMemory) return err;
            return;
        };
        errdefer image.deinit();
        const path = try a.dupe(u8, icon.png.path);
        errdefer a.free(path);
        try self.entries.append(a, .{ .path = path, .image = image });
    }
    pub fn find(self: *const Cache, path: []const u8) ?ui.graphics.images.Image {
        for (self.entries.items) |entry| if (std.mem.eql(u8, entry.path, path)) return entry.image;
        return null;
    }
};
fn decode(a: std.mem.Allocator, bytes: []const u8) anyerror!ui.graphics.images.Image {
    return ui.graphics.images.Image.load(a, bytes);
}
