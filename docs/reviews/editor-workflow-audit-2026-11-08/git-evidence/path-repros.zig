const std = @import("std");
const builtin = @import("builtin");
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

test "audit quoted Git paths preserve source identity" {
    var temp = t.tmpDir(.{});
    defer temp.cleanup();
    const root = try init(&temp);
    defer t.allocator.free(root);
    var repo = (try git.Repository.discover(t.allocator, t.io, root)).?;
    defer repo.deinit();
    const path = "line\nname.txt";
    try temp.dir.writeFile(t.io, .{ .sub_path = path, .data = "before\n" });
    try repo.stage(&.{path});
    try repo.commit("baseline");
    try temp.dir.writeFile(t.io, .{ .sub_path = path, .data = "after\n" });
    var status = try repo.status(t.allocator);
    defer status.deinit();
    var diff = try repo.diff(t.allocator, path, false);
    defer diff.deinit();
    try t.expectEqual(@as(usize, 1), diff.hunks.len);
    std.debug.print("status actual path {any}; parsed hunk path {any}\n", .{status.entries[0].path, diff.hunks[0].path});
    try t.expectEqualStrings(status.entries[0].path, diff.hunks[0].path);
}
test "audit binary patches have metadata without text hunks" {
    var temp = t.tmpDir(.{});
    defer temp.cleanup();
    const root = try init(&temp);
    defer t.allocator.free(root);
    var repo = (try git.Repository.discover(t.allocator, t.io, root)).?;
    defer repo.deinit();
    try temp.dir.writeFile(t.io, .{ .sub_path = "binary.dat", .data = "before\x00bytes" });
    try repo.stage(&.{"binary.dat"});
    try repo.commit("baseline");
    try temp.dir.writeFile(t.io, .{ .sub_path = "binary.dat", .data = "after\x00bytes" });
    var diff = try repo.allChanges(t.allocator);
    defer diff.deinit();
    std.debug.print("binary patch bytes={d}, exposed hunks={d}\n{s}\n", .{diff.text.len, diff.hunks.len, diff.text});
    try t.expect(diff.text.len > 0);
    try t.expectEqual(@as(usize, 0), diff.hunks.len);
}
test "audit space Git paths preserve source identity" {
    var temp = t.tmpDir(.{});
    defer temp.cleanup();
    const root = try init(&temp);
    defer t.allocator.free(root);
    var repo = (try git.Repository.discover(t.allocator, t.io, root)).?;
    defer repo.deinit();
    const path = "space name.txt";
    try temp.dir.writeFile(t.io, .{ .sub_path = path, .data = "before\n" });
    try repo.stage(&.{path});
    try repo.commit("baseline");
    try temp.dir.writeFile(t.io, .{ .sub_path = path, .data = "after\n" });
    var status = try repo.status(t.allocator);
    defer status.deinit();
    var diff = try repo.diff(t.allocator, path, false);
    defer diff.deinit();
    try t.expectEqual(@as(usize, 1), diff.hunks.len);
    std.debug.print("status actual path {any}; parsed hunk path {any}\n", .{status.entries[0].path, diff.hunks[0].path});
    try t.expectEqualStrings(status.entries[0].path, diff.hunks[0].path);
}
