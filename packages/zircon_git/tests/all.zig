const std = @import("std");
const git = @import("zircon_git");
const t = std.testing;
fn run(root: []const u8, args: []const []const u8) ![]u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(t.allocator);
    try argv.appendSlice(t.allocator, &.{ "git", "-C", root });
    try argv.appendSlice(t.allocator, args);
    const result = try std.process.run(t.allocator, t.io, .{ .argv = argv.items });
    defer t.allocator.free(result.stderr);
    errdefer t.allocator.free(result.stdout);
    if (result.term != .exited or result.term.exited != 0) {
        std.debug.print("Git fixture failed: {s}\n", .{result.stderr});
        return error.FixtureGitFailed;
    }
    return result.stdout;
}
fn command(root: []const u8, args: []const []const u8) !void {
    const bytes = try run(root, args);
    t.allocator.free(bytes);
}
fn init(temp: *t.TmpDir) ![:0]u8 {
    const root = try temp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    errdefer t.allocator.free(root);
    try command(root, &.{ "init", "-b", "main" });
    try command(root, &.{ "config", "user.name", "Zircon Tests" });
    try command(root, &.{ "config", "user.email", "zircon@example.invalid" });
    return root;
}
test "unborn repository status staging and unstaging preserve file bytes" {
    var temp = t.tmpDir(.{});
    defer temp.cleanup();
    const root = try init(&temp);
    defer t.allocator.free(root);
    var repo = (try git.Repository.discover(t.allocator, t.io, root)).?;
    defer repo.deinit();
    try temp.dir.writeFile(t.io, .{ .sub_path = "日本 file\nname.txt", .data = "first\n" });
    var status = try repo.status(t.allocator);
    defer status.deinit();
    try t.expect(status.unborn);
    try t.expectEqualStrings("main", status.branch);
    try t.expectEqual(@as(usize, 1), status.entries.len);
    try t.expectEqualStrings("日本 file\nname.txt", status.entries[0].path);
    try t.expect(status.entries[0].index == .untracked);
    var new_file = try repo.diff(t.allocator, "日本 file\nname.txt", false);
    defer new_file.deinit();
    try t.expectEqual(@as(usize, 1), new_file.hunks.len);
    try t.expect(new_file.hunks[0].lines[0].kind == .addition);
    try t.expectEqualStrings("first", new_file.hunks[0].lines[0].text);
    try repo.stage(&.{"日本 file\nname.txt"});
    var staged = try repo.status(t.allocator);
    defer staged.deinit();
    try t.expect(staged.entries[0].staged);
    try repo.unstage(&.{"日本 file\nname.txt"});
    var unstaged = try repo.status(t.allocator);
    defer unstaged.deinit();
    try t.expect(unstaged.entries[0].index == .untracked);
    const bytes = try temp.dir.readFileAlloc(t.io, "日本 file\nname.txt", t.allocator, .limited(100));
    defer t.allocator.free(bytes);
    try t.expectEqualStrings("first\n", bytes);
    const history = try repo.history(t.allocator, 10);
    defer git.deinitHistory(t.allocator, history);
    try t.expectEqual(@as(usize, 0), history.len);
}
test "status diff history blame and explicit commits use actual repository state" {
    var temp = t.tmpDir(.{});
    defer temp.cleanup();
    const root = try init(&temp);
    defer t.allocator.free(root);
    var repo = (try git.Repository.discover(t.allocator, t.io, root)).?;
    defer repo.deinit();
    try temp.dir.writeFile(t.io, .{ .sub_path = "source.txt", .data = "one\ntwo\nthree\n" });
    try repo.stage(&.{"source.txt"});
    try repo.commit("Initial content");
    try temp.dir.writeFile(t.io, .{ .sub_path = "source.txt", .data = "one\nchanged\nthree\n" });
    var diff = try repo.diff(t.allocator, "source.txt", false);
    defer diff.deinit();
    try t.expectEqual(@as(usize, 1), diff.hunks.len);
    try t.expectEqual(@as(usize, 1), diff.hunks[0].old_start);
    try t.expect(std.mem.indexOf(u8, diff.text, "+changed") != null);
    const baseline = try repo.baseline(t.allocator, "source.txt", .index);
    defer t.allocator.free(baseline);
    try t.expectEqualStrings("one\ntwo\nthree\n", baseline);
    try repo.stage(&.{"source.txt"});
    var staged = try repo.diff(t.allocator, "source.txt", true);
    defer staged.deinit();
    try t.expect(staged.hunks.len == 1);
    try repo.commit("Change middle line\n\nA full commit message.");
    const commits = try repo.history(t.allocator, 10);
    defer git.deinitHistory(t.allocator, commits);
    try t.expectEqual(@as(usize, 2), commits.len);
    try t.expectEqualStrings("Change middle line", commits[0].subject);
    try t.expectEqualStrings("Zircon Tests", commits[0].author);
    var historical = try repo.commitDiff(t.allocator, commits[0].oid, "source.txt");
    defer historical.deinit();
    try t.expect(std.mem.indexOf(u8, historical.text, "+changed") != null);
    const original = try repo.fileAt(t.allocator, commits[1].oid, "source.txt");
    defer t.allocator.free(original);
    try t.expectEqualStrings("one\ntwo\nthree\n", original);
    try t.expectError(error.InvalidObjectId, repo.fileAt(t.allocator, "--all", "source.txt"));
    var blame = try repo.blame(t.allocator, "source.txt", 2, null);
    defer blame.deinit();
    try t.expectEqualStrings(commits[0].oid, blame.oid);
    try t.expectEqualStrings("changed", blame.contents);
    try t.expect(!blame.uncommitted);
    var unsaved = try repo.blame(t.allocator, "source.txt", 2, "one\nnot saved\nthree\n");
    defer unsaved.deinit();
    try t.expect(unsaved.uncommitted);
    try t.expectEqualStrings("not saved", unsaved.contents);
    try repo.unstage(&.{"source.txt"});
}
test "rename and detached HEAD preserve exact paths and report branch mode" {
    var temp = t.tmpDir(.{});
    defer temp.cleanup();
    const root = try init(&temp);
    defer t.allocator.free(root);
    var repo = (try git.Repository.discover(t.allocator, t.io, root)).?;
    defer repo.deinit();
    try temp.dir.writeFile(t.io, .{ .sub_path = "old name.txt", .data = "same bytes\n" });
    try repo.stage(&.{"old name.txt"});
    try repo.commit("Initial");
    try command(root, &.{ "mv", "old name.txt", "new\n日本.txt" });
    var status = try repo.status(t.allocator);
    defer status.deinit();
    try t.expectEqualStrings("new\n日本.txt", status.entries[0].path);
    try t.expectEqualStrings("old name.txt", status.entries[0].old_path.?);
    try t.expect(status.entries[0].index == .renamed);
    try repo.commit("Rename");
    try command(root, &.{ "checkout", "--detach", "HEAD" });
    var detached = try repo.status(t.allocator);
    defer detached.deinit();
    try t.expect(detached.detached);
}
test "failed operations retain files and reject escaping paths" {
    var temp = t.tmpDir(.{});
    defer temp.cleanup();
    const root = try init(&temp);
    defer t.allocator.free(root);
    var repo = (try git.Repository.discover(t.allocator, t.io, root)).?;
    defer repo.deinit();
    try temp.dir.writeFile(t.io, .{ .sub_path = "source.txt", .data = "retain" });
    try t.expectError(error.InvalidPath, repo.stage(&.{"../outside"}));
    try t.expectError(error.InvalidPath, repo.stage(&.{".git/config"}));
    try t.expectError(error.InvalidCommitMessage, repo.commit(" \n"));
    try t.expectError(error.GitCommandFailed, repo.stage(&.{"missing.txt"}));
    try t.expect(repo.lastError().len > 0);
    const bytes = try temp.dir.readFileAlloc(t.io, "source.txt", t.allocator, .limited(100));
    defer t.allocator.free(bytes);
    try t.expectEqualStrings("retain", bytes);
    try t.expectError(error.GitCommandFailed, repo.commit("No staged content"));
    var status = try repo.status(t.allocator);
    defer status.deinit();
    try t.expectEqual(@as(usize, 1), status.entries.len);
}
test "line diff maps insert modification deletion and EOF without quadratic unbounded work" {
    const changes = try git.diffLines(t.allocator, "a\nb\nc\nd\n", "a\nB\nc\nd\ne\n");
    defer t.allocator.free(changes);
    try t.expectEqual(@as(usize, 2), changes.len);
    try t.expect(changes[0].kind == .modified);
    try t.expectEqual(@as(usize, 1), changes[0].start);
    try t.expect(changes[1].kind == .added);
    try t.expectEqual(@as(usize, 4), changes[1].start);
    const deleted = try git.diffLines(t.allocator, "a\nb\n", "a\n");
    defer t.allocator.free(deleted);
    try t.expect(deleted[0].kind == .deleted);
    try t.expectEqual(@as(usize, 1), deleted[0].start);
    const same = try git.diffLines(t.allocator, "日本\n", "日本\n");
    defer t.allocator.free(same);
    try t.expectEqual(@as(usize, 0), same.len);
}
test "bare repositories have no worktree and are not accepted as editor repositories" {
    var temp = t.tmpDir(.{});
    defer temp.cleanup();
    const path = try temp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(path);
    try command(path, &.{ "init", "--bare" });
    try t.expect((try git.Repository.discover(t.allocator, t.io, path)) == null);
}

test "literal pathspecs stage only the named file even when its name resembles Git magic" {
    var temp = t.tmpDir(.{});
    defer temp.cleanup();
    const root = try init(&temp);
    defer t.allocator.free(root);
    var repo = (try git.Repository.discover(t.allocator, t.io, root)).?;
    defer repo.deinit();
    try temp.dir.writeFile(t.io, .{ .sub_path = ":(glob)*", .data = "literal" });
    try temp.dir.writeFile(t.io, .{ .sub_path = "other.txt", .data = "keep untracked" });
    try repo.stage(&.{":(glob)*"});
    var status = try repo.status(t.allocator);
    defer status.deinit();
    var staged: usize = 0;
    for (status.entries) |entry| if (entry.staged) {
        staged += 1;
        try t.expectEqualStrings(":(glob)*", entry.path);
    };
    try t.expectEqual(@as(usize, 1), staged);
}
test "failed commit hook leaves index and worktree available for retry" {
    var temp = t.tmpDir(.{});
    defer temp.cleanup();
    const root = try init(&temp);
    defer t.allocator.free(root);
    var repo = (try git.Repository.discover(t.allocator, t.io, root)).?;
    defer repo.deinit();
    try temp.dir.writeFile(t.io, .{ .sub_path = "file.txt", .data = "retain" });
    try repo.stage(&.{"file.txt"});
    const hook = try temp.dir.createFile(t.io, ".git/hooks/pre-commit", .{ .permissions = .fromMode(0o755) });
    try hook.writeStreamingAll(t.io, "#!/bin/sh\nprintf 'fixture hook rejected\\n' >&2\nexit 1\n");
    hook.close(t.io);
    try t.expectError(error.GitCommandFailed, repo.commit("Rejected commit"));
    try t.expect(std.mem.indexOf(u8, repo.lastError(), "fixture hook rejected") != null);
    var status = try repo.status(t.allocator);
    defer status.deinit();
    try t.expect(status.entries[0].staged);
    const commits = try repo.history(t.allocator, 10);
    defer git.deinitHistory(t.allocator, commits);
    try t.expectEqual(@as(usize, 0), commits.len);
}
test "untracked baselines are empty and path conversion rejects sibling directories" {
    var temp = t.tmpDir(.{});
    defer temp.cleanup();
    const root = try init(&temp);
    defer t.allocator.free(root);
    var repo = (try git.Repository.discover(t.allocator, t.io, root)).?;
    defer repo.deinit();
    const empty = try repo.baseline(t.allocator, "missing.txt", .index);
    defer t.allocator.free(empty);
    try t.expectEqual(@as(usize, 0), empty.len);
    const head = try repo.baseline(t.allocator, "missing.txt", .head);
    defer t.allocator.free(head);
    try t.expectEqual(@as(usize, 0), head.len);
    const absolute = try std.fs.path.join(t.allocator, &.{ root, "sub", "file.txt" });
    defer t.allocator.free(absolute);
    const relative = try repo.relativePath(t.allocator, absolute);
    defer t.allocator.free(relative);
    try t.expectEqualStrings("sub/file.txt", relative);
    try t.expectError(error.InvalidPath, repo.relativePath(t.allocator, "/outside/not-in-repository"));
}

test "branch stash and network workflows use real repositories and a local bare remote" {
    var local = t.tmpDir(.{});
    defer local.cleanup();
    var bare = t.tmpDir(.{});
    defer bare.cleanup();
    var peer = t.tmpDir(.{});
    defer peer.cleanup();
    const root = try init(&local);
    defer t.allocator.free(root);
    const remote = try bare.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(remote);
    const other = try peer.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(other);
    try command(remote, &.{ "init", "--bare", "-b", "main" });
    try local.dir.writeFile(t.io, .{ .sub_path = "source.txt", .data = "initial\n" });
    try command(root, &.{ "add", "source.txt" });
    try command(root, &.{ "commit", "-m", "Initial" });
    var repo = (try git.Repository.discover(t.allocator, t.io, root)).?;
    defer repo.deinit();
    try repo.switchBranch("feature/test", true, false);
    try repo.switchBranch("main", false, false);
    try t.expectError(error.InvalidGitReference, repo.switchBranch("--bad", true, false));
    try local.dir.writeFile(t.io, .{ .sub_path = "source.txt", .data = "changed\n" });
    try local.dir.writeFile(t.io, .{ .sub_path = "new.txt", .data = "untracked\n" });
    try repo.stashSave(false);
    var refs = try repo.references(t.allocator);
    try t.expectEqual(@as(usize, 2), refs.branches.len);
    try t.expectEqual(@as(usize, 1), refs.stashes.len);
    const oid = try t.allocator.dupe(u8, refs.stashes[0].oid);
    defer t.allocator.free(oid);
    refs.deinit();
    var patch = try repo.stashDiff(t.allocator, oid);
    try t.expect(std.mem.indexOf(u8, patch.text, "+changed") != null);
    patch.deinit();
    _ = try local.dir.statFile(t.io, "new.txt", .{});
    try repo.stashApply(oid, false);
    try command(root, &.{ "restore", "source.txt" });
    try repo.stashApply(oid, true);
    try repo.stashSave(true);
    try t.expectError(error.FileNotFound, local.dir.statFile(t.io, "new.txt", .{}));
    refs = try repo.references(t.allocator);
    const all_oid = try t.allocator.dupe(u8, refs.stashes[0].oid);
    defer t.allocator.free(all_oid);
    refs.deinit();
    patch = try repo.stashDiff(t.allocator, all_oid);
    try t.expect(std.mem.indexOf(u8, patch.text, "new.txt") != null);
    patch.deinit();
    try repo.stashApply(all_oid, true);
    try command(root, &.{ "add", "source.txt", "new.txt" });
    try command(root, &.{ "commit", "-m", "Changes" });
    try command(root, &.{ "remote", "add", "origin", remote });
    try repo.network(.{ .push = .{ .remote = "origin", .publish = true } });
    try command(root, &.{ "clone", remote, other });
    try command(other, &.{ "config", "user.name", "Peer" });
    try command(other, &.{ "config", "user.email", "peer@zircon.invalid" });
    try peer.dir.writeFile(t.io, .{ .sub_path = "source.txt", .data = "from peer\n" });
    try command(other, &.{ "add", "source.txt" });
    try command(other, &.{ "commit", "-m", "Peer change" });
    try command(other, &.{"push"});
    try repo.network(.{ .fetch = "origin" });
    refs = try repo.references(t.allocator);
    try t.expectEqual(@as(usize, 1), refs.remotes.len);
    var behind = false;
    for (refs.branches) |branch| if (std.mem.eql(u8, branch.name, "main")) {
        behind = std.mem.indexOf(u8, branch.tracking, "behind 1") != null;
    };
    refs.deinit();
    try t.expect(behind);
    try repo.network(.{ .pull = false });
    const pulled = try local.dir.readFileAlloc(t.io, "source.txt", t.allocator, .limited(1024));
    defer t.allocator.free(pulled);
    try t.expectEqualStrings("from peer\n", pulled);
    try command(other, &.{ "switch", "-c", "remote-feature" });
    try command(other, &.{ "push", "--set-upstream", "origin", "remote-feature" });
    try repo.network(.{ .fetch = "origin" });
    try repo.switchBranch("origin/remote-feature", false, true);
    var status = try repo.status(t.allocator);
    defer status.deinit();
    try t.expectEqualStrings("remote-feature", status.branch);
}

test "combined review includes staged unstaged and untracked files including an unborn repository" {
    var temp = t.tmpDir(.{});
    defer temp.cleanup();
    const root = try init(&temp);
    defer t.allocator.free(root);
    var repo = (try git.Repository.discover(t.allocator, t.io, root)).?;
    defer repo.deinit();
    try temp.dir.writeFile(t.io, .{ .sub_path = "staged.zig", .data = "const staged = 1;\n" });
    try repo.stage(&.{"staged.zig"});
    try temp.dir.writeFile(t.io, .{ .sub_path = "staged.zig", .data = "const staged = 2;\n" });
    var patch = try repo.allChanges(t.allocator);
    try t.expect(std.mem.indexOf(u8, patch.text, "+const staged = 2;") != null);
    try t.expect(std.mem.indexOf(u8, patch.text, "+const staged = 1;") == null);
    patch.deinit();
    try repo.stage(&.{"staged.zig"});
    try repo.commit("Initial");
    try temp.dir.writeFile(t.io, .{ .sub_path = "staged.zig", .data = "const staged = 3;\n" });
    try repo.stage(&.{"staged.zig"});
    try temp.dir.writeFile(t.io, .{ .sub_path = "working.zig", .data = "const working = true;\n" });
    try temp.dir.writeFile(t.io, .{ .sub_path = "untracked.zig", .data = "const untracked = true;\n" });
    patch = try repo.allChanges(t.allocator);
    defer patch.deinit();
    var staged = false;
    var working = false;
    var untracked = false;
    for (patch.hunks) |hunk| {
        if (std.mem.eql(u8, hunk.path, "staged.zig")) staged = true;
        if (std.mem.eql(u8, hunk.path, "working.zig")) working = true;
        if (std.mem.eql(u8, hunk.path, "untracked.zig")) untracked = true;
    }
    try t.expect(staged and working and untracked);
}

test "conflicting stash pop preserves its stash and reports the failed apply" {
    var temp = t.tmpDir(.{});
    defer temp.cleanup();
    const root = try init(&temp);
    defer t.allocator.free(root);
    var repo = (try git.Repository.discover(t.allocator, t.io, root)).?;
    defer repo.deinit();
    try temp.dir.writeFile(t.io, .{ .sub_path = "source.txt", .data = "base\n" });
    try repo.stage(&.{"source.txt"});
    try repo.commit("Base");
    try temp.dir.writeFile(t.io, .{ .sub_path = "source.txt", .data = "stashed\n" });
    try repo.stashSave(false);
    var refs = try repo.references(t.allocator);
    const oid = try t.allocator.dupe(u8, refs.stashes[0].oid);
    defer t.allocator.free(oid);
    refs.deinit();
    try temp.dir.writeFile(t.io, .{ .sub_path = "source.txt", .data = "different\n" });
    try repo.stage(&.{"source.txt"});
    try repo.commit("Different");
    try t.expectError(error.GitCommandFailed, repo.stashApply(oid, true));
    refs = try repo.references(t.allocator);
    defer refs.deinit();
    try t.expectEqual(@as(usize, 1), refs.stashes.len);
    try t.expectEqualStrings(oid, refs.stashes[0].oid);
    var status = try repo.status(t.allocator);
    defer status.deinit();
    try t.expect(status.entries[0].conflicted);
}
