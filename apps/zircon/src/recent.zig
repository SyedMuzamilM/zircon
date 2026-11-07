const std = @import("std");
pub const Recent = struct {
    path: ?[]u8 = null,
    entries: std.ArrayList([]u8) = .empty,
    pub fn deinit(self: *Recent, a: std.mem.Allocator) void {
        if (self.path) |p| a.free(p);
        for (self.entries.items) |entry| a.free(entry);
        self.entries.deinit(a);
    }
    pub fn load(self: *Recent, a: std.mem.Allocator, io: std.Io, settings_path: []const u8, root: []const u8) !void {
        self.path = try std.fs.path.join(a, &.{ std.fs.path.dirname(settings_path) orelse ".", "recent-projects.json" });
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, self.path.?, a, .limited(128 * 1024)) catch null;
        if (bytes) |data| {
            defer a.free(data);
            const parsed = std.json.parseFromSlice([]const []const u8, a, data, .{ .allocate = .alloc_always }) catch null;
            if (parsed) |value| {
                defer value.deinit();
                for (value.value[0..@min(20, value.value.len)]) |entry| {
                    if (std.mem.eql(u8, entry, root) or !std.fs.path.isAbsolute(entry) or self.entries.items.len >= 19) continue;
                    var duplicate = false;
                    for (self.entries.items) |previous| if (std.mem.eql(u8, entry, previous)) {
                        duplicate = true;
                        break;
                    };
                    if (duplicate) continue;
                    const copy = try a.dupe(u8, entry);
                    errdefer a.free(copy);
                    try self.entries.append(a, copy);
                }
            }
        }
        const copy = try a.dupe(u8, root);
        errdefer a.free(copy);
        try self.entries.insert(a, 0, copy);
        const json = try std.json.Stringify.valueAlloc(a, self.entries.items, .{});
        defer a.free(json);
        try std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(self.path.?) orelse ".");
        var atomic = try std.Io.Dir.cwd().createFileAtomic(io, self.path.?, .{});
        defer atomic.deinit(io);
        try atomic.file.writeStreamingAll(io, json);
        try atomic.file.sync(io);
        try atomic.replace(io);
    }
};
