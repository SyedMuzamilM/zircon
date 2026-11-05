//! Native entry point. The optional path opens a real file or project directory.
//! --snapshot exports one real rendered frame and exits for artifact checks.
const std = @import("std");
const ui = @import("zircon_ui");
const Shell = @import("zircon").Shell;
pub fn main(init: std.process.Init) !void {
    const started = ui.testing.native.now();
    const args = try init.minimal.args.toSlice(init.arena.allocator());
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
    var file: ?[]const u8 = null;
    if (requested) |path| {
        const stat = try std.Io.Dir.cwd().statFile(init.io, path, .{});
        if (stat.kind == .directory) root = path else {
            const absolute = try std.fs.path.resolve(init.arena.allocator(), &.{ cwd, path });
            root = std.fs.path.dirname(absolute) orelse cwd;
            file = absolute;
        }
    }
    var app = try ui.App.init(.{ .allocator = init.gpa });
    defer app.deinit();
    var shell = try Shell.init(init.gpa, init.io, root, file);
    const handle = app.openWindow(Shell, .{ .title = "Zircon", .chrome = .integrated, .width = 1240, .height = 820, .visible = snapshot_path == null }, shell) catch |err| {
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
    }
    try app.update(owner, Shell.bootstrap, .{handle});
    if (snapshot_path) |path| {
        _ = try app.step(ui.testing.native.now());
        try (try app.window(handle)).snapshot(path);
        std.debug.print("rendered_frames={d} first_frame_and_png_ms={d:.3}\n", .{ (try app.window(handle)).frame_count, (ui.testing.native.now() - started) * 1000 });
        return;
    }
    try app.run();
}
