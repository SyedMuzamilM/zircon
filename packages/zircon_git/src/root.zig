//! Independent Git operations. The caller runs blocking queries in its worker
//! and serializes mutations. Results own their data, never repository buffers.
const std = @import("std");
const process = @import("process.zig");
const status_module = @import("status.zig");
const diff_module = @import("diff.zig");
const history_module = @import("history.zig");
pub const Status = status_module.Status;
pub const Entry = status_module.Entry;
pub const Change = status_module.Change;
pub const Diff = diff_module.Diff;
pub const Hunk = diff_module.Hunk;
pub const Line = diff_module.Line;
pub const LineChange = diff_module.LineChange;
pub const diffLines = diff_module.diffLines;
pub const Commit = history_module.Commit;
pub const deinitHistory = history_module.deinitHistory;
pub const Blame = history_module.Blame;
pub const Baseline = enum { head, index };
var temp_counter = std.atomic.Value(u64).init(1);
pub const Repository = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []u8,
    last_error: []u8 = &.{},
    pub fn discover(a: std.mem.Allocator, io: std.Io, path: []const u8) !?Repository {
        if (path.len == 0 or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;
        const result = try process.run(a, io, path, &.{ "rev-parse", "--show-toplevel" });
        defer process.release(a, result);
        if (!process.success(result)) {
            if (std.mem.indexOf(u8, result.stderr, "not a git repository") != null or std.mem.indexOf(u8, result.stderr, "must be run in a work tree") != null) return null;
            return error.GitCommandFailed;
        }
        const root = stripLineEnding(result.stdout);
        if (root.len == 0) return error.InvalidGitRoot;
        return .{ .allocator = a, .io = io, .root = try a.dupe(u8, root) };
    }
    pub fn deinit(self: *Repository) void {
        self.allocator.free(self.root);
        self.allocator.free(self.last_error);
        self.* = undefined;
    }
    pub fn lastError(self: *const Repository) []const u8 {
        return self.last_error;
    }
    fn command(self: *Repository, a: std.mem.Allocator, args: []const []const u8) ![]u8 {
        const result = try process.run(a, self.io, self.root, args);
        defer a.free(result.stderr);
        if (!process.success(result)) {
            defer a.free(result.stdout);
            const message = try self.allocator.dupe(u8, result.stderr);
            self.allocator.free(self.last_error);
            self.last_error = message;
            return error.GitCommandFailed;
        }
        return result.stdout;
    }
    pub fn status(self: *Repository, a: std.mem.Allocator) !Status {
        const bytes = try self.command(a, &.{ "status", "--porcelain=v1", "--branch", "-z", "--untracked-files=all" });
        defer a.free(bytes);
        return status_module.parse(a, bytes);
    }
    pub fn diff(self: *Repository, a: std.mem.Allocator, path: ?[]const u8, staged: bool) !Diff {
        if (path) |p| try validatePath(p);
        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(a);
        try args.appendSlice(a, &.{ "diff", "--no-ext-diff", "--no-textconv", "--no-color", "--unified=3" });
        if (staged) try args.append(a, "--cached");
        try args.append(a, "--");
        if (path) |p| try args.append(a, p);
        const bytes = try self.command(a, args.items);
        defer a.free(bytes);
        if (staged) return diff_module.parse(a, bytes);
        var current = try self.status(a);
        defer current.deinit();
        var combined: std.ArrayList(u8) = .empty;
        defer combined.deinit(a);
        for (current.entries) |entry| {
            if (entry.index != .untracked) continue;
            if (path) |selected| if (!std.mem.eql(u8, selected, entry.path)) continue;
            // Ordinary git diff omits untracked files. No-index emits Git's
            // own new-file patch, including binary detection and path quoting.
            const result = try process.run(a, self.io, self.root, &.{ "diff", "--no-index", "--no-ext-diff", "--no-textconv", "--no-color", "--unified=3", "--", "/dev/null", entry.path });
            defer process.release(a, result);
            if (result.term != .exited or result.term.exited > 1) {
                const message = try self.allocator.dupe(u8, result.stderr);
                self.allocator.free(self.last_error);
                self.last_error = message;
                return error.GitCommandFailed;
            }
            if (combined.items.len == 0) try combined.appendSlice(a, bytes);
            if (result.stdout.len > process.output_limit - combined.items.len) return error.DiffTooLarge;
            try combined.appendSlice(a, result.stdout);
        }
        return diff_module.parse(a, if (combined.items.len > 0) combined.items else bytes);
    }
    /// A historical patch is computed from the selected commit, never relabelled
    /// working-tree output. Full object IDs avoid option/revision ambiguity.
    pub fn commitDiff(self: *Repository, a: std.mem.Allocator, oid: []const u8, path: ?[]const u8) !Diff {
        if (!history_module.validOid(oid)) return error.InvalidObjectId;
        if (path) |value| try validatePath(value);
        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(a);
        try args.appendSlice(a, &.{ "show", "--format=", "--no-ext-diff", "--no-textconv", "--no-color", "--unified=3", oid, "--" });
        if (path) |value| try args.append(a, value);
        const bytes = try self.command(a, args.items);
        defer a.free(bytes);
        return diff_module.parse(a, bytes);
    }
    pub fn fileAt(self: *Repository, a: std.mem.Allocator, oid: []const u8, path: []const u8) ![]u8 {
        if (!history_module.validOid(oid)) return error.InvalidObjectId;
        try validatePath(path);
        const object = try std.fmt.allocPrint(a, "{s}:{s}", .{ oid, path });
        defer a.free(object);
        return self.command(a, &.{ "show", object });
    }
    pub fn history(self: *Repository, a: std.mem.Allocator, limit: usize) ![]Commit {
        if (limit == 0) return a.alloc(Commit, 0);
        if (limit > 10_000) return error.InvalidHistoryLimit;
        const count = try std.fmt.allocPrint(a, "-n{d}", .{limit});
        defer a.free(count);
        const result = try process.run(a, self.io, self.root, &.{ "log", count, "--no-decorate", "--format=%H%x00%an%x00%ae%x00%at%x00%s%x00" });
        defer process.release(a, result);
        if (!process.success(result)) {
            if (std.mem.indexOf(u8, result.stderr, "does not have any commits yet") != null or std.mem.indexOf(u8, result.stderr, "bad default revision") != null) return a.alloc(Commit, 0);
            return self.failure(result.stderr);
        }
        return history_module.parse(a, result.stdout);
    }
    fn failure(self: *Repository, bytes: []const u8) error{ OutOfMemory, GitCommandFailed } {
        const copy = self.allocator.dupe(u8, bytes) catch return error.OutOfMemory;
        self.allocator.free(self.last_error);
        self.last_error = copy;
        return error.GitCommandFailed;
    }
    pub fn baseline(self: *Repository, a: std.mem.Allocator, path: []const u8, source: Baseline) ![]u8 {
        try validatePath(path);
        const object = try std.fmt.allocPrint(a, "{s}:{s}", .{ if (source == .head) "HEAD" else "", path });
        defer a.free(object);
        const result = try process.run(a, self.io, self.root, &.{ "show", object });
        defer a.free(result.stderr);
        if (process.success(result)) return result.stdout;
        a.free(result.stdout);
        if (std.mem.indexOf(u8, result.stderr, "does not exist") != null or std.mem.indexOf(u8, result.stderr, "not in the index") != null or std.mem.indexOf(u8, result.stderr, "invalid object name 'HEAD'") != null or std.mem.indexOf(u8, result.stderr, "bad revision 'HEAD'") != null) return a.alloc(u8, 0);
        return self.failure(result.stderr);
    }
    pub fn stage(self: *Repository, paths: []const []const u8) !void {
        return self.pathsCommand("add", paths);
    }
    pub fn unstage(self: *Repository, paths: []const []const u8) !void {
        for (paths) |path| try validatePath(path);
        if (paths.len == 0) return;
        const head = try process.run(self.allocator, self.io, self.root, &.{ "rev-parse", "--verify", "HEAD" });
        defer process.release(self.allocator, head);
        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(self.allocator);
        if (process.success(head)) try args.appendSlice(self.allocator, &.{ "restore", "--staged", "--" }) else try args.appendSlice(self.allocator, &.{ "rm", "--cached", "--ignore-unmatch", "--" });
        try args.appendSlice(self.allocator, paths);
        const output = try self.command(self.allocator, args.items);
        self.allocator.free(output);
    }
    fn pathsCommand(self: *Repository, operation: []const u8, paths: []const []const u8) !void {
        for (paths) |path| try validatePath(path);
        if (paths.len == 0) return;
        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(self.allocator);
        try args.appendSlice(self.allocator, &.{ operation, "--" });
        try args.appendSlice(self.allocator, paths);
        const output = try self.command(self.allocator, args.items);
        self.allocator.free(output);
    }
    pub fn commit(self: *Repository, message: []const u8) !void {
        if (std.mem.trim(u8, message, " \t\r\n").len == 0 or std.mem.indexOfScalar(u8, message, 0) != null) return error.InvalidCommitMessage;
        const output = try self.command(self.allocator, &.{ "commit", "-m", message });
        self.allocator.free(output);
    }
    pub fn blame(self: *Repository, a: std.mem.Allocator, path: []const u8, line: usize, contents: ?[]const u8) !Blame {
        try validatePath(path);
        if (line == 0) return error.InvalidLine;
        const range = try std.fmt.allocPrint(a, "{d},{d}", .{ line, line });
        defer a.free(range);
        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(a);
        try args.appendSlice(a, &.{ "blame", "--line-porcelain", "-L", range });
        var temporary: ?[]u8 = null;
        var temporary_created = false;
        defer if (temporary) |name| {
            if (temporary_created) std.Io.Dir.cwd().deleteFile(self.io, name) catch {};
            a.free(name);
        };
        if (contents) |bytes| {
            // A private sibling under Git's metadata directory avoids passing
            // document bytes through shell syntax and is removed on every exit.
            const git_path = try self.command(a, &.{ "rev-parse", "--absolute-git-dir" });
            defer a.free(git_path);
            const id = temp_counter.fetchAdd(1, .monotonic);
            var nonce: u64 = undefined;
            self.io.random(std.mem.asBytes(&nonce));
            const name = try std.fmt.allocPrint(a, "{s}/zircon-blame-{d}-{d}-{x}.tmp", .{ stripLineEnding(git_path), std.Thread.getCurrentId(), id, nonce });
            temporary = name;
            const file = try std.Io.Dir.cwd().createFile(self.io, name, .{ .exclusive = true, .permissions = .fromMode(0o600) });
            temporary_created = true;
            defer file.close(self.io);
            try file.writeStreamingAll(self.io, bytes);
            try args.appendSlice(a, &.{ "--contents", name });
        }
        try args.appendSlice(a, &.{ "--", path });
        const output = try self.command(a, args.items);
        defer a.free(output);
        return history_module.parseBlame(a, output);
    }
    /// Convert an absolute project path to a Git-relative path without allowing
    /// traversal. Callers passing symlinks must use the workspace canonical path.
    pub fn relativePath(self: *const Repository, a: std.mem.Allocator, path: []const u8) ![]u8 {
        if (!std.fs.path.isAbsolute(path)) {
            try validatePath(path);
            return a.dupe(u8, path);
        }
        const relative = try std.fs.path.relativeAlloc(a, self.root, null, self.root, path);
        errdefer a.free(relative);
        try validatePath(relative);
        return relative;
    }
};
pub fn validatePath(path: []const u8) !void {
    if (path.len == 0 or std.fs.path.isAbsolute(path) or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;
    var components = std.mem.splitScalar(u8, path, '/');
    while (components.next()) |component| if (std.mem.eql(u8, component, "..") or std.mem.eql(u8, component, ".git")) return error.InvalidPath;
}

test {
    _ = @import("parser_tests.zig");
}

fn stripLineEnding(bytes: []const u8) []const u8 {
    return if (std.mem.endsWith(u8, bytes, "\n")) bytes[0 .. bytes.len - 1] else bytes;
}
