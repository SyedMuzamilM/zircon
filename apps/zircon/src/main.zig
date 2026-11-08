//! Native entry point. The optional path opens a real file or project directory.
//! --snapshot exports one real rendered frame and exits for artifact checks.
const std = @import("std");
const zircon = @import("zircon");
const ui = @import("zircon_ui");
const Shell = zircon.Shell;
pub fn main(init: std.process.Init) !void {
    const started = ui.testing.native.now();
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    try enterApplicationBundle(init, args);
    var requested: ?[]const u8 = null;
    var snapshot_path: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--snapshot")) {
            i += 1;
            if (i >= args.len) return error.MissingSnapshotPath;
            snapshot_path = args[i];
        } else if (std.mem.eql(u8, args[i], "--help")) {
            std.debug.print("Usage: zircon [file-or-folder] [--snapshot output.png]\n", .{});
            return;
        } else if (requested == null) requested = args[i] else return error.UnexpectedArgument;
    }
    const cwd = try std.process.currentPathAlloc(init.io, init.gpa);
    defer init.gpa.free(cwd);
    var root: []const u8 = cwd;
    if (requested == null and std.mem.eql(u8, cwd, "/")) if (init.environ_map.get("HOME")) |home| {
        const scratch = try std.fs.path.join(init.arena.allocator(), &.{ home, "Library", "Application Support", "Zircon", "Scratch" });
        try std.Io.Dir.cwd().createDirPath(init.io, scratch);
        root = scratch;
    };
    var file: ?[]const u8 = null;
    if (requested) |path| {
        const stat = try std.Io.Dir.cwd().statFile(init.io, path, .{});
        if (stat.kind == .directory) root = path else {
            const absolute = try std.fs.path.resolve(init.arena.allocator(), &.{ cwd, path });
            root = std.fs.path.dirname(absolute) orelse cwd;
            file = absolute;
        }
    }
    var icon = try zircon.applicationIcon(init.gpa);
    defer icon.deinit();
    var app = try ui.App.init(.{ .allocator = init.gpa, .icon = icon });
    defer app.deinit();
    var shell = try Shell.init(init.gpa, init.io, root, file);
    const handle = app.openWindow(Shell, .{ .title = "Zircon", .menus = &zircon.menus.groups, .chrome = .integrated, .width = 1240, .height = 820, .visible = snapshot_path == null }, shell) catch |err| {
        shell.deinit(init.gpa);
        return err;
    };
    const owner = try app.windowEntity(Shell, handle);
    if (init.environ_map.get("HOME")) |user_directory| {
        const extension_home = try std.fs.path.join(init.arena.allocator(), &.{ user_directory, "Library", "Application Support", "Zircon", "extensions" });
        try app.update(owner, Shell.loadExtensions, .{extension_home});
        const settings_path = try std.fs.path.join(init.arena.allocator(), &.{ user_directory, "Library", "Application Support", "Zircon", "settings.json" });
        app.update(owner, Shell.loadSettings, .{@as(?[]const u8, settings_path)}) catch |err| {
            const Report = struct {
                fn call(self: *Shell, cx: *ui.Context(Shell), failure: anyerror) !void {
                    try self.reportError(failure);
                    cx.notify();
                }
            };
            try app.update(owner, Report.call, .{err});
        };
        if (snapshot_path == null) {
            const recovery_home = try std.fs.path.join(init.arena.allocator(), &.{ user_directory, "Library", "Application Support", "Zircon", "recovery" });
            try app.update(owner, Shell.initRecovery, .{recovery_home});
        }
    }
    try app.update(owner, Shell.bootstrap, .{handle});
    if (snapshot_path) |path| {
        const objc = ui.testing.native.objc;
        const bundle = objc.send(objc.Id, objc.class("NSBundle"), "mainBundle", .{});
        std.debug.print("app_bundle_id={s}\n", .{objc.fromString(objc.send(objc.Id, bundle, "bundleIdentifier", .{}))});
        _ = try app.step(ui.testing.native.now());
        try (try app.window(handle)).snapshot(path);
        std.debug.print("rendered_frames={d} first_frame_and_png_ms={d:.3}\n", .{ (try app.window(handle)).frame_count, (ui.testing.native.now() - started) * 1000 });
        return;
    }
    try app.run();
}

/// Development CLI launches use the same bundle identity as Finder launches.
fn enterApplicationBundle(init: std.process.Init, args: []const []const u8) !void {
    const executable = try std.process.executablePathAlloc(init.io, init.arena.allocator());
    if (!std.mem.endsWith(u8, executable, "/bin/zircon")) return;
    const path = try std.fs.path.resolve(init.arena.allocator(), &.{ std.fs.path.dirname(executable).?, "../Zircon.app/Contents/MacOS/zircon" });
    const own = try std.Io.Dir.cwd().statFile(init.io, executable, .{});
    const bundled = std.Io.Dir.cwd().statFile(init.io, path, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return,
        else => return err,
    };
    if (own.size != bundled.size or own.mtime.nanoseconds != bundled.mtime.nanoseconds) return;
    const argv = try init.arena.allocator().alloc([]const u8, args.len);
    @memcpy(argv, args);
    argv[0] = path;
    return std.process.replace(init.io, .{ .argv = argv, .environ_map = init.environ_map });
}
