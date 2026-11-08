//! Check only the root and disclosed directories, preserving the lazy tree.
const std = @import("std");
const ui = @import("zircon_ui");
const actions = @import("../actions.zig");
const shell = @import("../shell.zig");
const Shell = shell.Shell;
pub const Model = struct { next_check: f64 = 0, fingerprint: ?u64 = null };
pub fn poll(self: *Shell, cx: *ui.Context(Shell)) !void {
    const now = try cx.app.currentTime();
    if (now < self.project_watch.next_check) return;
    self.project_watch.next_check = now + 1;
    const stamp = try fingerprint(self);
    if (self.project_watch.fingerprint == stamp) return;
    try actions.refreshTree(self);
    self.project_watch.fingerprint = try fingerprint(self);
    cx.notify();
}
fn fingerprint(self: *const Shell) !u64 {
    var hash = std.hash.Wyhash.init(0);
    try directoryStamp(self, &hash, self.workspace.root_path);
    for (self.tree.items) |row| if (row.directory and row.expanded) try directoryStamp(self, &hash, row.path);
    return hash.final();
}
fn directoryStamp(self: *const Shell, hash: *std.hash.Wyhash, path: []const u8) !void {
    hash.update(path);
    const stat = std.Io.Dir.cwd().statFile(self.workspace.io, path, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir, error.AccessDenied => return,
        else => return err,
    };
    std.hash.autoHash(hash, stat.inode);
    std.hash.autoHash(hash, stat.mtime);
}
