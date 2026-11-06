const std = @import("std");
const extensions = @import("zircon_extensions");
const t = std.testing;
test "theme color parsing preserves alpha and rejects malformed values" {
    try t.expectEqual(@as(u32, 0x123456ff), (try extensions.Color.parse("#123456")).rgba);
    try t.expectEqual(@as(u32, 0x12345678), (try extensions.Color.parse("#12345678")).rgba);
    try t.expectError(error.InvalidColor, extensions.Color.parse("red"));
}

const fixture =
    \\{"schema_version":1,"id":"org.example.test","name":"Test contributions","version":"1.0.0","contributes":{"themes":[{"id":"test-dark","name":"Test dark","colors":{"document":"#abcdef"},"syntax":{"keyword":"#11223344"}}],"icon_themes":[{"id":"test-icons","name":"Test icons","extensions":[{"key":"py","icon":{"symbol":"Py"}}]}],"languages":[{"id":"python","name":"Python","extensions":["py"],"keywords":["def","return"],"line_comment":"#"}],"language_servers":[{"id":"pylsp","languages":["python"],"command":"pylsp","args":["--stdio"]}]}}
;
fn path(temp: *t.TmpDir, a: std.mem.Allocator, sub: []const u8) ![]u8 {
    const value = try temp.dir.realPathFileAlloc(t.io, sub, a);
    defer a.free(value);
    return a.dupe(u8, value);
}
fn prepare(temp: *t.TmpDir) !void {
    try temp.dir.createDirPath(t.io, "source");
    try temp.dir.createDirPath(t.io, "home");
    try temp.dir.writeFile(t.io, .{ .sub_path = "source/extension.json", .data = fixture });
}
test "install resolves real theme icon language and server and activation persists" {
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try prepare(&tmp);
    const source = try path(&tmp, t.allocator, "source");
    defer t.allocator.free(source);
    const home = try path(&tmp, t.allocator, "home");
    defer t.allocator.free(home);
    var registry = try extensions.Registry.init(t.allocator, t.io, home);
    defer registry.deinit();
    try t.expectEqualStrings("org.example.test", try registry.install(source));
    var snap = registry.snapshot();
    defer snap.deinit();
    try t.expectEqual(@as(usize, 1), snap.installed().len);
    try t.expectEqual(@as(u32, 0xabcdefff), snap.resolveTheme("test-dark").?.colors.document.rgba);
    try t.expectEqual(@as(u32, 0x11223344), snap.resolveTheme("test-dark").?.syntax.keyword.rgba);
    try t.expectEqualStrings("Py", snap.resolveIconTheme("test-icons").?.resolve("test.py", false).symbol);
    try t.expectEqualStrings("python", snap.languageForPath("folder/file.PY").?.id);
    try t.expectEqualStrings("pylsp", snap.serverForLanguage("python").?.command);
    try registry.setEnabled("org.example.test", false);
    var disabled = registry.snapshot();
    defer disabled.deinit();
    try t.expect(!disabled.installed()[0].enabled);
    try t.expect(disabled.resolveTheme("test-dark") == null);
    try t.expect(disabled.languageForPath("a.py") == null);
    // An old frame's immutable generation remains usable after activation changes.
    try t.expect(snap.resolveTheme("test-dark") != null);
    var reopened = try extensions.Registry.init(t.allocator, t.io, home);
    defer reopened.deinit();
    var persisted = reopened.snapshot();
    defer persisted.deinit();
    try t.expect(!persisted.installed()[0].enabled);
    try registry.setEnabled("org.example.test", true);
    try registry.remove("org.example.test");
    var removed = registry.snapshot();
    defer removed.deinit();
    try t.expectEqual(@as(usize, 0), removed.installed().len);
    try t.expect(snap.resolveTheme("test-dark") != null);
}

test "invalid manifests and duplicate contributions preserve effective installed generation" {
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try prepare(&tmp);
    const source = try path(&tmp, t.allocator, "source");
    defer t.allocator.free(source);
    const home = try path(&tmp, t.allocator, "home");
    defer t.allocator.free(home);
    var registry = try extensions.Registry.init(t.allocator, t.io, home);
    defer registry.deinit();
    _ = try registry.install(source);
    var before = registry.snapshot();
    defer before.deinit();
    try t.expectError(error.ExtensionAlreadyInstalled, registry.install(source));
    try tmp.dir.writeFile(t.io, .{ .sub_path = "source/extension.json", .data = "{bad json" });
    try t.expectError(error.SyntaxError, registry.install(source));
    try tmp.dir.writeFile(t.io, .{ .sub_path = "source/extension.json", .data =
        \\{"schema_version":1,"id":"../bad","name":"Bad","version":"1","contributes":{"themes":[{"id":"bad","name":"Bad"}]}}
    });
    try t.expectError(error.InvalidExtensionId, registry.install(source));
    try tmp.dir.writeFile(t.io, .{ .sub_path = "source/extension.json", .data =
        \\{"schema_version":1,"id":"org.example.second","name":"Second","version":"1","contributes":{"themes":[{"id":"test-dark","name":"Duplicate"}]}}
    });
    try t.expectError(error.DuplicateContribution, registry.install(source));
    var after = registry.snapshot();
    defer after.deinit();
    try t.expectEqual(before.revision(), after.revision());
    try t.expectEqual(@as(usize, 1), after.installed().len);
    const disk = try tmp.dir.readFileAlloc(t.io, "home/state.json", t.allocator, .limited(10000));
    defer t.allocator.free(disk);
    try t.expect(std.mem.indexOf(u8, disk, "second") == null);
}
test "contribution paths cannot escape a bundle or traverse symlinks" {
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try prepare(&tmp);
    const source = try path(&tmp, t.allocator, "source");
    defer t.allocator.free(source);
    const home = try path(&tmp, t.allocator, "home");
    defer t.allocator.free(home);
    var registry = try extensions.Registry.init(t.allocator, t.io, home);
    defer registry.deinit();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "outside.png", .data = "\x89PNG\r\n\x1a\n" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "source/extension.json", .data =
        \\{"schema_version":1,"id":"bad.paths","name":"Paths","version":"1","contributes":{"icon_themes":[{"id":"icons","name":"Icons","default_file":{"png":"../outside.png"}}]}}
    });
    try t.expectError(error.InvalidContributionPath, registry.install(source));
    try tmp.dir.writeFile(t.io, .{ .sub_path = "source/extension.json", .data =
        \\{"schema_version":1,"id":"bad.paths","name":"Paths","version":"1","contributes":{"icon_themes":[{"id":"icons","name":"Icons","default_file":{"png":"/tmp/outside.png"}}]}}
    });
    try t.expectError(error.InvalidContributionPath, registry.install(source));
    try tmp.dir.writeFile(t.io, .{ .sub_path = "source/extension.json", .data = fixture });
    try tmp.dir.symLink(t.io, "../outside.png", "source/escape.png", .{});
    try t.expectError(error.SymlinkNotAllowed, registry.install(source));
    var snap = registry.snapshot();
    defer snap.deinit();
    try t.expectEqual(@as(usize, 0), snap.installed().len);
}
test "missing PNG asset and unsupported schema fail before installation" {
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try prepare(&tmp);
    const source = try path(&tmp, t.allocator, "source");
    defer t.allocator.free(source);
    const home = try path(&tmp, t.allocator, "home");
    defer t.allocator.free(home);
    var registry = try extensions.Registry.init(t.allocator, t.io, home);
    defer registry.deinit();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "source/extension.json", .data =
        \\{"schema_version":1,"id":"missing.asset","name":"Missing","version":"1","contributes":{"icon_themes":[{"id":"icons","name":"Icons","default_file":{"png":"missing.png"}}]}}
    });
    try t.expectError(error.FileNotFound, registry.install(source));
    try tmp.dir.writeFile(t.io, .{ .sub_path = "source/extension.json", .data =
        \\{"schema_version":2,"id":"future.schema","name":"Future","version":"1","contributes":{"themes":[{"id":"future","name":"Future"}]}}
    });
    try t.expectError(error.UnsupportedSchemaVersion, registry.install(source));
    try tmp.dir.writeFile(t.io, .{ .sub_path = "source/extension.json", .data =
        \\{"schema_version":1,"id":"unknown.field","name":"Unknown","version":"1","contributes":{"parsers":[]}}
    });
    try t.expectError(error.UnknownField, registry.install(source));
}
test "asset bytes survive uninstall in a retained snapshot" {
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try prepare(&tmp);
    const source = try path(&tmp, t.allocator, "source");
    defer t.allocator.free(source);
    const home = try path(&tmp, t.allocator, "home");
    defer t.allocator.free(home);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "source/icon.png", .data = @embedFile("fixtures/pixel.png") });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "source/extension.json", .data =
        \\{"schema_version":1,"id":"asset.bundle","name":"Assets","version":"1","contributes":{"icon_themes":[{"id":"png-icons","name":"PNG","default_file":{"png":"icon.png"}}]}}
    });
    var registry = try extensions.Registry.init(t.allocator, t.io, home);
    defer registry.deinit();
    _ = try registry.install(source);
    var snapshot = registry.snapshot();
    defer snapshot.deinit();
    try registry.remove("asset.bundle");
    try t.expectEqualSlices(u8, @embedFile("fixtures/pixel.png"), snapshot.resolveIconTheme("png-icons").?.default_file.png.bytes);
}
test "activation disk failure preserves previous effective snapshot and install rollback" {
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try prepare(&tmp);
    const source = try path(&tmp, t.allocator, "source");
    defer t.allocator.free(source);
    const home = try path(&tmp, t.allocator, "home");
    defer t.allocator.free(home);
    var registry = try extensions.Registry.init(t.allocator, t.io, home);
    defer registry.deinit();
    _ = try registry.install(source);
    try tmp.dir.rename("home/state.json", tmp.dir, "home/state.saved", t.io);
    try tmp.dir.createDirPath(t.io, "home/state.json");
    if (registry.setEnabled("org.example.test", false)) |_| return error.ExpectedPersistenceFailure else |_| {}
    var snapshot = registry.snapshot();
    defer snapshot.deinit();
    try t.expect(snapshot.installed()[0].enabled);
    try tmp.dir.deleteDir(t.io, "home/state.json");
    try tmp.dir.rename("home/state.saved", tmp.dir, "home/state.json", t.io);
    var reopened = try extensions.Registry.init(t.allocator, t.io, home);
    defer reopened.deinit();
    var persisted = reopened.snapshot();
    defer persisted.deinit();
    try t.expect(persisted.installed()[0].enabled);
}
test "install allocation failures retain old registry and clean owned snapshots" {
    try t.checkAllAllocationFailures(t.allocator, allocationCase, .{});
}
fn allocationCase(a: std.mem.Allocator) !void {
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try prepare(&tmp);
    const source = try path(&tmp, t.allocator, "source");
    defer t.allocator.free(source);
    const home = try path(&tmp, t.allocator, "home");
    defer t.allocator.free(home);
    var registry = try extensions.Registry.init(a, t.io, home);
    defer registry.deinit();
    _ = registry.install(source) catch |err| {
        var retained = registry.snapshot();
        defer retained.deinit();
        try t.expectEqual(@as(usize, 0), retained.installed().len);
        return err;
    };
    var snapshot = registry.snapshot();
    defer snapshot.deinit();
    try t.expect(snapshot.resolveTheme("test-dark") != null);
}

test "install refuses a source containing the managed home and malformed PNG headers" {
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try prepare(&tmp);
    const root = try path(&tmp, t.allocator, ".");
    defer t.allocator.free(root);
    const source = try path(&tmp, t.allocator, "source");
    defer t.allocator.free(source);
    const home = try path(&tmp, t.allocator, "home");
    defer t.allocator.free(home);
    var registry = try extensions.Registry.init(t.allocator, t.io, home);
    defer registry.deinit();
    try t.expectError(error.SourceContainsRegistryHome, registry.install(root));
    try tmp.dir.writeFile(t.io, .{ .sub_path = "source/icon.png", .data = "\x89PNG\r\n\x1a\n" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "source/extension.json", .data =
        \\{"schema_version":1,"id":"invalid.png","name":"Invalid","version":"1","contributes":{"icon_themes":[{"id":"icons","name":"Icons","default_file":{"png":"icon.png"}}]}}
    });
    try t.expectError(error.InvalidPngAsset, registry.install(source));
}

test "upgrade preserves activation and retained snapshots and rolls back publication failure" {
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try prepare(&tmp);
    const source = try path(&tmp, t.allocator, "source");
    defer t.allocator.free(source);
    const home = try path(&tmp, t.allocator, "home");
    defer t.allocator.free(home);
    var registry = try extensions.Registry.init(t.allocator, t.io, home);
    defer registry.deinit();
    _ = try registry.install(source);
    try registry.setEnabled("org.example.test", false);
    var retained = registry.snapshot();
    defer retained.deinit();
    const updated = try std.mem.replaceOwned(u8, t.allocator, fixture, "1.0.0", "2.0.0");
    defer t.allocator.free(updated);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "source/extension.json", .data = updated });
    try registry.upgrade(source);
    var next = registry.snapshot();
    defer next.deinit();
    try t.expectEqualStrings("2.0.0", next.installed()[0].version);
    try t.expect(!next.installed()[0].enabled);
    try t.expectEqualStrings("1.0.0", retained.installed()[0].version);
    try tmp.dir.deleteFile(t.io, "home/state.json");
    try tmp.dir.createDir(t.io, "home/state.json", .default_dir);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "source/extension.json", .data = fixture });
    var failed = false;
    registry.upgrade(source) catch {
        failed = true;
    };
    try t.expect(failed);
    var unchanged = registry.snapshot();
    defer unchanged.deinit();
    try t.expectEqualStrings("2.0.0", unchanged.installed()[0].version);
    try tmp.dir.deleteTree(t.io, "home/state.json");
    var reopened = try extensions.Registry.init(t.allocator, t.io, home);
    defer reopened.deinit();
    var disk = reopened.snapshot();
    defer disk.deinit();
    try t.expectEqualStrings("2.0.0", disk.installed()[0].version);
}

test "converted icon mappings share encoded assets and language suffixes support multipart names" {
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try prepare(&tmp);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "source/icon.png", .data = @embedFile("fixtures/pixel.png") });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "source/extension.json", .data =
        \\{"schema_version":1,"id":"zed.fixture","name":"Converted","version":"1","unsupported_features":["Debug adapters"],"contributes":{"icon_themes":[{"id":"icons","name":"Icons","extensions":[{"key":"py","icon":{"png":"icon.png"}},{"key":"pyi","icon":{"png":"icon.png"}}],"stems":[{"key":"Dockerfile","icon":{"png":"icon.png"}}]}],"languages":[{"id":"blade","name":"Blade","extensions":["blade.php"],"lsp_id":"blade","grammar":{"name":"html","builtin":true,"wasm":"","highlights":""}}]}}
    });
    const source = try path(&tmp, t.allocator, "source");
    defer t.allocator.free(source);
    const home = try path(&tmp, t.allocator, "home");
    defer t.allocator.free(home);
    var registry = try extensions.Registry.init(t.allocator, t.io, home);
    defer registry.deinit();
    _ = try registry.install(source);
    var snapshot = registry.snapshot();
    defer snapshot.deinit();
    const theme = snapshot.resolveIconTheme("icons").?;
    try t.expect(theme.resolve("a.py", false).png.bytes.ptr == theme.resolve("a.pyi", false).png.bytes.ptr);
    try t.expect(theme.resolve("Dockerfile", false).png.bytes.ptr == theme.resolve("a.py", false).png.bytes.ptr);
    try t.expectEqualStrings("blade", snapshot.languageForPath("view.blade.php").?.lsp_id.?);
    try t.expect(snapshot.languageForPath("view.php") == null);
    try t.expectEqualStrings("@builtin", snapshot.languageForPath("view.blade.php").?.grammar.?.wasm);
    try t.expectEqualStrings("Debug adapters", snapshot.installed()[0].unsupported_features[0]);
}
