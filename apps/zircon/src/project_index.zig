//! Cancellable lazy project indexing. Worker results own their bytes; UI
//! completion copies them before executor disposal. Symlinked directories are
//! skipped to avoid recursive cycles and traversal outside the requested tree.
const std = @import("std");
const ui = @import("zircon_ui");
const model = @import("shell.zig");
const Shell = model.Shell;
const Result = struct { entries: []model.IndexedFile, truncated: bool };
const Job = struct {
    pub const Output = Result;
    root: []u8,
    io: std.Io,
    pub fn run(self: *Job, cancel: *ui.tasks.Cancellation) !Result {
        const a = std.heap.page_allocator;
        var entries: std.ArrayList(model.IndexedFile) = .empty;
        errdefer {
            for (entries.items) |entry| {
                a.free(entry.path);
                a.free(entry.label);
            }
            entries.deinit(a);
        }
        var truncated = false;
        if (!try scanGit(a, self.io, self.root, cancel, &entries, &truncated)) try scan(a, self.io, self.root, "", 0, cancel, &entries, &truncated);
        std.mem.sort(model.IndexedFile, entries.items, {}, struct {
            fn less(_: void, x: model.IndexedFile, y: model.IndexedFile) bool {
                return std.ascii.orderIgnoreCase(x.label, y.label) == .lt;
            }
        }.less);
        return .{ .entries = try entries.toOwnedSlice(a), .truncated = truncated };
    }
    pub fn discard(_: *Job, result: Result) void {
        const a = std.heap.page_allocator;
        for (result.entries) |entry| {
            a.free(entry.path);
            a.free(entry.label);
        }
        a.free(result.entries);
    }
    pub fn deinit(self: *Job, _: std.mem.Allocator) void {
        std.heap.page_allocator.free(self.root);
    }
};

fn scanGit(a: std.mem.Allocator, io: std.Io, root: []const u8, cancel: *ui.tasks.Cancellation, entries: *std.ArrayList(model.IndexedFile), truncated: *bool) !bool {
    const top = std.process.run(a, io, .{ .argv = &.{ "git", "-C", root, "rev-parse", "--show-toplevel" }, .stdout_limit = .limited(4096), .stderr_limit = .limited(64 * 1024) }) catch return false;
    defer {
        a.free(top.stdout);
        a.free(top.stderr);
    }
    const root_end = if (root.len > 0 and root[root.len - 1] == '/') root.len - 1 else root.len;
    if (top.term != .exited or top.term.exited != 0 or !std.mem.eql(u8, std.mem.trim(u8, top.stdout, "\r\n"), root[0..root_end])) return false;
    const result = std.process.run(a, io, .{ .argv = &.{ "git", "-C", root, "ls-files", "-co", "--exclude-standard", "-z" }, .stdout_limit = .limited(64 * 1024 * 1024), .stderr_limit = .limited(1024 * 1024) }) catch return false;
    defer {
        a.free(result.stdout);
        a.free(result.stderr);
    }
    if (result.term != .exited or result.term.exited != 0) return false;
    var offset: usize = 0;
    while (offset < result.stdout.len) {
        try cancel.check();
        const end = std.mem.indexOfScalarPos(u8, result.stdout, offset, 0) orelse return error.InvalidGitIndex;
        if (end == offset) return error.InvalidGitIndex;
        if (entries.items.len >= 20_000) {
            truncated.* = true;
            break;
        }
        const relative = result.stdout[offset..end];
        const absolute = try std.fs.path.join(a, &.{ root, relative });
        errdefer a.free(absolute);
        const label = try a.dupe(u8, relative);
        errdefer a.free(label);
        try entries.append(a, .{ .path = absolute, .label = label });
        offset = end + 1;
    }
    return true;
}
pub fn start(self: *Shell, cx: *ui.Context(Shell)) !void {
    if (self.indexing) return;
    const root = try std.heap.page_allocator.dupe(u8, self.workspace.root_path);
    errdefer std.heap.page_allocator.free(root);
    _ = try cx.spawn(Job, .{ .root = root, .io = self.workspace.io }, complete);
    self.indexing = true;
}

fn complete(self: *Shell, cx: *ui.Context(Shell), result: anyerror!Result) !void {
    self.indexing = false;
    const found = result catch |err| {
        if (err != error.Canceled) try self.reportError(err);
        cx.notify();
        return;
    };
    var next: std.ArrayList(model.IndexedFile) = .empty;
    errdefer {
        for (next.items) |entry| {
            self.allocator.free(entry.path);
            self.allocator.free(entry.label);
        }
        next.deinit(self.allocator);
    }
    for (found.entries) |entry| {
        const path = try self.allocator.dupe(u8, entry.path);
        errdefer self.allocator.free(path);
        const label = try self.allocator.dupe(u8, entry.label);
        errdefer self.allocator.free(label);
        try next.append(self.allocator, .{ .path = path, .label = label });
    }
    for (self.file_index.items) |entry| {
        self.allocator.free(entry.path);
        self.allocator.free(entry.label);
    }
    self.file_index.deinit(self.allocator);
    self.file_index = next;
    if (found.truncated) try self.setStatus(try self.allocator.dupe(u8, "File search indexes the first 20,000 files, up to 32 folders deep."));
    cx.notify();
}

fn scan(a: std.mem.Allocator, io: std.Io, root: []const u8, relative: []const u8, depth: usize, cancel: *ui.tasks.Cancellation, entries: *std.ArrayList(model.IndexedFile), truncated: *bool) anyerror!void {
    try cancel.check();
    if (depth > 32 or entries.items.len >= 20_000) {
        truncated.* = true;
        return;
    }
    const path = try std.fs.path.join(a, &.{ root, relative });
    defer a.free(path);
    const dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| {
        if (err == error.AccessDenied or err == error.FileNotFound) return;
        return err;
    };
    defer dir.close(io);
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        try cancel.check();
        if (entries.items.len >= 20_000) {
            truncated.* = true;
            return;
        }
        if (ignored(entry.name)) continue;
        const local = try std.fs.path.join(a, &.{ relative, entry.name });
        defer a.free(local);
        if (entry.kind == .directory) try scan(a, io, root, local, depth + 1, cancel, entries, truncated) else if (entry.kind == .file) {
            const absolute = try std.fs.path.join(a, &.{ root, local });
            errdefer a.free(absolute);
            const label = try a.dupe(u8, local);
            errdefer a.free(label);
            try entries.append(a, .{ .path = absolute, .label = label });
        }
    }
}

fn ignored(name: []const u8) bool {
    for ([_][]const u8{ ".git", ".zig-cache", ".tools", "zig-out", "node_modules", ".DS_Store" }) |excluded| if (std.mem.eql(u8, name, excluded)) return true;
    return false;
}
