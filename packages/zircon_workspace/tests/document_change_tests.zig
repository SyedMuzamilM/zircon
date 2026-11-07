const std = @import("std");
const workspace = @import("zircon_workspace");
const t = std.testing;

test "workspace document changes carry identity, revisions and origin" {
    var temp = t.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    var project = try workspace.Workspace.init(t.allocator, t.io, root);
    defer project.deinit();
    const id = try project.untitled("");
    var event = try project.apply(id, 0, &.{.{ .range = .{ .start = 0, .end = 0 }, .text = "hello" }}, 7, .typing);
    defer event.deinit();
    try t.expectEqual(id, event.document);
    try t.expectEqual(workspace.ChangeOrigin.typing, event.origin);
    try t.expectEqual(@as(u64, 0), event.change.before);
    try t.expectEqual(@as(u64, 1), event.change.after);
    try t.expectEqual(@as(usize, 1), event.change.mappings.len);
    try t.expectError(error.StaleRevision, project.apply(id, 0, &.{.{ .range = .{ .start = 0, .end = 0 }, .text = "stale" }}, 7, .agent));
}
