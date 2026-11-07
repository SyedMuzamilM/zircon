const std = @import("std");
const workspace = @import("zircon_workspace");
const t = std.testing;
const Mapping = std.meta.Elem(@TypeOf(@as(workspace.DocumentChange, undefined).mappings));

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
    try t.expectEqual(@as(u64, 0), event.before);
    try t.expectEqual(@as(u64, 1), event.after);
    try t.expectEqual(@as(usize, 1), event.mappings.len);
    try t.expectError(error.StaleRevision, project.apply(id, 0, &.{.{ .range = .{ .start = 0, .end = 0 }, .text = "stale" }}, 7, .agent));
}

test "recent change history bounds count and mapping bytes while retaining the newest events" {
    var log: workspace.ChangeLog = .{};
    defer log.clear();
    const id: workspace.DocumentId = .{ .workspace = 1, .slot = 0, .generation = 1 };
    for (0..workspace.ChangeLog.capacity + 20) |revision| {
        const mappings = try t.allocator.alloc(Mapping, 1);
        mappings[0] = .{ .range = .{ .start = 0, .end = 0 }, .inserted = 1 };
        log.push(.{ .allocator = t.allocator, .document = id, .origin = .typing, .before = revision, .after = revision + 1, .state = revision + 1, .mappings = mappings });
    }
    try t.expectEqual(workspace.ChangeLog.capacity, log.len);
    try t.expectEqual(@as(u64, 20), log.get(0).?.before);
    try t.expectEqual(@as(u64, workspace.ChangeLog.capacity + 20), log.get(log.len - 1).?.after);
    const large = try t.allocator.alloc(Mapping, workspace.ChangeLog.max_mapping_bytes / @sizeOf(Mapping));
    log.push(.{ .allocator = t.allocator, .document = id, .origin = .project_edit, .before = 200, .after = 201, .state = 201, .mappings = large });
    try t.expectEqual(@as(usize, 1), log.len);
    const oversized = try t.allocator.alloc(Mapping, large.len + 1);
    log.push(.{ .allocator = t.allocator, .document = id, .origin = .project_edit, .before = 201, .after = 202, .state = 202, .mappings = oversized });
    try t.expectEqual(@as(usize, 1), log.len);
    try t.expect(log.mapping_bytes <= workspace.ChangeLog.max_mapping_bytes);
    log.clear();
    try t.expectEqual(@as(usize, 0), log.mapping_bytes);
}

fn allocationCase(allocator: std.mem.Allocator, root: []const u8) !void {
    var project = try workspace.Workspace.init(allocator, t.io, root);
    defer project.deinit();
    const id = try project.untitled("before");
    var event = project.apply(id, 0, &.{.{ .range = .{ .start = 0, .end = 6 }, .text = "after" }}, 0, .typing) catch |err| {
        const record = try project.getConst(id);
        try t.expectEqual(@as(u64, 0), record.doc.revision());
        var source = record.doc.snapshot();
        defer source.deinit();
        const bytes = try source.copy(t.allocator, .{ .start = 0, .end = source.byteLen() });
        defer t.allocator.free(bytes);
        try t.expectEqualStrings("before", bytes);
        return err;
    };
    defer event.deinit();
    try t.expectEqual(@as(u64, 1), event.after);
}
test "failed workspace apply never commits text without its event" {
    var temp = t.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    try t.checkAllAllocationFailures(t.allocator, allocationCase, .{root});
}
