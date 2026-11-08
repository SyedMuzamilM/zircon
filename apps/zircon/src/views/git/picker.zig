//! Repository menus and searchable branch, stash and remote pickers share the
//! command system. Payloads bind to the installed repository generation.
const std = @import("std");
const ui = @import("zircon_ui");
const catalogue = @import("../../commands.zig");
const service = @import("../../services/git.zig");
const shell = @import("../../shell.zig");
const v = @import("../components.zig");
const field_input = @import("../input.zig");
const overlays = @import("../overlays.zig");
const git_controls = @import("menus.zig");
const Shell = shell.Shell;

pub const Fields = struct {
    query: field_input.Handle,

    pub fn init(cx: *ui.Context(Shell), a: std.mem.Allocator) !Fields {
        return .{ .query = try field_input.create(cx, a, .{ .height = 32 }) };
    }
};

const Command = catalogue.Command;
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

pub fn append(self: *const Shell, b: *ui.Ui, rows: *std.ArrayList(ui.Element)) !void {
    const c = self.colors;
    const refs = self.git.references;
    const query = if (self.fields) |fields| try field_input.text(b, fields.git_picker.query) else "";
    if (self.git.menu == .branches or self.git.menu == .stashes) try rows.append(b.allocator(), try b.fluent().div()
        .h(.{ .px = 30 })
        .shrink_0()
        .padding(ui.Insets.all(2))
        .rounded_px(v.metrics.control_radius)
        .background(c.document)
        .flex()
        .children(.{ modeTab(self, b, false), modeTab(self, b, true) })
        .id(.{ .string = "git-picker-tabs" })
        .build());
    try rows.append(b.allocator(), try v.text(b, switch (self.git.menu) {
        .branches => "Switch or create branch",
        .stashes => "Stashes",
        .fetch_remote => "Fetch from remote",
        else => "Push to remote",
    }, c.text, 13));
    if (self.fields) |fields| try rows.append(b.allocator(), try b.fluent().view(fields.git_picker.query)
        .id(.{ .string = switch (self.git.menu) {
            .branches => "git-branch-query",
            .stashes => "git-stash-query",
            .fetch_remote => "git-fetch-query",
            else => "git-push-query",
        } }).autofocus().build());
    var options: std.ArrayList(ui.Element) = .empty;
    if (refs) |references| switch (self.git.menu) {
        .branches => {
            for (references.branches, 0..) |branch, i| if (overlays.matches(query, branch.name)) {
                const current = !branch.remote and self.git.status != null and std.mem.eql(u8, branch.name, self.git.status.?.branch);
                try options.append(b.allocator(), try b.fluent().button(.{
                    .label = branch.name,
                })
                    .flex()
                    .h(.{ .px = 52 })
                    .shrink_0()
                    .gap_px(8)
                    .items_center()
                    .padding(.{ .left = 8, .right = 8 })
                    .rounded_px(v.metrics.control_radius)
                    .background(if (options.items.len == self.git.picker_index) c.selected else null)
                    .hover_background(c.hover)
                    .overflow_hidden()
                    .on_click(if (self.git.updating()) null else try b.onClickWith(chooseBranch, Target{ .index = @intCast(i), .generation = self.git.status_generation }))
                    .children(&.{
                        try v.icon(b, if (current) .check else .branch, if (current) c.accent else c.muted, 14),
                        try b.fluent().div()
                            .gap_px(3)
                            .min_w(.{ .px = 0 })
                            .overflow_hidden()
                            .flex_col()
                            .children(.{
                                v.text(b, branch.name, c.text, 13),
                                v.text(b, try std.fmt.allocPrint(b.allocator(), "{s} · {s}{s}", .{ branch.author, branch.subject, if (branch.remote) " · remote" else "" }), c.muted, 11),
                            }).build(),
                    }).build());
            };
            const name = std.mem.trim(u8, query, " ");
            if (canCreate(self, name)) try options.append(b.allocator(), try git_controls.commandRow(self, b, .git_create_branch, try std.fmt.allocPrint(b.allocator(), "Create branch {s}", .{name}), true));
        },
        .stashes => {
            for (references.stashes, 0..) |entry, i| if (overlays.matches(query, entry.subject)) try options.append(b.allocator(), try b.fluent().button(.{
                .label = entry.subject,
            })
                .flex()
                .h(.{ .px = 32 })
                .shrink_0()
                .gap_px(8)
                .items_center()
                .padding(.{ .left = 8 })
                .background(if (options.items.len == self.git.picker_index) c.selected else null)
                .hover_background(c.hover)
                .overflow_hidden()
                .on_click(if (self.git.updating()) null else try b.onClickWith(chooseStash, Target{ .index = @intCast(i), .generation = self.git.status_generation }))
                .children(&.{
                    try v.icon(b, .stash, c.muted, 14),
                    try v.text(b, entry.subject, c.text, 12),
                }).build());
            if (self.git.stash_selected != null) {
                try options.append(b.allocator(), try git_controls.commandRow(self, b, .git_stash_apply, "Apply selected stash", true));
                try options.append(b.allocator(), try git_controls.commandRow(self, b, .git_stash_pop, "Pop selected stash", true));
            }
        },
        .fetch_remote, .push_remote => for (references.remotes, 0..) |entry, i| {
            if (!overlays.matches(query, entry)) continue;
            try options.append(b.allocator(), try b.fluent().button(.{
                .label = entry,
            })
                .h(.{ .px = 30 })
                .shrink_0()
                .padding(.{ .left = 10, .top = 6 })
                .text_style(.{ .size = 13, .color = c.text })
                .hover_background(c.hover)
                .on_click(b.onClickWith(chooseRemote, Target{ .index = @intCast(i), .generation = self.git.status_generation }))
                .build());
        },
        else => {},
    };
    if (options.items.len == 0) try options.append(b.allocator(), try v.text(b, if (self.git.updating()) "Loading…" else "No matching entries", c.muted, 12));
    try rows.append(b.allocator(), try b.fluent().div()
        .grow()
        .min_h(.{ .px = 0 })
        .scroll_y_px(self.git.picker_scroll.offset)
        .overflow_hidden()
        .flex_col()
        .children(options.items)
        .listeners(.{
            .on_input = b.onInputWith(onScroll, @as(f32, @floatFromInt(options.items.len)) * (if (self.git.menu == .branches) @as(f32, 52) else 32)),
        }).build());
}

fn switchMode(self: *Shell, _: *ui.Event(ui.Click), cx: *ui.Context(Shell), stashes: bool) !void {
    const next: @TypeOf(self.git.menu) = if (stashes) .stashes else .branches;
    if (self.git.menu == next) return;
    // Internal tabs retain the original opener's bounds and installed refs.
    // Running the global open command here would move the popup every click.
    try prepare(self, cx, if (stashes) .stashes else .branches);
    self.git.menu = next;
    self.git.picker_index = 0;
    self.git.picker_scroll.offset = 0;
    self.git.stash_selected = null;
    std.heap.page_allocator.free(self.git.stash_oid);
    self.git.stash_oid = &.{};
    cx.notify();
}

fn modeTab(self: *const Shell, b: *ui.Ui, stashes: bool) !ui.Element {
    const c = self.colors;
    const selected = if (stashes) self.git.menu == .stashes else self.git.menu == .branches;
    return b.fluent().button(.{
        .label = if (stashes) "Stashes" else "Branches",
    })
        .flex()
        .grow()
        .h(.{ .px = 26 })
        .gap_px(6)
        .items_center()
        .justify_center()
        .rounded_px(4)
        .background(if (selected) c.selected else null)
        .hover_background(c.hover)
        .on_click(b.onClickWith(switchMode, stashes))
        .children(&.{
            try v.icon(b, if (stashes) .stash else .branch, if (selected) c.text else c.muted, 14),
            try v.text(b, if (stashes) "Stashes" else "Branches", if (selected) c.text else c.muted, 12),
        }).build();
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
    try cx.read(self.fields.?.git_picker.query, ui.controls.TextInput.copy, .{ arena.allocator(), &query });
    var indices: std.ArrayList(u32) = .empty;
    if (self.git.references) |refs| switch (self.git.menu) {
        .branches => for (refs.branches, 0..) |entry, i| {
            if (overlays.matches(query, entry.name)) try indices.append(arena.allocator(), @intCast(i));
        },
        .stashes => for (refs.stashes, 0..) |entry, i| {
            if (overlays.matches(query, entry.subject)) try indices.append(arena.allocator(), @intCast(i));
        },
        .fetch_remote, .push_remote => for (refs.remotes, 0..) |entry, i| {
            if (overlays.matches(query, entry)) try indices.append(arena.allocator(), @intCast(i));
        },
        else => {},
    };
    const create = self.git.menu == .branches and canCreate(self, std.mem.trim(u8, query, " "));
    const count = indices.items.len + @intFromBool(create);
    if (count > 0) {
        self.git.picker_index = @min(self.git.picker_index, count - 1);
        if (key == .enter and !self.git.updating()) {
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

pub fn prepare(self: *Shell, cx: *ui.Context(Shell), menu: @FieldType(@FieldType(Shell, "git"), "menu")) !void {
    const placeholder = switch (menu) {
        .branches => "Switch or type to create a branch…",
        .stashes => "Search stashes…",
        else => "Search remotes…",
    };
    try field_input.reset(cx, self.fields.?.git_picker.query, "", .{ .placeholder = placeholder, .height = 32 });
}
