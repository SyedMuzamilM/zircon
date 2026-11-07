//! Zed-style Changes/History rail. Virtual rows use a shared domain model so
//! collapsed folders, scrolling and staging all refer to repository paths.
const std = @import("std");
const ui = @import("zircon_ui");
const git = @import("zircon_git");
const Shell = @import("../shell.zig").Shell;
const tree = @import("../models/git_tree.zig");
const service = @import("../services/git.zig");
const Command = @import("../commands.zig").Command;
const v = @import("components.zig");
pub const row_height: f32 = 26;
pub const history_height: f32 = 56;
const Target = struct { index: u32, generation: u64 };
const DirectoryTarget = struct { target: Target, prefix_len: u32 };

pub fn render(self: *const Shell, b: *ui.Ui, width: f32, height: f32) !ui.Element {
    const c = self.colors;
    const history = self.left_panel == .git_history;
    const count = if (self.git.status) |status| status.entries.len else 0;
    var children: std.ArrayList(ui.Element) = .empty;
    try children.append(b.allocator(), try b.row(.{ .height = .{ .px = v.metrics.tabs }, .flex_shrink = 0, .background = c.tab_bar }, &.{ try tab(b, c, .git_changes, try std.fmt.allocPrint(b.allocator(), "Changes ({d})", .{count}), !history), try tab(b, c, .git_history, "History", history) }));
    const notices: f32 = if (self.git.error_text.len > 0) 28 else 0;
    if (!self.git.repository) {
        try children.append(b.allocator(), try b.column(.{ .flex_grow = 1, .padding = ui.Insets.all(12), .gap = 12 }, &.{ try v.text(b, "No Git repository", c.muted, 13), try v.iconButton(b, c, .git_refresh, "Refresh", .refresh, false) }));
    } else if (history) {
        var rows: std.ArrayList(ui.Element) = .empty;
        const visible = try ui.controls.visibleRows(self.git.commits.len, history_height, self.git.sidebar_scroll.offset, @max(1, height - 32 - notices), 0);
        for (self.git.commits[visible.start..visible.end], visible.start..) |commit, index| {
            const detail = try std.fmt.allocPrint(b.allocator(), "{s}  ·  {s}", .{ commit.author, commit.oid[0..@min(7, commit.oid.len)] });
            try rows.append(b.allocator(), try b.key(.{ .string = commit.oid }, try b.button(.{ .label = commit.subject, .children = &.{ try v.text(b, commit.subject, c.text, 13), try b.row(.{ .gap = 6, .align_items = .center }, &.{ try v.icon(b, .user, c.muted, 13), try v.text(b, detail, c.muted, 11) }) }, .on_click = try b.onClickWith(@as(u32, @intCast(index)), Shell.onGitCommit), .style = .{ .height = .{ .px = history_height }, .gap = 7, .padding = .{ .left = 12, .right = 12, .top = 8 }, .flex_shrink = 0, .background = if (std.mem.eql(u8, self.git.selected_commit, commit.oid)) c.selected else null, .hover_background = c.hover, .overflow = .hidden } })));
        }
        if (self.git.commits.len == 0) try rows.append(b.allocator(), try note(b, c, "No commits yet"));
        try children.append(b.allocator(), try list(b, rows.items, @max(0, -visible.top), @as(f32, @floatFromInt(self.git.commits.len)) * history_height));
    } else {
        const stage_control = try splitAction(b, c, .git_stage_all, .git_changes_menu, "Stage all", "Change actions", .plus, width >= 260, self.git.menu == .changes, self.git.busy);
        try children.append(b.allocator(), try b.row(.{ .height = .{ .px = 34 }, .flex_shrink = 0, .gap = 6, .align_items = .center, .padding = .{ .left = 8, .right = 8 } }, &.{ try ghostAction(b, c, .git_diff_all, "View diff", .diff), try b.div(.{ .flex_grow = 1 }, &.{}), try b.key(.{ .string = "git-stage-control" }, stage_control), try v.iconButton(b, c, .git_refresh, "Refresh", .refresh, false) }));
        var rows: std.ArrayList(ui.Element) = .empty;
        var total: f32 = 0;
        var scroll_y: f32 = 0;
        if (self.git.status) |status| {
            const model_rows = try self.git.tree.rows(b.allocator(), status.entries);
            total = @as(f32, @floatFromInt(model_rows.len)) * row_height;
            const reserved = v.metrics.tabs + 34 + 1 + 30 + 1 + 112 + if (self.git.commits.len > 0) @as(f32, 28) else 0;
            const visible = try ui.controls.visibleRows(model_rows.len, row_height, self.git.sidebar_scroll.offset, @max(1, height - reserved - notices), 0);
            scroll_y = @max(0, -visible.top);
            for (model_rows[visible.start..visible.end]) |row| try rows.append(b.allocator(), try treeRow(self, b, status.entries, row));
            if (status.entries.len == 0) try rows.append(b.allocator(), try note(b, c, "Working tree clean"));
        }
        try children.append(b.allocator(), try list(b, rows.items, scroll_y, total));
        try children.append(b.allocator(), try v.rule(b, c));
        const branch = if (self.git.status) |status| if (status.branch.len > 0) status.branch else "Detached HEAD" else "Loading…";
        const upstream = @import("git_controls.zig").hasUpstream(self);
        const publish = try splitAction(b, c, if (upstream) .git_push else .git_publish, .git_network_menu, if (upstream) "Push" else "Publish", "Remote actions", .arrow_up, width >= 220, self.git.menu == .network, self.git.busy);
        try children.append(b.allocator(), try b.row(.{ .height = .{ .px = 30 }, .flex_shrink = 0, .padding = .{ .left = 12, .right = 8 }, .gap = 6, .align_items = .center }, &.{ try b.button(.{ .label = "Switch branch", .children = &.{ try v.icon(b, .branch, c.muted, 14), try v.text(b, branch, c.text, 12) }, .on_click = try b.onClickWith(Command.git_branches, Shell.onCommand), .style = .{ .direction = .row, .gap = 5, .flex_grow = 1, .min_width = .{ .px = 0 }, .align_items = .center, .hover_background = c.hover, .overflow = .hidden } }), try b.key(.{ .string = "git-publish-control" }, publish) }));
        try children.append(b.allocator(), try v.rule(b, c));
        var staged = false;
        var conflicted = false;
        if (self.git.status) |status| for (status.entries) |entry| {
            staged = staged or entry.staged;
            conflicted = conflicted or entry.conflicted;
        };
        const message_text = if (self.fields) |fields| try @import("../view.zig").fieldText(b, fields.commit) else "";
        const commit_ready = staged and !conflicted and !self.git.busy and std.mem.trim(u8, message_text, " \t\r\n").len > 0;
        var commit_style = v.buttonStyle(c, commit_ready);
        if (!commit_ready) commit_style.background = c.hover;
        var commit: std.ArrayList(ui.Element) = .empty;
        if (self.fields) |fields| try commit.append(b.allocator(), try b.key(.{ .string = "commit-message" }, try b.styled(try b.view(fields.commit), .{ .height = .{ .px = 48 }, .flex_shrink = 0 })));
        try commit.append(b.allocator(), try b.row(.{ .align_items = .center }, &.{ try v.icon(b, .commit, c.muted, 15), try b.div(.{ .flex_grow = 1 }, &.{}), try b.button(.{ .label = "Commit staged changes", .children = &.{try v.text(b, "Commit staged", if (commit_ready) c.on_primary else c.muted, 12)}, .on_click = if (commit_ready) try b.onClickWith(Command.git_commit, Shell.onCommand) else null, .style = commit_style }) }));
        try children.append(b.allocator(), try b.column(.{ .height = .{ .px = 112 }, .flex_shrink = 0, .padding = ui.Insets.all(8), .gap = 12, .background = c.document }, commit.items));
        if (self.git.commits.len > 0) {
            const last = self.git.commits[0];
            try children.append(b.allocator(), try b.key(.{ .string = "latest-commit" }, try b.button(.{ .label = last.subject, .children = &.{ try v.icon(b, .commit, c.muted, 14), try v.text(b, last.subject, c.muted, 11) }, .on_click = try b.onClickWith(@as(u32, 0), Shell.onGitCommit), .style = .{ .direction = .row, .height = .{ .px = 28 }, .align_items = .center, .gap = 7, .padding = .{ .left = 12, .right = 8 }, .flex_shrink = 0, .hover_background = c.hover, .overflow = .hidden } })));
        }
    }
    if (self.git.error_text.len > 0) try children.append(b.allocator(), try b.styled(try v.text(b, self.git.error_text, c.warning, 11), .{ .height = .{ .px = 28 }, .flex_shrink = 0, .padding = ui.Insets.all(6), .text = .{ .size = 11, .color = c.warning }, .overflow = .hidden }));
    return b.key(.{ .string = "git-sidebar" }, try b.column(.{ .width = .{ .px = width }, .flex_shrink = 0, .background = c.sidebar, .overflow = .hidden }, children.items));
}
fn tab(b: *ui.Ui, c: v.Palette, command: Command, name: []const u8, selected: bool) !ui.Element {
    return b.column(.{ .width = .{ .percent = 50 }, .flex_shrink = 0, .min_width = .{ .px = 0 }, .background = if (selected) c.document else c.sidebar }, &.{ try b.button(.{ .label = name, .on_click = try b.onClickWith(command, Shell.onCommand), .style = .{ .direction = .row, .flex_grow = 1, .align_items = .center, .justify_content = .center, .hover_background = c.hover, .text = .{ .size = 13, .color = if (selected) c.text else c.muted } } }), try b.div(.{ .height = .{ .px = 1 }, .flex_shrink = 0, .background = if (selected) c.document else c.line }, &.{}) });
}
fn list(b: *ui.Ui, rows: []const ui.Element, scroll_y: f32, total: f32) !ui.Element {
    return b.listen(try b.key(.{ .string = "git-list" }, try b.column(.{ .flex_grow = 1, .min_height = .{ .px = 0 }, .scroll_y = scroll_y, .overflow = .hidden }, rows)), .{ .on_input = try b.onInputWith(total, onScroll) });
}
fn onScroll(self: *Shell, e: *ui.Event(ui.Input), cx: *ui.Context(Shell), total: f32) void {
    if (e.data != .scroll) return;
    self.git.sidebar_scroll.wheel(e.data.scroll.y, total, e.bounds.height);
    e.preventDefault();
    cx.notify();
}
fn treeRow(self: *const Shell, b: *ui.Ui, entries: []const git.Entry, row: tree.Row) !ui.Element {
    const c = self.colors;
    switch (row) {
        .section => |section| {
            const name: []const u8 = switch (section.group) {
                .tracked => "Tracked",
                .untracked => "Untracked",
                .conflicts => "Conflicts",
            };
            return b.key(.{ .number = @backingInt(section.group) }, try b.button(.{ .label = name, .children = &.{ try v.icon(b, if (self.git.tree.sections[@backingInt(section.group)]) .chevron_right else .chevron_down, c.muted, 12), try v.text(b, name, c.muted, 12), try v.text(b, try std.fmt.allocPrint(b.allocator(), "({d})", .{section.count}), c.muted, 11) }, .on_click = try b.onClickWith(section.group, toggleSection), .style = .{ .direction = .row, .height = .{ .px = row_height }, .flex_shrink = 0, .gap = 5, .align_items = .center, .padding = .{ .left = 10, .right = 8 }, .hover_background = c.hover } }));
        },
        .directory => |directory| return b.key(.{ .string = try std.fmt.allocPrint(b.allocator(), "{s}:{s}", .{ @tagName(directory.group), directory.path }) }, try b.button(.{ .label = directory.path, .children = &.{ try v.icon(b, if (self.git.tree.directories.contains(directory.path)) .chevron_right else .chevron_down, c.muted, 12), try v.icon(b, .folder, c.muted, 15), try v.text(b, std.fs.path.basename(directory.path), c.muted, 12) }, .on_click = try b.onClickWith(DirectoryTarget{ .target = .{ .index = directory.entry, .generation = self.git.status_generation }, .prefix_len = @intCast(directory.path.len) }, toggleDirectory), .style = .{ .direction = .row, .height = .{ .px = row_height }, .gap = 5, .align_items = .center, .flex_shrink = 0, .padding = .{ .left = 12 + @as(f32, @floatFromInt(directory.depth)) * 14 }, .hover_background = c.hover, .overflow = .hidden } })),
        .file => |file| {
            const entry = entries[file.index];
            const selected = std.mem.eql(u8, self.git.selected_path, entry.path);
            var style = v.iconButtonStyle(c, false);
            const name = try std.fmt.allocPrint(b.allocator(), "{s} {s}", .{ if (entry.staged and !entry.unstaged) "Unstage" else "Stage", entry.path });
            const staging = try b.button(.{ .label = name, .tooltip = name, .tooltip_colors = .{ c.panel, c.text, c.line }, .children = &.{try v.icon(b, if (entry.staged and entry.unstaged) .square_mixed else if (entry.staged) .square_checked else .square, if (entry.staged) c.accent else c.muted, 16)}, .on_click = try b.onClickWith(Target{ .index = file.index, .generation = self.git.status_generation }, stage), .style = style });
            style = .{ .direction = .row, .height = .{ .px = row_height }, .flex_grow = 1, .min_width = .{ .px = 0 }, .gap = 6, .align_items = .center, .padding = .{ .left = 26 + @as(f32, @floatFromInt(file.depth)) * 14 }, .overflow = .hidden };
            const target = try b.button(.{ .label = entry.path, .children = &.{ try v.fileGlyph(self, b, entry.path, false, false, 15), try b.styled(try v.text(b, std.fs.path.basename(entry.path), c.text, 12), .{ .flex_grow = 1, .min_width = .{ .px = 0 }, .text = .{ .size = 12, .color = c.text }, .overflow = .hidden }), try changeBadges(b, c, entry) }, .on_click = try b.onClickWith(Target{ .index = file.index, .generation = self.git.status_generation }, openFile), .style = style });
            return b.key(.{ .string = entry.path }, try b.row(.{ .height = .{ .px = row_height }, .flex_shrink = 0, .align_items = .center, .padding = .{ .right = 6 }, .background = if (selected) c.selected else null, .hover_background = c.hover }, &.{ target, staging }));
        },
    }
}
fn toggleSection(self: *Shell, _: *ui.Event(ui.Click), cx: *ui.Context(Shell), group: tree.Group) void {
    const index = @backingInt(group);
    self.git.tree.sections[index] = !self.git.tree.sections[index];
    self.git.sidebar_scroll.offset = 0;
    cx.notify();
}
fn resolve(self: *const Shell, target: Target) ?git.Entry {
    if (target.generation != self.git.status_generation) return null;
    const status = self.git.status orelse return null;
    return if (target.index < status.entries.len) status.entries[target.index] else null;
}
fn toggleDirectory(self: *Shell, _: *ui.Event(ui.Click), cx: *ui.Context(Shell), directory: DirectoryTarget) !void {
    const entry = resolve(self, directory.target) orelse return;
    if (directory.prefix_len >= entry.path.len or entry.path[directory.prefix_len] != '/') return;
    try self.git.tree.toggleDirectory(std.heap.page_allocator, entry.path[0..directory.prefix_len]);
    self.git.sidebar_scroll.offset = 0;
    cx.notify();
}
fn stage(self: *Shell, _: *ui.Event(ui.Click), cx: *ui.Context(Shell), target: Target) !void {
    const entry = resolve(self, target) orelse return;
    service.start(self, cx, if (entry.staged and !entry.unstaged) .{ .unstage = entry.path } else .{ .stage = entry.path }) catch |err| try self.reportError(err);
    cx.notify();
}
fn openFile(self: *Shell, e: *ui.Event(ui.Click), cx: *ui.Context(Shell), target: Target) !void {
    _ = resolve(self, target) orelse return;
    try self.onGitFile(e, cx, target.index);
}
fn ghostAction(b: *ui.Ui, c: v.Palette, command: Command, name: []const u8, icon: v.Icon) !ui.Element {
    var style = v.buttonStyle(c, false);
    style.background = null;
    style.padding = .{ .left = 2, .right = 4 };
    return b.button(.{ .label = name, .children = &.{ try v.icon(b, icon, c.muted, 14), try v.text(b, name, c.muted, 12) }, .on_click = try b.onClickWith(command, Shell.onCommand), .style = style });
}
fn note(b: *ui.Ui, c: v.Palette, bytes: []const u8) !ui.Element {
    return b.styled(try v.text(b, bytes, c.muted, 12), .{ .padding = ui.Insets.all(12), .text = .{ .size = 12, .color = c.muted } });
}

/// The main action and its menu share one surface, with independent hit targets.
fn splitAction(b: *ui.Ui, c: v.Palette, action: Command, menu: Command, label: []const u8, menu_label: []const u8, glyph: v.Icon, show_label: bool, selected: bool, busy: bool) !ui.Element {
    return b.row(.{ .height = .{ .px = 22 }, .flex_shrink = 0, .radius = v.metrics.control_radius, .background = c.element, .overflow = .hidden }, &.{
        try b.button(.{ .label = label, .tooltip = label, .tooltip_colors = .{ c.panel, c.text, c.line }, .children = if (show_label) &.{ try v.icon(b, glyph, c.muted, 12), try v.text(b, label, c.text, 11) } else &.{try v.icon(b, glyph, c.muted, 12)}, .on_click = if (busy) null else try b.onClickWith(action, Shell.onCommand), .style = .{ .direction = .row, .height = .{ .px = 22 }, .gap = 4, .padding = .{ .left = 6, .right = 6 }, .align_items = .center, .hover_background = c.hover, .opacity = if (busy) 0.5 else 1 } }),
        try b.div(.{ .width = .{ .px = 1 }, .height = .{ .px = 14 }, .margin = .{ .top = 4 }, .background = c.line, .flex_shrink = 0 }, &.{}),
        try b.button(.{ .label = menu_label, .tooltip = menu_label, .tooltip_colors = .{ c.panel, c.text, c.line }, .children = &.{try v.icon(b, .chevron_down, c.muted, 12)}, .on_click = try b.onClickWith(menu, Shell.onCommand), .style = .{ .width = .{ .px = 20 }, .height = .{ .px = 22 }, .align_items = .center, .justify_content = .center, .background = if (selected) c.selected else null, .hover_background = c.hover } }),
    });
}
fn changeBadges(b: *ui.Ui, c: v.Palette, entry: git.Entry) !ui.Element {
    var badges: std.ArrayList(ui.Element) = .empty;
    if (entry.stats) |stats| {
        if (stats.binary) return badge(b, "Binary", c.muted);
        if (stats.added > 0 or stats.deleted == 0) try badges.append(b.allocator(), try badge(b, try std.fmt.allocPrint(b.allocator(), "+{d}", .{stats.added}), c.added));
        if (stats.deleted > 0) try badges.append(b.allocator(), try badge(b, try std.fmt.allocPrint(b.allocator(), "−{d}", .{stats.deleted}), c.deleted));
    } else try badges.append(b.allocator(), try badge(b, "…", c.muted));
    return b.row(.{ .gap = 3, .align_items = .center, .flex_shrink = 0 }, badges.items);
}
fn badge(b: *ui.Ui, label: []const u8, color: ui.Color) !ui.Element {
    var background = color;
    background.a = 0.12;
    return b.row(.{ .height = .{ .px = 18 }, .padding = .{ .left = 5, .right = 5 }, .radius = 4, .align_items = .center, .background = background, .flex_shrink = 0 }, &.{try v.text(b, label, color, 11)});
}
