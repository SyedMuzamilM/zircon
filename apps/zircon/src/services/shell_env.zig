//! Asynchronous macOS login-shell environment capture so Finder/Dock-launched
//! Zircon resolves the user's real PATH and toolchains for terminals, LSPs, and tasks.
const std = @import("std");
const builtin = @import("builtin");
const ui = @import("zircon_ui");
const shell = @import("../shell.zig");
const handoff = @import("handoff.zig");
const terminal_tasks = @import("tasks.zig");
const Shell = shell.Shell;

const a = if (builtin.single_threaded) std.heap.page_allocator else std.heap.smp_allocator;
const marker = "\x00zircon-login-environment\x00";

pub const Model = struct {
    entries: [][2][]const u8 = &.{},
    loaded: bool = false,
    busy: bool = false,

    pub fn deinit(self: *Model) void {
        freeEntries(self.entries);
        self.* = .{};
    }
};

fn freeEntries(entries: [][2][]const u8) void {
    for (entries) |pair| {
        a.free(pair[0]);
        a.free(pair[1]);
    }
    a.free(entries);
}

const Result = struct {
    entries: [][2][]const u8 = &.{},
    pub fn deinit(self: *Result) void {
        freeEntries(self.entries);
    }
};
const Box = handoff.Handoff(Result);

const Job = struct {
    pub const Output = *Box;
    io: std.Io,
    root: []u8,
    shell_path: []u8,

    pub fn run(self: *Job, cancel: *ui.tasks.Cancellation) !*Box {
        try cancel.check();
        var result: Result = .{};
        errdefer result.deinit();
        if (comptime builtin.os.tag == .macos and builtin.link_libc) {
            const output = std.process.run(a, self.io, .{
                .argv = &.{ self.shell_path, "-l", "-i", "-c", "printf '\\000zircon-login-environment\\000'; /usr/bin/env -0" },
                .cwd = .{ .path = self.root },
                .stdout_limit = .limited(256 * 1024),
                .stderr_limit = .limited(16 * 1024),
                .timeout = .{ .duration = .{ .raw = .fromSeconds(3), .clock = .awake } },
            }) catch return Box.create(a, result);
            defer a.free(output.stdout);
            defer a.free(output.stderr);
            if (output.term.success()) {
                if (std.mem.indexOf(u8, output.stdout, marker)) |offset| result.entries = try parseNullEnv(output.stdout[offset + marker.len ..]);
            }
        }
        return Box.create(a, result);
    }

    pub fn discard(_: *Job, box: *Box) void {
        box.destroy();
    }

    pub fn deinit(self: *Job, _: std.mem.Allocator) void {
        a.free(self.root);
        a.free(self.shell_path);
    }
};

fn parseNullEnv(bytes: []const u8) ![][2][]const u8 {
    var list: std.ArrayList([2][]const u8) = .empty;
    errdefer {
        for (list.items) |pair| {
            a.free(pair[0]);
            a.free(pair[1]);
        }
        list.deinit(a);
    }
    var it = std.mem.splitScalar(u8, bytes, 0);
    while (it.next()) |entry| {
        if (entry.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
        const key = entry[0..eq];
        const val = entry[eq + 1 ..];
        if (key.len == 0 or std.mem.eql(u8, key, "TERM") or std.mem.eql(u8, key, "COLORTERM") or std.mem.eql(u8, key, "PWD") or std.mem.eql(u8, key, "SHLVL") or std.mem.eql(u8, key, "_")) continue;
        if (!validName(key) or !std.unicode.utf8ValidateSlice(val)) continue;
        const k = try a.dupe(u8, key);
        errdefer a.free(k);
        const v = try a.dupe(u8, val);
        errdefer a.free(v);
        try list.append(a, .{ k, v });
        if (list.items.len >= 512) break;
    }
    return list.toOwnedSlice(a);
}

pub fn start(self: *Shell, cx: *ui.Context(Shell)) !void {
    if (comptime builtin.os.tag != .macos or !builtin.link_libc) return;
    if (self.shell_env.busy or self.shell_env.loaded) return;
    const shell_raw = if (std.c.getenv("SHELL")) |v| std.mem.span(v) else "/bin/zsh";
    const home = if (std.c.getenv("HOME")) |value| std.mem.span(value) else "/";
    const root = try a.dupe(u8, home);
    errdefer a.free(root);
    const sh = try a.dupe(u8, shell_raw);
    errdefer a.free(sh);
    _ = try cx.spawn(Job, .{ .io = self.workspace.io, .root = root, .shell_path = sh }, complete);
    self.shell_env.busy = true;
}

fn complete(self: *Shell, cx: *ui.Context(Shell), raw: anyerror!*Box) !void {
    self.shell_env.busy = false;
    self.shell_env.loaded = true;
    defer cx.notify();
    if (raw) |box| {
        var result = box.take();
        defer result.deinit();
        if (result.entries.len != 0) {
            freeEntries(self.shell_env.entries);
            self.shell_env.entries = result.entries;
            result.entries = &.{};
        }
    } else |_| {}
    terminal_tasks.startPending(self, cx) catch |err| try self.reportError(err);
}

pub fn validName(name: []const u8) bool {
    if (name.len == 0 or !(std.ascii.isAlphabetic(name[0]) or name[0] == '_')) return false;
    for (name[1..]) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '_') return false;
    return true;
}

pub fn executable(alloc: std.mem.Allocator, io: std.Io, cwd: []const u8, command: []const u8, entries: []const [2][]const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, command, '/') != null) return command;
    // std.process resolves argv[0] against the parent's PATH.
    var i = entries.len;
    while (i > 0) {
        i -= 1;
        if (!std.mem.eql(u8, entries[i][0], "PATH")) continue;
        var dirs = std.mem.splitScalar(u8, entries[i][1], ':');
        while (dirs.next()) |dir| {
            const candidate = try std.fs.path.resolve(alloc, if (std.fs.path.isAbsolute(dir)) &.{ dir, command } else &.{ cwd, dir, command });
            const stat = std.Io.Dir.cwd().statFile(io, candidate, .{}) catch continue;
            if (stat.kind != .file) continue;
            std.Io.Dir.cwd().access(io, candidate, .{ .execute = true }) catch continue;
            return candidate;
        }
        break;
    }
    return command;
}
