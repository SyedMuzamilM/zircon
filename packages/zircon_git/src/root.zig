//! Independent Git operations. The caller runs blocking queries in its worker
//! and serializes mutations. Results own their data, never repository buffers.
const std = @import("std");
const builtin = @import("builtin");
pub const buffer_diff = @import("buffer_diff.zig");
const diff_module = @import("diff.zig");
const history_module = @import("history.zig");
const numstat = @import("numstat.zig");
const parser_tests = @import("parser_tests.zig");
const process = @import("process.zig");
const references_module = @import("references.zig");
const status_module = @import("status.zig");
pub const processStats = process.stats;
pub const LineStats = numstat.LineStats;
pub const Status = status_module.Status;
pub const Entry = status_module.Entry;
pub const Change = status_module.Change;
pub const Diff = diff_module.Diff;
pub const parseDiff = diff_module.parse;
pub const Hunk = diff_module.Hunk;
pub const Line = diff_module.Line;
pub const LineChange = diff_module.LineChange;
pub const diffLines = diff_module.diffLines;
pub const Commit = history_module.Commit;
pub const deinitHistory = history_module.deinitHistory;
pub const Blame = history_module.Blame;
pub const References = references_module.References;
pub const Branch = references_module.Branch;
pub const Stash = references_module.Stash;
pub const Network = union(enum) { fetch: []const u8, pull: bool, push: struct { remote: []const u8 = "", publish: bool = false, force_with_lease: bool = false } };
pub const Baseline = enum { head, index };
var temp_counter = std.atomic.Value(u64).init(1);
/// Clone runs in the caller's worker. Restrict remote-helper syntax at this
/// external boundary; arguments are never interpreted by a shell.
pub fn cloneRepository(a: std.mem.Allocator, io: std.Io, source: []const u8, destination: []const u8) !void {
    if (source.len == 0 or std.mem.indexOfAny(u8, source, "\x00\r\n") != null or !std.unicode.utf8ValidateSlice(source)) return error.InvalidRepositoryUrl;
    if (!std.fs.path.isAbsolute(source) and !std.mem.startsWith(u8, source, "https://") and !std.mem.startsWith(u8, source, "ssh://") and !std.mem.startsWith(u8, source, "git@")) return error.UnsupportedRepositoryUrl;
    if (!std.fs.path.isAbsolute(destination) or std.mem.indexOfScalar(u8, destination, 0) != null) return error.InvalidPath;
    const parent = std.fs.path.dirname(destination) orelse return error.InvalidPath;
    const result = try process.run(a, io, parent, &.{ "-c", "protocol.ext.allow=never", "clone", "--no-hardlinks", "--", source, destination });
    defer process.release(a, result);
    if (!process.success(result)) return error.GitCloneFailed;
}
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
        var result = try self.readStatus(a);
        errdefer result.deinit();
        self.statusCounts(a, &result) catch |err| {
            if (err == error.OutOfMemory) return err;
            // Optional counts must not hide the actual changed-file list.
            for (@constCast(result.entries)) |*entry| entry.stats = null;
        };
        return result;
    }
    fn readStatus(self: *Repository, a: std.mem.Allocator) !Status {
        const bytes = try self.command(a, &.{ "status", "--porcelain=v1", "--branch", "-z", "--untracked-files=all" });
        defer a.free(bytes);
        return status_module.parse(a, bytes);
    }
    /// Counts describe HEAD to the current worktree, including staged changes.
    /// An unborn repository compares staged paths against Git's empty tree.
    fn statusCounts(self: *Repository, a: std.mem.Allocator, result: *Status) !void {
        if (result.entries.len == 0) return;
        const entries = @constCast(result.entries);
        var by_path: std.StringHashMapUnmanaged(usize) = .empty;
        defer by_path.deinit(a);
        {
            for (entries, 0..) |*entry, i| if (entry.index != .untracked) {
                entry.stats = .{};
                try by_path.put(a, entry.path, i);
            };
            if (by_path.count() > 0) {
                const empty_tree = if (result.unborn) try self.command(a, &.{ "hash-object", "-t", "tree", "--stdin" }) else null;
                defer if (empty_tree) |value| a.free(value);
                const baseline_tree = if (empty_tree) |value| std.mem.trim(u8, value, "\r\n") else "HEAD";
                const bytes = try self.command(a, &.{ "diff", "--numstat", "-z", "--find-renames", "--no-ext-diff", "--no-textconv", baseline_tree, "--" });
                defer a.free(bytes);
                const rows = try numstat.parse(a, bytes);
                defer a.free(rows);
                for (rows) |row| if (by_path.get(row.path)) |i| {
                    entries[i].stats = row.stats;
                };
            }
        }
        const dir = try std.Io.Dir.cwd().openDir(self.io, self.root, .{});
        defer dir.close(self.io);
        var remaining: u64 = 64 * 1024 * 1024;
        for (entries) |*entry| if (entry.index == .untracked) {
            entry.stats = countNewFile(self.io, dir, entry.path, &remaining) catch null;
        };
    }
    pub fn diff(self: *Repository, a: std.mem.Allocator, path: ?[]const u8, staged: bool) !Diff {
        return self.compare(a, path, staged, false);
    }
    pub fn allChanges(self: *Repository, a: std.mem.Allocator) !Diff {
        return self.compare(a, null, false, true);
    }
    fn compare(self: *Repository, a: std.mem.Allocator, path: ?[]const u8, staged: bool, against_head: bool) !Diff {
        if (path) |p| try validatePath(p);
        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(a);
        try args.appendSlice(a, &.{ "diff", "--no-ext-diff", "--no-textconv", "--no-color", "--unified=3" });
        if (staged) try args.append(a, "--cached");
        var empty_tree: ?[]u8 = null;
        defer if (empty_tree) |value| a.free(value);
        if (against_head) {
            var state = try self.readStatus(a);
            defer state.deinit();
            if (state.unborn) {
                empty_tree = try self.command(a, &.{ "hash-object", "-t", "tree", "-w", "--stdin" });
                try args.append(a, std.mem.trim(u8, empty_tree.?, "\r\n"));
            } else try args.append(a, "HEAD");
        }
        try args.append(a, "--");
        if (path) |p| try args.append(a, p);
        const bytes = try self.command(a, args.items);
        defer a.free(bytes);
        if (staged) return diff_module.parse(a, bytes);
        var current = try self.readStatus(a);
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
        if (std.mem.indexOf(u8, result.stderr, "does not exist") != null or std.mem.indexOf(u8, result.stderr, "not in the index") != null or std.mem.indexOf(u8, result.stderr, "not in 'HEAD'") != null or std.mem.indexOf(u8, result.stderr, "invalid object name 'HEAD'") != null or std.mem.indexOf(u8, result.stderr, "bad revision 'HEAD'") != null) return a.alloc(u8, 0);
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
    /// NUL-separated index paths, including tracked files absent from status.
    pub fn trackedPaths(self: *Repository, a: std.mem.Allocator) ![]u8 {
        return self.command(a, &.{ "ls-files", "--cached", "-z" });
    }
    pub fn commitTrackedFallback(self: *Repository, message: []const u8) !void {
        var current = try self.status(self.allocator);
        defer current.deinit();
        for (current.entries) |entry| if (entry.conflicted) return error.UnresolvedGitConflicts;
        var staged = false;
        for (current.entries) |entry| staged = staged or entry.staged;
        if (!staged) {
            var paths: std.ArrayList([]const u8) = .empty;
            defer paths.deinit(self.allocator);
            for (current.entries) |entry| if (entry.unstaged and entry.index != .untracked and entry.index != .added and entry.worktree != .untracked and entry.worktree != .added) try paths.append(self.allocator, entry.path);
            if (paths.items.len == 0) return error.NoCommitChanges;
            try self.stage(paths.items);
        }
        try self.commit(message);
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
            const permissions = if (comptime builtin.os.tag == .windows) std.Io.File.Permissions.default_file else std.Io.File.Permissions.fromMode(0o600);
            const file = try std.Io.Dir.cwd().createFile(self.io, name, .{ .exclusive = true, .permissions = permissions });
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
    pub fn references(self: *Repository, a: std.mem.Allocator) !References {
        const branches = try self.command(a, &.{ "for-each-ref", "--sort=refname", "--format=%(refname)%00%(objectname)%00%(subject)%00%(authorname)%00%(upstream:short)%00%(upstream:track)%00", "refs/heads", "refs/remotes" });
        defer a.free(branches);
        const remotes = try self.command(a, &.{"remote"});
        defer a.free(remotes);
        const stashes = try self.command(a, &.{ "stash", "list", "--format=%gd%x00%H%x00%gs%x00" });
        defer a.free(stashes);
        return references_module.parse(a, branches, remotes, stashes);
    }
    pub fn network(self: *Repository, request: Network) !void {
        const al = self.allocator;
        const output = switch (request) {
            .fetch => |remote| blk: {
                if (remote.len == 0) break :blk try self.command(al, &.{ "fetch", "--prune" });
                try validateRefArgument(remote);
                break :blk try self.command(al, &.{ "fetch", "--prune", "--", remote });
            },
            .pull => |rebase| try self.command(al, &.{ "pull", if (rebase) "--rebase" else "--ff-only" }),
            .push => |push| blk: {
                var state = try self.readStatus(al);
                defer state.deinit();
                if (state.detached) return error.DetachedHead;
                if (push.remote.len > 0) try validateRefArgument(push.remote);
                var args: std.ArrayList([]const u8) = .empty;
                defer args.deinit(al);
                try args.append(al, "push");
                if (push.force_with_lease) try args.append(al, "--force-with-lease");
                if (push.publish) try args.append(al, "--set-upstream");
                if (push.remote.len > 0) try args.appendSlice(al, &.{ "--", push.remote, "HEAD" });
                break :blk try self.command(al, args.items);
            },
        };
        al.free(output);
    }
    pub fn switchBranch(self: *Repository, name: []const u8, create: bool, track: bool) !void {
        try validateRefArgument(name);
        const validated = try self.command(self.allocator, &.{ "check-ref-format", "--branch", name });
        self.allocator.free(validated);
        const output = try self.command(self.allocator, if (create) &.{ "switch", "-c", name } else if (track) &.{ "switch", "--track", "--", name } else &.{ "switch", "--no-guess", "--", name });
        self.allocator.free(output);
    }
    pub fn stashSave(self: *Repository, include_untracked: bool) !void {
        const output = try self.command(self.allocator, if (include_untracked) &.{ "--no-literal-pathspecs", "stash", "push", "--include-untracked", "--message", "Zircon stash" } else &.{ "--no-literal-pathspecs", "stash", "push", "--message", "Zircon stash" });
        self.allocator.free(output);
    }
    pub fn stashApply(self: *Repository, oid: []const u8, pop: bool) !void {
        if (!history_module.validOid(oid)) return error.InvalidGitReferences;
        const output = try self.command(self.allocator, &.{ "stash", "apply", "--", oid });
        self.allocator.free(output);
        if (pop) {
            var refs = try self.references(self.allocator);
            defer refs.deinit();
            for (refs.stashes) |stash| if (std.mem.eql(u8, stash.oid, oid)) {
                const dropped = try self.command(self.allocator, &.{ "stash", "drop", "--", stash.reference });
                self.allocator.free(dropped);
                return;
            };
            return error.StashMoved;
        }
    }
    pub fn stashDiff(self: *Repository, a: std.mem.Allocator, oid: []const u8) !Diff {
        if (!history_module.validOid(oid)) return error.InvalidGitReferences;
        const output = try self.command(a, &.{ "stash", "show", "--patch", "--include-untracked", oid, "--" });
        defer a.free(output);
        return diff_module.parse(a, output);
    }
    pub fn commitMessage(self: *Repository, a: std.mem.Allocator, oid: []const u8) ![]u8 {
        if (!history_module.validOid(oid)) return error.InvalidGitHistory;
        return self.command(a, &.{ "show", "-s", "--format=%B", oid, "--" });
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
    _ = parser_tests;
    _ = numstat;
}

fn stripLineEnding(bytes: []const u8) []const u8 {
    return if (std.mem.endsWith(u8, bytes, "\n")) bytes[0 .. bytes.len - 1] else bytes;
}

fn validateRefArgument(value: []const u8) !void {
    if (value.len == 0 or value[0] == '-' or std.mem.indexOfAny(u8, value, "\x00\r\n") != null or std.mem.indexOf(u8, value, "@{") != null) return error.InvalidGitReference;
}

/// Bound work on untracked files and never follow a symlink outside the repo.
/// Unreadable, changing, oversized and nonregular files retain unknown counts.
fn countNewFile(io: std.Io, dir: std.Io.Dir, path: []const u8, remaining: *u64) !LineStats {
    try validatePath(path);
    const before = try dir.statFile(io, path, .{ .follow_symlinks = false });
    if (before.kind == .sym_link) {
        var link: [std.fs.max_path_bytes]u8 = undefined;
        const length = try dir.readLink(io, path, &link);
        return countBytes(link[0..length]);
    }
    if (before.kind != .file or before.size > remaining.*) return error.UnknownGitLineCounts;
    remaining.* -= before.size;
    const file = try dir.openFile(io, path, .{ .follow_symlinks = false });
    defer file.close(io);
    const opened = try file.stat(io);
    if (!sameFile(before, opened)) return error.ChangingGitFile;
    var buffer: [32 * 1024]u8 = undefined;
    var offset: u64 = 0;
    var added: u64 = 0;
    var last: ?u8 = null;
    while (offset < before.size) {
        const length: usize = @intCast(@min(buffer.len, before.size - offset));
        const read = try file.readPositionalAll(io, buffer[0..length], offset);
        if (read != length) return error.ChangingGitFile;
        // Git's binary heuristic examines the first 8000 bytes.
        if (offset < 8000 and std.mem.indexOfScalar(u8, buffer[0..@min(read, @as(usize, @intCast(8000 - offset)))], 0) != null) return .{ .binary = true };
        added += std.mem.count(u8, buffer[0..read], "\n");
        last = buffer[read - 1];
        offset += read;
    }
    if (!sameFile(before, try file.stat(io)) or !sameFile(before, try dir.statFile(io, path, .{ .follow_symlinks = false }))) return error.ChangingGitFile;
    return .{ .added = added + @intFromBool(last != null and last.? != '\n') };
}
fn countBytes(bytes: []const u8) LineStats {
    if (std.mem.indexOfScalar(u8, bytes[0..@min(bytes.len, 8000)], 0) != null) return .{ .binary = true };
    return .{ .added = std.mem.count(u8, bytes, "\n") + @intFromBool(bytes.len > 0 and bytes[bytes.len - 1] != '\n') };
}
fn sameFile(a: std.Io.File.Stat, b: std.Io.File.Stat) bool {
    return a.kind == b.kind and a.inode == b.inode and a.size == b.size and a.mtime.nanoseconds == b.mtime.nanoseconds and a.ctime.nanoseconds == b.ctime.nanoseconds;
}
