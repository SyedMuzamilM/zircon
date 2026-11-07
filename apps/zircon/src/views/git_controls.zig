//! Repository menus and searchable branch, stash and remote pickers share the
//! command system. Payloads bind to the installed repository generation.
const std = @import("std");
const ui = @import("zircon_ui");
const Shell = @import("../shell.zig").Shell;
const catalogue = @import("../commands.zig");
const Command = catalogue.Command;
const service = @import("../services/git.zig");
const v = @import("components.zig");
const Target = struct { index: u32, generation: u64 };
pub fn defaultRemote(self: *const Shell) []const u8 {
    if (self.git.references) |refs| {
        for (refs.remotes) |remote| if (std.mem.eql(u8, remote, "origin")) return remote;
        if (refs.remotes.len == 1) return refs.remotes[0];
    }
    return "";
}
pub fn hasUpstream(self: *const Shell) bool {
    const status = self.git.status orelse return false;
    if (self.git.references) |refs| for (refs.branches) |branch| if (!branch.remote and std.mem.eql(u8, branch.name, status.branch)) return branch.upstream.len > 0;
    return false;
}
pub fn stashAction(self: *Shell, cx: *ui.Context(Shell), action: Command) !void {
    const refs = self.git.references orelse return error.NoStashes;
    var index: usize = 0;
    if (self.git.stash_oid.len > 0) {
        var found = false;
        for (refs.stashes, 0..) |entry, i| if (std.mem.eql(u8, entry.oid, self.git.stash_oid)) {
            index = i;
            found = true;
            break;
        };
        if (!found) return error.NoStashes;
    }
    if (index >= refs.stashes.len) return error.NoStashes;
    const stash = refs.stashes[index];
    if (action == .git_stash_show) {
        self.git.combined = false;
        self.git.stash_view = true;
        const oid = try std.heap.page_allocator.dupe(u8, stash.oid);
        std.heap.page_allocator.free(self.git.selected_commit);
        self.git.selected_commit = oid;
        self.showTool(.git_diff);
        try service.start(self, cx, .{ .stash_show = stash.oid });
    } else try service.start(self, cx, .{ .stash_apply = .{ .oid = stash.oid, .pop = action == .git_stash_pop } });
}
fn chooseBranch(self: *Shell, _: *ui.Event(ui.Click), cx: *ui.Context(Shell), target: Target) !void {
    if (target.generation != self.git.status_generation) return;
    const refs = self.git.references orelse return;
    if (target.index >= refs.branches.len) return;
    const branch = refs.branches[target.index];
    service.start(self, cx, .{ .switch_branch = .{ .name = branch.name, .track = branch.remote } }) catch |err| {
        try self.reportError(err);
        cx.notify();
        return;
    };
    self.git.menu = .none;
    cx.notify();
}
fn chooseStash(self: *Shell, _: *ui.Event(ui.Click), cx: *ui.Context(Shell), target: Target) !void {
    if (target.generation != self.git.status_generation) return;
    const refs = self.git.references orelse return;
    if (target.index >= refs.stashes.len) return;
    const oid = try std.heap.page_allocator.dupe(u8, refs.stashes[target.index].oid);
    std.heap.page_allocator.free(self.git.stash_oid);
    self.git.stash_oid = oid;
    self.git.stash_selected = target.index;
    try stashAction(self, cx, .git_stash_show);
    cx.notify();
}
fn chooseRemote(self: *Shell, _: *ui.Event(ui.Click), cx: *ui.Context(Shell), target: Target) !void {
    if (target.generation != self.git.status_generation) return;
    const refs = self.git.references orelse return;
    if (target.index >= refs.remotes.len) return;
    const remote = refs.remotes[target.index];
    service.start(self, cx, if (self.git.menu == .fetch_remote) .{ .network = .{ .fetch = remote } } else .{ .network = .{ .push = .{ .remote = remote } } }) catch |err| try self.reportError(err);
    self.git.menu = .none;
    cx.notify();
}
fn dismiss(self: *Shell, e: *ui.Event(ui.Input), cx: *ui.Context(Shell)) void {
    if (e.data == .pointer_down and e.phase == .target) {
        self.git.menu = .none;
        e.preventDefault();
        cx.notify();
    }
}
fn commandRow(self: *const Shell, b: *ui.Ui, command: Command, label: []const u8, enabled: bool) !ui.Element {
    if (enabled and !self.git.busy) return v.menuRow(b, self.colors, command, label, try self.key_bindings.shortcut(b.allocator(), command), false);
    return b.row(.{ .height = .{ .px = 30 }, .flex_shrink = 0, .align_items = .center, .padding = .{ .left = 10, .right = 10 }, .opacity = 0.45 }, &.{try v.text(b, label, self.colors.muted, 13)});
}
pub fn render(self: *const Shell, b: *ui.Ui) !ui.Element {
    const c = self.colors;
    var rows: std.ArrayList(ui.Element) = .empty;
    const refs = self.git.references;
    const remote = refs != null and refs.?.remotes.len > 0;
    const detached = if (self.git.status) |status| status.detached else true;
    const stash = refs != null and refs.?.stashes.len > 0;
    const query = if (self.fields) |fields| try @import("../view.zig").fieldText(b, fields.path) else "";
    switch (self.git.menu) {
        .network => {
            inline for (.{ .{ Command.git_fetch, "Fetch", true }, .{ Command.git_fetch_from, "Fetch from…", true }, .{ Command.git_pull, "Pull", false }, .{ Command.git_pull_rebase, "Pull with rebase", false } }) |item| try rows.append(b.allocator(), try commandRow(self, b, item[0], item[1], remote and (item[2] or hasUpstream(self))));
            try rows.append(b.allocator(), try v.rule(b, c));
            try rows.append(b.allocator(), try commandRow(self, b, .git_push, "Push", hasUpstream(self) and !detached));
            try rows.append(b.allocator(), try commandRow(self, b, .git_push_to, "Push to…", remote and !detached));
            try rows.append(b.allocator(), try commandRow(self, b, .git_publish, "Publish branch", defaultRemote(self).len > 0 and !detached));
            try rows.append(b.allocator(), try commandRow(self, b, .git_force_push, "Force push with lease", hasUpstream(self) and !detached));
        },
        .changes => {
            const has_changes = self.git.status != null and self.git.status.?.entries.len > 0;
            try rows.append(b.allocator(), try commandRow(self, b, .git_stage_all, "Stage all", has_changes));
            try rows.append(b.allocator(), try commandRow(self, b, .git_unstage_all, "Unstage all", has_changes));
            try rows.append(b.allocator(), try v.rule(b, c));
            try rows.append(b.allocator(), try commandRow(self, b, .git_stash_all, "Stash all", has_changes));
            try rows.append(b.allocator(), try commandRow(self, b, .git_stash_tracked, "Stash tracked", has_changes));
            try rows.append(b.allocator(), try commandRow(self, b, .git_stash_pop, "Pop latest stash", stash));
            try rows.append(b.allocator(), try commandRow(self, b, .git_stashes, "View stashes…", stash));
        },
        .branches, .stashes, .fetch_remote, .push_remote => {
            if (self.git.menu == .branches or self.git.menu == .stashes) try rows.append(b.allocator(), try b.row(.{ .height = .{ .px = 30 }, .flex_shrink = 0, .gap = 4 }, &.{ try v.actionButton(b, c, .git_branches, "Branches", self.git.menu == .branches), try v.actionButton(b, c, .git_stashes, "Stashes", self.git.menu == .stashes) }));
            try rows.append(b.allocator(), try v.text(b, switch (self.git.menu) {
                .branches => "Switch or create branch",
                .stashes => "Stashes",
                .fetch_remote => "Fetch from remote",
                else => "Push to remote",
            }, c.text, 13));
            if (self.fields) |fields| try rows.append(b.allocator(), try b.autofocus(try b.key(.{ .string = "git-picker-query" }, try b.view(fields.path))));
            var options: std.ArrayList(ui.Element) = .empty;
            if (refs) |references| switch (self.git.menu) {
                .branches => {
                    for (references.branches, 0..) |branch, i| if (@import("../view.zig").matches(query, branch.name)) {
                        const current = !branch.remote and self.git.status != null and std.mem.eql(u8, branch.name, self.git.status.?.branch);
                        try options.append(b.allocator(), try b.button(.{ .label = branch.name, .children = &.{ try v.icon(b, if (current) .check else .branch, if (current) c.accent else c.muted, 14), try b.column(.{ .gap = 3, .min_width = .{ .px = 0 }, .overflow = .hidden }, &.{ try v.text(b, branch.name, c.text, 13), try v.text(b, try std.fmt.allocPrint(b.allocator(), "{s} · {s}{s}", .{ branch.author, branch.subject, if (branch.remote) " · remote" else "" }), c.muted, 11) }) }, .on_click = if (self.git.busy) null else try b.onClickWith(Target{ .index = @intCast(i), .generation = self.git.status_generation }, chooseBranch), .style = .{ .direction = .row, .height = .{ .px = 52 }, .flex_shrink = 0, .gap = 8, .align_items = .center, .padding = .{ .left = 8, .right = 8 }, .radius = v.metrics.control_radius, .background = if (options.items.len == self.git.picker_index) c.selected else null, .hover_background = c.hover, .overflow = .hidden } }));
                    };
                    const name = std.mem.trim(u8, query, " ");
                    if (canCreate(self, name)) try options.append(b.allocator(), try commandRow(self, b, .git_create_branch, try std.fmt.allocPrint(b.allocator(), "Create branch {s}", .{name}), true));
                },
                .stashes => {
                    for (references.stashes, 0..) |entry, i| if (@import("../view.zig").matches(query, entry.subject)) try options.append(b.allocator(), try b.button(.{ .label = entry.subject, .children = &.{ try v.icon(b, .stash, c.muted, 14), try v.text(b, entry.subject, c.text, 12) }, .on_click = if (self.git.busy) null else try b.onClickWith(Target{ .index = @intCast(i), .generation = self.git.status_generation }, chooseStash), .style = .{ .direction = .row, .height = .{ .px = 32 }, .flex_shrink = 0, .gap = 8, .align_items = .center, .padding = .{ .left = 8 }, .background = if (options.items.len == self.git.picker_index) c.selected else null, .hover_background = c.hover, .overflow = .hidden } }));
                    if (self.git.stash_selected != null) {
                        try options.append(b.allocator(), try commandRow(self, b, .git_stash_apply, "Apply selected stash", true));
                        try options.append(b.allocator(), try commandRow(self, b, .git_stash_pop, "Pop selected stash", true));
                    }
                },
                .fetch_remote, .push_remote => for (references.remotes, 0..) |entry, i| {
                    if (!@import("../view.zig").matches(query, entry)) continue;
                    try options.append(b.allocator(), try b.button(.{ .label = entry, .on_click = try b.onClickWith(Target{ .index = @intCast(i), .generation = self.git.status_generation }, chooseRemote), .style = .{ .height = .{ .px = 30 }, .flex_shrink = 0, .padding = .{ .left = 10, .top = 6 }, .text = .{ .size = 13, .color = c.text }, .hover_background = c.hover } }));
                },
                else => {},
            };
            if (options.items.len == 0) try options.append(b.allocator(), try v.text(b, if (self.git.busy) "Loading…" else "No matching entries", c.muted, 12));
            try rows.append(b.allocator(), try b.listen(try b.column(.{ .flex_grow = 1, .min_height = .{ .px = 0 }, .scroll_y = self.git.picker_scroll.offset, .overflow = .hidden }, options.items), .{ .on_input = try b.onInputWith(@as(f32, @floatFromInt(options.items.len)) * (if (self.git.menu == .branches) @as(f32, 52) else 32), onScroll) }));
        },
        .none => unreachable,
    }
    if (self.status_is_error) try rows.append(b.allocator(), try v.text(b, self.status, c.warning, 12));
    const searchable = self.git.menu == .branches or self.git.menu == .stashes or self.git.menu == .fetch_remote or self.git.menu == .push_remote;
    const height = @min(if (searchable) @as(f32, 360) else @as(f32, @floatFromInt(rows.items.len)) * 30 + 12, b.viewport().height - 90);
    const placement = v.popoverBounds(b.viewport(), self.git_anchor, .{ .width = if (searchable) 440 else 300, .height = height });
    const popup = try b.key(.{ .string = "git-controls" }, try v.floatingPanel(b, c, .{ .width = placement.width, .height = placement.height }, ui.Insets.all(if (searchable) 12 else 6), if (searchable) 8 else 0, rows.items));
    return b.modal(try b.listen(try b.stack(.{ .padding = .{ .top = placement.y, .left = placement.x }, .align_items = .start }, &.{popup}), .{ .on_input = b.onInput(dismiss) }));
}

fn onScroll(self: *Shell, e: *ui.Event(ui.Input), cx: *ui.Context(Shell), total: f32) void {
    if (e.data != .scroll) return;
    self.git.picker_scroll.wheel(e.data.scroll.y, total, e.bounds.height);
    e.preventDefault();
    cx.notify();
}
pub fn input(self: *Shell, e: *ui.Event(ui.Input), cx: *ui.Context(Shell)) !bool {
    if (self.git.menu == .none) return false;
    if (e.data == .key_down and e.data.key_down.key == .escape) {
        self.git.menu = .none;
        e.preventDefault();
        e.stopPropagation();
        cx.notify();
        return true;
    }
    if (e.data != .key_down) return false;
    const key = e.data.key_down.key;
    if (key != .up and key != .down and key != .enter) return true;
    const searchable = self.git.menu == .branches or self.git.menu == .stashes or self.git.menu == .fetch_remote or self.git.menu == .push_remote;
    if (!searchable) return false;
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    var query: []u8 = &.{};
    try cx.read(self.fields.?.path, ui.controls.TextInput.copy, .{ arena.allocator(), &query });
    var indices: std.ArrayList(u32) = .empty;
    if (self.git.references) |refs| switch (self.git.menu) {
        .branches => for (refs.branches, 0..) |entry, i| {
            if (@import("../view.zig").matches(query, entry.name)) try indices.append(arena.allocator(), @intCast(i));
        },
        .stashes => for (refs.stashes, 0..) |entry, i| {
            if (@import("../view.zig").matches(query, entry.subject)) try indices.append(arena.allocator(), @intCast(i));
        },
        .fetch_remote, .push_remote => for (refs.remotes, 0..) |entry, i| {
            if (@import("../view.zig").matches(query, entry)) try indices.append(arena.allocator(), @intCast(i));
        },
        else => {},
    };
    const create = self.git.menu == .branches and canCreate(self, std.mem.trim(u8, query, " "));
    const count = indices.items.len + @intFromBool(create);
    if (count > 0) {
        self.git.picker_index = @min(self.git.picker_index, count - 1);
        if (key == .enter and !self.git.busy) {
            var click: ui.Event(ui.Click) = .{ .data = .{} };
            if (self.git.picker_index == indices.items.len) {
                try self.onCommand(&click, cx, .git_create_branch);
            } else {
                const target: Target = .{ .index = indices.items[self.git.picker_index], .generation = self.git.status_generation };
                switch (self.git.menu) {
                    .branches => try chooseBranch(self, &click, cx, target),
                    .stashes => try chooseStash(self, &click, cx, target),
                    else => try chooseRemote(self, &click, cx, target),
                }
            }
        } else if (key != .enter) {
            self.git.picker_index = if (key == .down) (self.git.picker_index + 1) % count else (self.git.picker_index + count - 1) % count;
            const row: f32 = if (self.git.menu == .branches) 52 else 32;
            self.git.picker_scroll.reveal(@as(f32, @floatFromInt(self.git.picker_index)) * row, @as(f32, @floatFromInt(self.git.picker_index + 1)) * row, @as(f32, @floatFromInt(count)) * row, 260);
        }
    }
    e.preventDefault();
    e.stopPropagation();
    cx.notify();
    return true;
}

fn canCreate(self: *const Shell, name: []const u8) bool {
    if (name.len == 0) return false;
    const refs = self.git.references orelse return false;
    for (refs.branches) |branch| if (!branch.remote and std.mem.eql(u8, branch.name, name)) return false;
    return true;
}
