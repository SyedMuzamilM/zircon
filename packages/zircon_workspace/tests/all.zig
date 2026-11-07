const std = @import("std");
const workspace = @import("zircon_workspace");
const t = std.testing;
fn rootPath(temp: *t.TmpDir, a: std.mem.Allocator) ![]u8 {
    var buffer: [4096]u8 = undefined;
    const n = try temp.dir.realPath(t.io, &buffer);
    return a.dupe(u8, buffer[0..n]);
}
fn contents(project: *const workspace.Workspace, id: workspace.DocumentId) ![]u8 {
    var snapshot = try project.snapshot(id);
    defer snapshot.deinit();
    return snapshot.copy(t.allocator, .{ .start = 0, .end = snapshot.byteLen() });
}
fn append(project: *workspace.Workspace, id: workspace.DocumentId, bytes: []const u8) !void {
    const record = try project.get(id);
    var snapshot = record.doc.snapshot();
    defer snapshot.deinit();
    var change = try record.doc.apply(record.doc.revision(), &.{.{ .range = .{ .start = snapshot.byteLen(), .end = snapshot.byteLen() }, .text = bytes }}, 0);
    change.deinit();
}
test "open canonical paths deduplicates symlinks and preserves CRLF bytes" {
    var temp = t.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    try temp.dir.writeFile(t.io, .{ .sub_path = "source.zig", .data = "const a = 1;\r\n日本語\r\n" });
    try temp.dir.symLink(t.io, "source.zig", "alias.zig", .{});
    const root = try rootPath(&temp, t.allocator);
    defer t.allocator.free(root);
    var project = try workspace.Workspace.init(t.allocator, t.io, root);
    defer project.deinit();
    const id = try project.open("source.zig");
    try t.expectEqual(id, try project.open("alias.zig"));
    const bytes = try contents(&project, id);
    defer t.allocator.free(bytes);
    try t.expectEqualStrings("const a = 1;\r\n日本語\r\n", bytes);
    try t.expect(!(try project.dirty(id)));
    try t.expectEqualStrings("source.zig", (try project.get(id)).title());
}
test "atomic save preserves permissions and undo to saved content clears dirty state" {
    var temp = t.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    try temp.dir.writeFile(t.io, .{ .sub_path = "source.txt", .data = "saved" });
    const file = try temp.dir.openFile(t.io, "source.txt", .{});
    defer file.close(t.io);
    const permissions = std.Io.File.Permissions.fromMode(0o640);
    try file.setPermissions(t.io, permissions);
    const root = try rootPath(&temp, t.allocator);
    defer t.allocator.free(root);
    var project = try workspace.Workspace.init(t.allocator, t.io, root);
    defer project.deinit();
    const id = try project.open("source.txt");
    try append(&project, id, "!");
    try t.expect(try project.dirty(id));
    try project.save(id, null);
    try t.expect(!(try project.dirty(id)));
    const bytes = try temp.dir.readFileAlloc(t.io, "source.txt", t.allocator, .limited(100));
    defer t.allocator.free(bytes);
    try t.expectEqualStrings("saved!", bytes);
    const stat = try temp.dir.statFile(t.io, "source.txt", .{});
    try t.expectEqual(permissions.toMode() & 0o7777, stat.permissions.toMode() & 0o7777);
    try append(&project, id, "new");
    try t.expect(try project.dirty(id));
    try t.expect(try (try project.get(id)).doc.undo());
    try t.expect(!(try project.dirty(id)));
    // A second save checks the new replacement's stamp, not the old inode.
    try append(&project, id, "again");
    try project.save(id, null);
}
test "external disk changes refuse saving without changing disk or saved marker" {
    var temp = t.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    try temp.dir.writeFile(t.io, .{ .sub_path = "source.txt", .data = "before" });
    const root = try rootPath(&temp, t.allocator);
    defer t.allocator.free(root);
    var project = try workspace.Workspace.init(t.allocator, t.io, root);
    defer project.deinit();
    const id = try project.open("source.txt");
    try append(&project, id, "local");
    try temp.dir.writeFile(t.io, .{ .sub_path = "source.txt", .data = "external" });
    try t.expectError(error.DiskConflict, project.save(id, null));
    try t.expect(try project.dirty(id));
    const bytes = try temp.dir.readFileAlloc(t.io, "source.txt", t.allocator, .limited(100));
    defer t.allocator.free(bytes);
    try t.expectEqualStrings("external", bytes);
}
test "save as publishes new files and leaves untitled identity intact on failure" {
    var temp = t.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    try temp.dir.writeFile(t.io, .{ .sub_path = "exists.txt", .data = "other" });
    const root = try rootPath(&temp, t.allocator);
    defer t.allocator.free(root);
    var project = try workspace.Workspace.init(t.allocator, t.io, root);
    defer project.deinit();
    const id = try project.untitled("Hello 🙂\n");
    try t.expectError(error.SavePathRequired, project.save(id, null));
    try t.expectError(error.PathAlreadyExists, project.save(id, "exists.txt"));
    try t.expectError(error.FileNotFound, project.save(id, "missing/target.txt"));
    try t.expect((try project.get(id)).path == null);
    try t.expect(try project.dirty(id));
    try project.save(id, "new.txt");
    try t.expect(!(try project.dirty(id)));
    const bytes = try temp.dir.readFileAlloc(t.io, "new.txt", t.allocator, .limited(100));
    defer t.allocator.free(bytes);
    try t.expectEqualStrings("Hello 🙂\n", bytes);
    try t.expectEqual(id, try project.open("new.txt"));
}
test "dirty close decisions protect documents and generational ids reject replacements" {
    var temp = t.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    const root = try rootPath(&temp, t.allocator);
    defer t.allocator.free(root);
    var project = try workspace.Workspace.init(t.allocator, t.io, root);
    defer project.deinit();
    const id = try project.untitled("unsaved");
    try t.expectError(error.UnsavedChanges, project.close(id, .if_clean));
    try t.expect(!try project.close(id, .cancel));
    try t.expectError(error.SavePathRequired, project.close(id, .save));
    try t.expect(try project.close(id, .discard));
    const replacement = try project.untitled("");
    try t.expectEqual(id.slot, replacement.slot);
    try t.expect(id.generation != replacement.generation);
    try t.expectError(error.DocumentNotFound, project.get(id));
    try t.expect(try project.close(replacement, .if_clean));
}
test "project listing is lazy sorted directory first and excludes build internals" {
    var temp = t.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    try temp.dir.createDir(t.io, "src", .default_dir);
    try temp.dir.createDir(t.io, ".git", .default_dir);
    try temp.dir.createDir(t.io, "node_modules", .default_dir);
    try temp.dir.writeFile(t.io, .{ .sub_path = "z.txt", .data = "z" });
    try temp.dir.writeFile(t.io, .{ .sub_path = "A.txt", .data = "a" });
    try temp.dir.symLink(t.io, "missing", "broken", .{});
    const root = try rootPath(&temp, t.allocator);
    defer t.allocator.free(root);
    var project = try workspace.Workspace.init(t.allocator, t.io, root);
    defer project.deinit();
    const entries = try project.children(".", t.allocator);
    defer workspace.deinitEntries(entries, t.allocator);
    try t.expectEqual(@as(usize, 3), entries.len);
    try t.expectEqualStrings("src", entries[0].name);
    try t.expectEqualStrings("A.txt", entries[1].name);
    try t.expectEqualStrings("z.txt", entries[2].name);
}
test "invalid UTF8 and binary files are explicit load errors" {
    var temp = t.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    try temp.dir.writeFile(t.io, .{ .sub_path = "invalid", .data = "\xff" });
    try temp.dir.writeFile(t.io, .{ .sub_path = "binary", .data = "hello\x00" });
    const root = try rootPath(&temp, t.allocator);
    defer t.allocator.free(root);
    var project = try workspace.Workspace.init(t.allocator, t.io, root);
    defer project.deinit();
    try t.expectError(error.InvalidUtf8, project.open("invalid"));
    try t.expectError(error.BinaryFile, project.open("binary"));
}
test "failed preparation releases all workspace and document ownership" {
    try t.checkAllAllocationFailures(t.allocator, allocationCase, .{});
}
fn allocationCase(a: std.mem.Allocator) !void {
    var temp = t.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    const root = try rootPath(&temp, t.allocator);
    defer t.allocator.free(root);
    var project = try workspace.Workspace.init(a, t.io, root);
    defer project.deinit();
    const id = try project.untitled("text");
    try project.save(id, "new.txt");
    const entries = try project.children(".", a);
    defer workspace.deinitEntries(entries, a);
}

test "real permission failure leaves original file and unsaved document intact" {
    var temp = t.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    try temp.dir.writeFile(t.io, .{ .sub_path = "source.txt", .data = "original" });
    const root = try rootPath(&temp, t.allocator);
    defer t.allocator.free(root);
    var project = try workspace.Workspace.init(t.allocator, t.io, root);
    defer project.deinit();
    const id = try project.open("source.txt");
    try append(&project, id, "local");
    const old_saved = (try project.get(id)).saved_state;
    try temp.dir.setPermissions(t.io, .fromMode(0o500));
    defer temp.dir.setPermissions(t.io, .default_dir) catch {};
    if (project.save(id, null)) |_| return error.ExpectedPermissionFailure else |err| {
        try t.expect(err == error.PermissionDenied or err == error.AccessDenied or err == error.ReadOnlyFileSystem);
    }
    try t.expect(try project.dirty(id));
    try t.expectEqual(old_saved, (try project.get(id)).saved_state);
    const bytes = try temp.dir.readFileAlloc(t.io, "source.txt", t.allocator, .limited(100));
    defer t.allocator.free(bytes);
    try t.expectEqualStrings("original", bytes);
}
test "document identities cannot resolve in a different workspace" {
    var temp = t.tmpDir(.{});
    defer temp.cleanup();
    const root = try rootPath(&temp, t.allocator);
    defer t.allocator.free(root);
    var first = try workspace.Workspace.init(t.allocator, t.io, root);
    defer first.deinit();
    var second = try workspace.Workspace.init(t.allocator, t.io, root);
    defer second.deinit();
    const id = try first.untitled("");
    _ = try second.untitled("");
    try t.expectError(error.WrongWorkspace, second.get(id));
    try t.expectError(error.WrongWorkspace, second.snapshot(id));
    try t.expectError(error.WrongWorkspace, second.close(id, .discard));
}

test "oversized files are refused before loading sparse content" {
    var temp = t.tmpDir(.{});
    defer temp.cleanup();
    const file = try temp.dir.createFile(t.io, "large.txt", .{});
    defer file.close(t.io);
    try file.setLength(t.io, workspace.max_file_bytes + 1);
    const root = try rootPath(&temp, t.allocator);
    defer t.allocator.free(root);
    var project = try workspace.Workspace.init(t.allocator, t.io, root);
    defer project.deinit();
    try t.expectError(error.FileTooLarge, project.open("large.txt"));
}

test "binary edit cannot replace a file that the workspace would refuse to reopen" {
    var temp = t.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(t.io, .{ .sub_path = "source.txt", .data = "text" });
    const root = try rootPath(&temp, t.allocator);
    defer t.allocator.free(root);
    var project = try workspace.Workspace.init(t.allocator, t.io, root);
    defer project.deinit();
    const id = try project.open("source.txt");
    try append(&project, id, "\x00");
    try t.expectError(error.BinaryFile, project.save(id, null));
    try t.expect(try project.dirty(id));
    const bytes = try temp.dir.readFileAlloc(t.io, "source.txt", t.allocator, .limited(100));
    defer t.allocator.free(bytes);
    try t.expectEqualStrings("text", bytes);
}

test {
    _ = @import("recovery.zig");
}
