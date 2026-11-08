//! Project windows share application settings while keeping documents, jobs and
//! repository state independent. Cloning never runs in an input/render callback.
const std = @import("std");
const git = @import("zircon_git");
const ui = @import("zircon_ui");
const handoff = @import("services/handoff.zig");
const shell_module = @import("shell.zig");
const Shell = shell_module.Shell;
const a = std.heap.page_allocator;
pub const Kind = enum { local_folder, git_repository, clone };
pub fn open(self: *Shell, cx: *ui.Context(Shell), requested: []const u8, kind: Kind) !ui.WindowHandle {
    var path = try std.fs.path.resolve(self.allocator, &.{ self.workspace.root_path, requested });
    defer self.allocator.free(path);
    if (kind == .git_repository) {
        var repository = (try git.Repository.discover(self.allocator, self.workspace.io, path)) orelse return error.NotGitRepository;
        defer repository.deinit();
        const root = try self.allocator.dupe(u8, repository.root);
        self.allocator.free(path);
        path = root;
    }
    var shell = try Shell.init(self.allocator, self.workspace.io, path, null);
    shell.settings = self.settings;
    const window = cx.app.openWindow(Shell, .{ .title = "Zircon", .chrome = .integrated, .width = 1240, .height = 820 }, shell) catch |err| {
        shell.deinit(self.allocator);
        return err;
    };
    errdefer cx.app.closeWindow(window) catch {};
    const owner = try cx.app.windowEntity(Shell, window);
    if (self.agents.home) |home| try cx.app.update(owner, Shell.configureAgents, .{ home, self.agents.environment });
    if (self.extensions) |extensions| try cx.app.update(owner, Shell.loadExtensions, .{extensions.home});
    if (self.recovery) |recovery| try cx.app.update(owner, Shell.initRecovery, .{recovery.home});
    try cx.app.update(owner, Shell.bootstrap, .{window});
    self.overlay = .none;
    cx.notify();
    return window;
}
const Result = struct {
    destination: []u8,
    pub fn deinit(self: *Result) void {
        a.free(self.destination);
    }
};
const Box = handoff.Handoff(Result);
const Clone = struct {
    pub const Output = *Box;
    io: std.Io,
    source: []u8,
    destination: []u8,
    pub fn run(self: *Clone, cancel: *ui.tasks.Cancellation) !*Box {
        try cancel.check();
        try git.cloneRepository(a, self.io, self.source, self.destination);
        try cancel.check();
        const path = try a.dupe(u8, self.destination);
        errdefer a.free(path);
        return Box.create(a, .{ .destination = path });
    }
    pub fn discard(_: *Clone, result: *Box) void {
        result.destroy();
    }
    pub fn deinit(self: *Clone, _: std.mem.Allocator) void {
        a.free(self.source);
        a.free(self.destination);
    }
};
pub fn clone(self: *Shell, cx: *ui.Context(Shell), source: []const u8, destination: []const u8) !void {
    if (self.cloning) return error.GitBusy;
    const url = try a.dupe(u8, source);
    errdefer a.free(url);
    const path = try std.fs.path.resolve(a, &.{ self.workspace.root_path, destination });
    errdefer a.free(path);
    _ = try cx.spawn(Clone, .{ .io = self.workspace.io, .source = url, .destination = path }, complete);
    self.cloning = true;
    try self.setStatus(try self.allocator.dupe(u8, "Cloning repository…"));
    cx.notify();
}

fn complete(self: *Shell, cx: *ui.Context(Shell), result: anyerror!*Box) !void {
    self.cloning = false;
    const box = result catch |err| {
        try self.reportError(err);
        cx.notify();
        return;
    };
    var value = box.take();
    defer value.deinit();
    _ = open(self, cx, value.destination, .git_repository) catch |err| {
        try self.reportError(err);
        cx.notify();
        return;
    };
    try self.setStatus(try self.allocator.dupe(u8, "Repository cloned and opened in a new window."));
    cx.notify();
}
