//! Workspace and global JSONC tasks (.zircon/tasks.json) executed in Zircon's
//! built-in terminal with $ZIRCON_* variable expansion and Rerun Last Task.
const std = @import("std");
const ui = @import("zircon_ui");
const actions = @import("../actions.zig");
const jsonc = @import("../settings/jsonc.zig");
const settings = @import("../settings/model.zig");
const shell = @import("../shell.zig");
const terminal_module = @import("../terminal.zig");
const overlays = @import("../views/overlays.zig");
const shell_env = @import("shell_env.zig");
const Shell = shell.Shell;

pub const TaskTemplate = struct {
    label: []u8,
    command: []u8,
    args: [][]u8 = &.{},
    cwd: ?[]u8 = null,
    env: [][2][]u8 = &.{},

    pub fn deinit(self: *TaskTemplate, a: std.mem.Allocator) void {
        a.free(self.label);
        a.free(self.command);
        for (self.args) |arg| a.free(arg);
        a.free(self.args);
        if (self.cwd) |c| a.free(c);
        for (self.env) |pair| {
            a.free(pair[0]);
            a.free(pair[1]);
        }
        a.free(self.env);
    }

    pub fn clone(self: TaskTemplate, a: std.mem.Allocator) !TaskTemplate {
        const label = try a.dupe(u8, self.label);
        errdefer a.free(label);
        const cmd = try a.dupe(u8, self.command);
        errdefer a.free(cmd);
        const args = try a.alloc([]u8, self.args.len);
        var filled_args: usize = 0;
        errdefer {
            for (args[0..filled_args]) |arg| a.free(arg);
            a.free(args);
        }
        for (self.args) |arg| {
            args[filled_args] = try a.dupe(u8, arg);
            filled_args += 1;
        }
        const cwd = if (self.cwd) |c| try a.dupe(u8, c) else null;
        errdefer if (cwd) |c| a.free(c);
        const env = try a.alloc([2][]u8, self.env.len);
        var filled_env: usize = 0;
        errdefer {
            for (env[0..filled_env]) |pair| {
                a.free(pair[0]);
                a.free(pair[1]);
            }
            a.free(env);
        }
        for (self.env) |pair| {
            const k = try a.dupe(u8, pair[0]);
            errdefer a.free(k);
            const v = try a.dupe(u8, pair[1]);
            env[filled_env] = .{ k, v };
            filled_env += 1;
        }
        return .{ .label = label, .command = cmd, .args = args, .cwd = cwd, .env = env };
    }
};

pub const Model = struct {
    last: ?TaskTemplate = null,
    pending: std.ArrayList(TaskTemplate) = .empty,
    available: []TaskTemplate = &.{},

    pub fn deinit(self: *Model, a: std.mem.Allocator) void {
        if (self.last) |*t| t.deinit(a);
        for (self.pending.items) |*task| task.deinit(a);
        self.pending.deinit(a);
        freeTasks(a, self.available);
        self.* = .{};
    }
};

pub const Variables = struct {
    worktree_root: []const u8,
    file: []const u8 = "",
    relative_file: []const u8 = "",
    dirname: []const u8 = "",
    stem: []const u8 = "",
    row: usize = 1,
    column: usize = 1,
    selected_text: []const u8 = "",

    pub fn get(self: Variables, name: []const u8, num_buf: *[24]u8) ?[]const u8 {
        if (std.mem.eql(u8, name, "ZIRCON_WORKTREE_ROOT")) return self.worktree_root;
        if (std.mem.eql(u8, name, "ZIRCON_FILE")) return if (self.file.len > 0) self.file else null;
        if (std.mem.eql(u8, name, "ZIRCON_RELATIVE_FILE")) return if (self.relative_file.len > 0) self.relative_file else null;
        if (std.mem.eql(u8, name, "ZIRCON_DIRNAME")) return if (self.dirname.len > 0) self.dirname else null;
        if (std.mem.eql(u8, name, "ZIRCON_STEM")) return if (self.stem.len > 0) self.stem else null;
        if (std.mem.eql(u8, name, "ZIRCON_ROW")) return std.fmt.bufPrint(num_buf, "{d}", .{self.row}) catch null;
        if (std.mem.eql(u8, name, "ZIRCON_COLUMN")) return std.fmt.bufPrint(num_buf, "{d}", .{self.column}) catch null;
        if (std.mem.eql(u8, name, "ZIRCON_SELECTED_TEXT")) return if (self.selected_text.len > 0) self.selected_text else null;
        return null;
    }
};

/// Expands $ZIRCON_VAR and ${ZIRCON_VAR:default} placeholders.
pub fn expand(a: std.mem.Allocator, template: []const u8, vars: Variables) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var num_buf: [24]u8 = undefined;
    var i: usize = 0;
    while (i < template.len) {
        if (template[i] == '$' and i + 1 < template.len) {
            if (template[i + 1] == '{') {
                if (std.mem.indexOfScalarPos(u8, template, i + 2, '}')) |close| {
                    const inner = template[i + 2 .. close];
                    const colon = std.mem.indexOfScalar(u8, inner, ':');
                    const name = if (colon) |c| inner[0..c] else inner;
                    const fallback = if (colon) |c| inner[c + 1 ..] else "";
                    if (std.mem.startsWith(u8, name, "ZIRCON_")) {
                        try out.appendSlice(a, vars.get(name, &num_buf) orelse fallback);
                        i = close + 1;
                        continue;
                    }
                }
            } else if (std.mem.startsWith(u8, template[i + 1 ..], "ZIRCON_")) {
                var end = i + 1;
                while (end < template.len and (std.ascii.isAlphanumeric(template[end]) or template[end] == '_')) : (end += 1) {}
                const name = template[i + 1 .. end];
                if (vars.get(name, &num_buf)) |val| try out.appendSlice(a, val);
                i = end;
                continue;
            }
        }
        try out.append(a, template[i]);
        i += 1;
    }
    return out.toOwnedSlice(a);
}

pub fn loadWorkspaceTasks(a: std.mem.Allocator, io: std.Io, workspace_root: []const u8, user_settings_path: ?[]const u8) ![]TaskTemplate {
    var list: std.ArrayList(TaskTemplate) = .empty;
    errdefer {
        for (list.items) |*t| t.deinit(a);
        list.deinit(a);
    }
    const local_path = try std.fs.path.join(a, &.{ workspace_root, ".zircon", "tasks.json" });
    defer a.free(local_path);
    try appendTasksFromFile(a, io, local_path, &list);

    if (user_settings_path) |settings_path| {
        if (std.fs.path.dirname(settings_path)) |dir| {
            const global_path = try std.fs.path.join(a, &.{ dir, "tasks.json" });
            defer a.free(global_path);
            try appendTasksFromFile(a, io, global_path, &list);
        }
    }
    return list.toOwnedSlice(a);
}

fn appendTasksFromFile(a: std.mem.Allocator, io: std.Io, path: []const u8, out: *std.ArrayList(TaskTemplate)) !void {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    if (stat.kind != .file) return error.InvalidTasksFile;
    const raw = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(512 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer a.free(raw);
    const stripped = try jsonc.strip(a, raw);
    defer a.free(stripped);
    var parsed = try std.json.parseFromSlice(std.json.Value, a, stripped, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    if (parsed.value != .array) return error.InvalidTasksFile;
    for (parsed.value.array.items) |item| {
        if (item != .object) continue;
        const label_val = item.object.get("label") orelse continue;
        const cmd_val = item.object.get("command") orelse continue;
        if (label_val != .string or cmd_val != .string or label_val.string.len == 0 or cmd_val.string.len == 0) continue;

        if (out.items.len >= 512 or !validString(label_val.string) or !validString(cmd_val.string)) return error.InvalidTasksFile;
        var task: TaskTemplate = blk: {
            const label = try a.dupe(u8, label_val.string);
            errdefer a.free(label);
            break :blk .{ .label = label, .command = try a.dupe(u8, cmd_val.string) };
        };
        errdefer task.deinit(a);

        if (item.object.get("cwd")) |cwd_val| {
            if (cwd_val != .string or !validString(cwd_val.string)) return error.InvalidTasksFile;
            if (cwd_val.string.len != 0) task.cwd = try a.dupe(u8, cwd_val.string);
        }
        if (item.object.get("args")) |args_val| {
            if (args_val != .array) return error.InvalidTasksFile;
            var args: std.ArrayList([]u8) = .empty;
            errdefer {
                for (args.items) |arg| a.free(arg);
                args.deinit(a);
            }
            for (args_val.array.items) |entry| {
                if (entry != .string or !validString(entry.string)) return error.InvalidTasksFile;
                const arg = try a.dupe(u8, entry.string);
                errdefer a.free(arg);
                try args.append(a, arg);
            }
            task.args = try args.toOwnedSlice(a);
        }
        if (item.object.get("env")) |env_val| {
            if (env_val != .object) return error.InvalidTasksFile;
            var env: std.ArrayList([2][]u8) = .empty;
            errdefer {
                for (env.items) |pair| {
                    a.free(pair[0]);
                    a.free(pair[1]);
                }
                env.deinit(a);
            }
            var it = env_val.object.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.* != .string or !validString(entry.value_ptr.string) or !shell_env.validName(entry.key_ptr.*)) return error.InvalidTasksFile;
                const k = try a.dupe(u8, entry.key_ptr.*);
                errdefer a.free(k);
                const v = try a.dupe(u8, entry.value_ptr.string);
                errdefer a.free(v);
                try env.append(a, .{ k, v });
            }
            task.env = try env.toOwnedSlice(a);
        }
        try out.append(a, task);
    }
}

pub fn captureVariables(self: *Shell, a: std.mem.Allocator) !Variables {
    var vars: Variables = .{ .worktree_root = self.workspace.root_path };
    const current = actions.active(self) catch return vars;
    const record = self.workspace.getConst(current.id) catch return vars;
    var snapshot = record.doc.snapshot();
    defer snapshot.deinit();

    const sel = current.editor.primary();
    const pt = try snapshot.pointAt(@min(sel.head, snapshot.byteLen()));
    vars.row = pt.line + 1;
    vars.column = pt.byte_column + 1;

    const r = sel.range();
    if (r.end > r.start and r.end - r.start <= 8192) {
        vars.selected_text = try snapshot.copy(a, r);
    }
    if (record.path) |full| {
        vars.file = full;
        vars.dirname = std.fs.path.dirname(full) orelse self.workspace.root_path;
        vars.stem = std.fs.path.stem(full);
        const root = std.mem.trimEnd(u8, self.workspace.root_path, "/");
        if (full.len > root.len and std.mem.startsWith(u8, full, root) and full[root.len] == '/') {
            vars.relative_file = full[root.len + 1 ..];
        } else {
            vars.relative_file = full;
        }
    }
    return vars;
}

fn validString(value: []const u8) bool {
    return std.unicode.utf8ValidateSlice(value) and std.mem.indexOfScalar(u8, value, 0) == null;
}

fn freeTasks(a: std.mem.Allocator, tasks: []TaskTemplate) void {
    for (tasks) |*task| task.deinit(a);
    a.free(tasks);
}

pub fn show(self: *Shell, cx: *ui.Context(Shell)) !void {
    var path: ?[]u8 = null;
    if (self.settings) |entity| try cx.read(entity, settings.Settings.copyPath, .{ self.allocator, &path });
    defer if (path) |owned| self.allocator.free(owned);
    const loaded = try loadWorkspaceTasks(self.allocator, self.workspace.io, self.workspace.root_path, path);
    freeTasks(self.allocator, self.tasks.available);
    self.tasks.available = loaded;
    try overlays.show(self, cx, .task_picker);
}

pub fn onTask(self: *Shell, _: *ui.Event(ui.Click), cx: *ui.Context(Shell), index: u32) !void {
    try execute(self, cx, index);
}

pub fn execute(self: *Shell, cx: *ui.Context(Shell), index: usize) !void {
    if (self.overlay != .task_picker or index >= self.tasks.available.len) return;
    runTask(self, cx, self.tasks.available[index]) catch |err| {
        try self.reportError(err);
        cx.notify();
        return;
    };
    self.overlay = .none;
    cx.notify();
}

// The shell expands environment variables after parsing operators. Keeping
// editor data in the environment avoids inserting it into the command string.
fn shellCommand(a: std.mem.Allocator, template: []const u8, vars: Variables, env: *std.ArrayList([2][]const u8)) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    var fallback_count: usize = 0;
    while (i < template.len) {
        if (template[i] == '\\' and i + 1 < template.len) {
            try output.appendSlice(a, template[i..][0..2]);
            i += 2;
            continue;
        }
        if (std.mem.startsWith(u8, template[i..], "${ZIRCON_")) {
            if (std.mem.indexOfScalarPos(u8, template, i + 2, '}')) |end| {
                const inner = template[i + 2 .. end];
                if (std.mem.indexOfScalar(u8, inner, ':')) |colon| {
                    const name = inner[0..colon];
                    const fallback = inner[colon + 1 ..];
                    if (shell_env.validName(name) and (fallback.len == 0 or std.mem.indexOfScalar(u8, "-=+?", fallback[0]) == null)) {
                        const key = try std.fmt.allocPrint(a, "ZIRCON_TASK_VALUE_{d}", .{fallback_count});
                        fallback_count += 1;
                        var number: [24]u8 = undefined;
                        const value = try a.dupe(u8, vars.get(name, &number) orelse fallback);
                        try env.append(a, .{ key, value });
                        try output.appendSlice(a, "${");
                        try output.appendSlice(a, key);
                        try output.append(a, '}');
                        i = end + 1;
                        continue;
                    }
                }
            }
        }
        try output.append(a, template[i]);
        i += 1;
    }
    return output.toOwnedSlice(a);
}

/// Starts a dedicated terminal tab and retains the template for a rerun
/// with the editor's current file, selection and cursor.
pub fn runTask(self: *Shell, cx: *ui.Context(Shell), task: TaskTemplate) !void {
    if (self.shell_env.busy) {
        try self.tasks.pending.ensureUnusedCapacity(self.allocator, 1);
        self.tasks.pending.appendAssumeCapacity(try task.clone(self.allocator));
        try self.setStatus(try self.allocator.dupe(u8, "Waiting for the login shell environment…"));
        cx.notify();
        return;
    }
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const vars = try captureVariables(self, a);
    const cwd = if (task.cwd) |directory| blk: {
        const expanded = try expand(a, directory, vars);
        if (!validString(expanded)) return error.InvalidTerminalCommand;
        break :blk try std.fs.path.resolve(a, &.{ self.workspace.root_path, expanded });
    } else self.workspace.root_path;
    const stat = try std.Io.Dir.cwd().statFile(self.workspace.io, cwd, .{});
    if (stat.kind != .directory) return error.InvalidTaskDirectory;

    var env: std.ArrayList([2][]const u8) = .empty;
    try env.appendSlice(a, self.shell_env.entries);
    inline for (.{
        "ZIRCON_FILE",          "ZIRCON_RELATIVE_FILE", "ZIRCON_DIRNAME", "ZIRCON_STEM",
        "ZIRCON_WORKTREE_ROOT", "ZIRCON_ROW",           "ZIRCON_COLUMN",  "ZIRCON_SELECTED_TEXT",
    }) |name| {
        var number: [24]u8 = undefined;
        const value = try a.dupe(u8, vars.get(name, &number) orelse "");
        try env.append(a, .{ name, value });
    }
    for (task.env) |pair| try env.append(a, .{ pair[0], try expand(a, pair[1], vars) });

    var command: ?[]const u8 = null;
    var args: std.ArrayList([]const u8) = .empty;
    if (task.args.len == 0) {
        if (self.terminal.shell_program.len != 0) command = self.terminal.shell_program;
        try args.appendSlice(a, &.{ "-l", "-c", try shellCommand(a, task.command, vars, &env) });
    } else {
        command = try expand(a, task.command, vars);
        for (task.args) |arg| try args.append(a, try expand(a, arg, vars));
    }

    var saved = try task.clone(self.allocator);
    errdefer saved.deinit(self.allocator);
    try terminal_module.createTask(self, task.label, cwd, .{
        .command = command,
        .args = args.items,
        .extra_env = env.items,
        .max_history = self.terminal.max_scroll_history,
    });
    if (self.tasks.last) |*old| old.deinit(self.allocator);
    self.tasks.last = saved;
    cx.notify();
}

pub fn startPending(self: *Shell, cx: *ui.Context(Shell)) !void {
    while (self.tasks.pending.items.len != 0) {
        var task = self.tasks.pending.orderedRemove(0);
        defer task.deinit(self.allocator);
        runTask(self, cx, task) catch |err| {
            try self.reportError(err);
            continue;
        };
        try self.setStatus(try std.fmt.allocPrint(self.allocator, "Started task {s}", .{task.label}));
    }
}

pub fn rerunLast(self: *Shell, cx: *ui.Context(Shell)) !void {
    const last = self.tasks.last orelse return error.NoPreviousTask;
    try runTask(self, cx, last);
}
