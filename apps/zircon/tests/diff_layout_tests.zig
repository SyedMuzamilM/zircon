const std = @import("std");
const zircon = @import("zircon");
const t = std.testing;
fn run(root: []const u8, args: []const []const u8) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(t.allocator);
    try argv.appendSlice(t.allocator, &.{ "git", "-C", root });
    try argv.appendSlice(t.allocator, args);
    const result = try std.process.run(t.allocator, t.io, .{ .argv = argv.items });
    defer t.allocator.free(result.stdout);
    defer t.allocator.free(result.stderr);
    try t.expect(result.term.success());
}
test "diff projection groups files and shares collapse offsets between unified and split rows" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    try run(root, &.{ "init", "-q", "-b", "main" });
    try run(root, &.{ "config", "user.name", "Projection" });
    try run(root, &.{ "config", "user.email", "projection@example.invalid" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "one.txt", .data = "a\nb\nc\n" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "two.txt", .data = "x\ny\n" });
    try run(root, &.{ "add", "." });
    try run(root, &.{ "commit", "-qm", "base" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "one.txt", .data = "a\nB\nc\nd\n" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "two.txt", .data = "x\nY\n" });
    var repo = (try zircon.git.Repository.discover(t.allocator, t.io, root)).?;
    defer repo.deinit();
    var diff = try repo.allChanges(t.allocator);
    defer diff.deinit();
    var projection = try zircon.diff_layout.Projection.init(t.allocator, diff);
    defer projection.deinit();
    try t.expectEqual(@as(usize, 2), projection.files.len);
    try t.expectEqualStrings("one.txt", projection.files[0].path);
    try t.expectEqual(@as(usize, 2), projection.files[0].added);
    try t.expectEqual(@as(usize, 1), projection.files[0].deleted);
    try t.expect(projection.files[0].split.len > 0 and projection.files[0].unified.len > 0);
    var state: zircon.diff_layout.State = .{};
    defer state.deinit(t.allocator);
    const full = projection.contentHeight(&state, 18);
    try state.toggle(t.allocator, "one.txt");
    const collapsed = projection.contentHeight(&state, 18);
    try t.expect(collapsed < full);
    try t.expectEqual(@as(?f32, 0), projection.fileOffset(&state, "one.txt", 18));
    state.expandAll(t.allocator);
    try t.expectEqual(full, projection.contentHeight(&state, 18));
}
