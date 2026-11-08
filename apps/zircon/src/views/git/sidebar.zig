//! Zed-style Changes/History rail. Virtual rows use a shared domain model so
//! collapsed folders, scrolling and staging all refer to repository paths.
const std = @import("std");
const ui = @import("zircon_ui");
const commands = @import("../../commands.zig");
const shell = @import("../../shell.zig");
const v = @import("../components.zig");
const commit_form = @import("commit.zig");
const files = @import("files.zig");
const git_controls = @import("menus.zig");
const Shell = shell.Shell;
const Command = commands.Command;
pub const row_height = files.row_height;
pub const history_height: f32 = 56;

pub fn render(self: *const Shell, b: *ui.Ui, width: f32, height: f32) !ui.Element {
    const c = self.colors;
    const history = self.left_panel == .git_history;
    const count = if (self.git.status) |status| status.entries.len else 0;
    var children: std.ArrayList(ui.Element) = .empty;
    try children.append(b.allocator(), try b.fluent().div()
        .h(.{ .px = v.metrics.tabs })
        .shrink_0()
        .background(c.tab_bar)
        .flex()
        .children(.{
            tab(b, c, .git_changes, try std.fmt.allocPrint(b.allocator(), "Changes ({d})", .{count}), !history),
            tab(b, c, .git_history, "History", history),
        }).build());
    const notices: f32 = if (self.git.error_text.len > 0) 28 else 0;
    if (!self.git.repository) {
        try children.append(b.allocator(), try b.fluent().div()
            .grow()
            .padding(ui.Insets.all(12))
            .gap_px(12)
            .flex_col()
            .children(.{
                v.text(b, "No Git repository", c.muted, 13),
                v.iconButton(b, c, .git_refresh, "Refresh", .refresh, false),
            }).build());
    } else if (history) {
        try children.append(b.allocator(), try historyList(self, b, height, notices));
    } else {
        try children.append(b.allocator(), try changesToolbar(self, b, width));
        try children.append(b.allocator(), try changedFiles(self, b, height, notices));
        try children.append(b.allocator(), try v.rule(b, c));
        try children.append(b.allocator(), try branchRow(self, b, width));
        try children.append(b.allocator(), try v.rule(b, c));
        try children.append(b.allocator(), try commit_form.render(self, b));
        if (self.git.commits.len > 0) try children.append(b.allocator(), try latestCommit(self, b));
    }
    if (self.git.error_text.len > 0) try children.append(b.allocator(), try b.fluent().adopt(try v.text(b, self.git.error_text, c.warning, 11))
        .style(.{
            .height = .{ .px = 28 },
            .flex_shrink = 0,
            .padding = ui.Insets.all(6),
            .text = .{ .size = 11, .color = c.warning },
            .overflow = .hidden,
        }).build());
    return b.fluent().div()
        .w(.{ .px = width })
        .shrink_0()
        .background(c.sidebar)
        .overflow_hidden()
        .flex_col()
        .children(children.items)
        .id(.{ .string = "git-sidebar" })
        .build();
}

fn tab(b: *ui.Ui, c: v.Palette, command: Command, name: []const u8, selected: bool) !ui.Element {
    return b.fluent().div()
        .w(.{ .percent = 50 })
        .shrink_0()
        .min_w(.{ .px = 0 })
        .background(if (selected) c.sidebar else c.document)
        .flex_col()
        .children(&.{
            try b.fluent().button(.{
                .label = name,
            })
                .flex()
                .grow()
                .items_center()
                .justify_center()
                .hover_background(c.hover)
                .text_style(.{ .size = 13, .color = if (selected) c.text else c.muted })
                .on_click(b.onClickWith(Shell.onCommand, command))
                .build(),
            try b.fluent().div()
                .h(.{ .px = 1 })
                .shrink_0()
                .background(if (selected) c.document else c.line)
                .children(.{})
                .build(),
        }).build();
}

fn list(b: *ui.Ui, rows: []const ui.Element, scroll_y: f32, total: f32) !ui.Element {
    return b.fluent().div()
        .grow()
        .min_h(.{ .px = 0 })
        .scroll_y_px(scroll_y)
        .overflow_hidden()
        .flex_col()
        .children(rows)
        .id(.{ .string = "git-list" })
        .listeners(.{ .on_input = b.onInputWith(onScroll, total) })
        .build();
}

fn onScroll(self: *Shell, e: *ui.Event(ui.Input), cx: *ui.Context(Shell), total: f32) void {
    if (e.data != .scroll) return;
    self.git.sidebar_scroll.wheel(e.data.scroll.y, total, e.bounds.height);
    e.preventDefault();
    cx.notify();
}

fn ghostAction(b: *ui.Ui, c: v.Palette, command: Command, name: []const u8, icon: v.Icon) !ui.Element {
    var style = v.buttonStyle(c, false);
    style.background = null;
    style.padding = .{ .left = 2, .right = 4 };
    return b.fluent().button(.{
        .label = name,
    }).style(style).on_click(b.onClickWith(Shell.onCommand, command)).children(&.{
        try v.icon(b, icon, c.muted, 14),
        try v.text(b, name, c.muted, 12),
    }).build();
}

fn note(b: *ui.Ui, c: v.Palette, bytes: []const u8) !ui.Element {
    return b.fluent().adopt(try v.text(b, bytes, c.muted, 12)).style(.{
        .padding = ui.Insets.all(12),
        .text = .{ .size = 12, .color = c.muted },
    }).build();
}

/// The main action and its menu share one surface, with independent hit targets.
fn splitAction(b: *ui.Ui, c: v.Palette, action: Command, menu: Command, label: []const u8, menu_label: []const u8, glyph: v.Icon, show_label: bool, selected: bool, busy: bool) !ui.Element {
    return b.fluent().div()
        .h(.{ .px = 22 })
        .shrink_0()
        .rounded_px(v.metrics.control_radius)
        .background(c.element)
        .overflow_hidden()
        .flex()
        .children(&.{
            try b.fluent().button(.{
                .label = label,
                .tooltip = label,
                .tooltip_colors = .{ c.panel, c.text, c.line },
            })
                .flex()
                .h(.{ .px = 22 })
                .gap_px(4)
                .padding(.{ .left = 6, .right = 6 })
                .items_center()
                .hover_background(c.hover)
                .opacity(if (busy) 0.5 else 1)
                .on_click(if (busy) null else try b.onClickWith(Shell.onCommand, action))
                .children(if (show_label) &.{ try v.icon(b, glyph, c.muted, 12), try v.text(b, label, c.text, 11) } else &.{try v.icon(b, glyph, c.muted, 12)})
                .build(),
            try b.fluent().div()
                .w(.{ .px = 1 })
                .h(.{ .px = 14 })
                .margin(.{ .top = 4 })
                .background(c.line)
                .shrink_0()
                .children(.{})
                .build(),
            try b.fluent().button(.{
                .label = menu_label,
                .tooltip = menu_label,
                .tooltip_colors = .{ c.panel, c.text, c.line },
            })
                .w(.{ .px = 20 })
                .h(.{ .px = 22 })
                .items_center()
                .justify_center()
                .background(if (selected) c.selected else null)
                .hover_background(c.hover)
                .on_click(b.onClickWith(Shell.onCommand, menu))
                .children(&.{try v.icon(b, .chevron_down, c.muted, 12)})
                .build(),
        }).build();
}

fn historyList(self: *const Shell, b: *ui.Ui, height: f32, notices: f32) !ui.Element {
    const c = self.colors;
    var rows: std.ArrayList(ui.Element) = .empty;
    const visible = try ui.controls.visibleRows(self.git.commits.len, history_height, self.git.sidebar_scroll.offset, @max(1, height - 32 - notices), 0);
    for (self.git.commits[visible.start..visible.end], visible.start..) |commit, index| {
        const detail = try std.fmt.allocPrint(b.allocator(), "{s}  ·  {s}", .{ commit.author, commit.oid[0..@min(7, commit.oid.len)] });
        try rows.append(b.allocator(), try b.fluent().button(.{
            .label = commit.subject,
        })
            .h(.{ .px = history_height })
            .gap_px(7)
            .padding(.{ .left = 12, .right = 12, .top = 8 })
            .shrink_0()
            .background(if (std.mem.eql(u8, self.git.selected_commit, commit.oid)) c.selected else null)
            .hover_background(c.hover)
            .overflow_hidden()
            .on_click(b.onClickWith(Shell.onGitCommit, @as(u32, @intCast(index))))
            .children(&.{
                try v.text(b, commit.subject, c.text, 13),
                try b.fluent().div()
                    .gap_px(6)
                    .items_center()
                    .flex()
                    .children(.{ v.icon(b, .user, c.muted, 13), v.text(b, detail, c.muted, 11) })
                    .build(),
            }).id(.{ .string = commit.oid }).build());
    }
    if (self.git.commits.len == 0) try rows.append(b.allocator(), try note(b, c, "No commits yet"));
    return list(b, rows.items, @max(0, -visible.top), @as(f32, @floatFromInt(self.git.commits.len)) * history_height);
}

fn changesToolbar(self: *const Shell, b: *ui.Ui, width: f32) !ui.Element {
    const c = self.colors;
    const stage_control = try splitAction(b, c, .git_stage_all, .git_changes_menu, "Stage all", "Change actions", .plus, width >= 260, self.git.menu == .changes, self.git.updating());
    return b.fluent().div()
        .h(.{ .px = 34 })
        .shrink_0()
        .gap_px(6)
        .items_center()
        .padding(.{ .left = 8, .right = 8 })
        .flex()
        .children(&.{
            try ghostAction(b, c, .git_diff_all, "View diff", .diff),
            try b.fluent().div().grow().children(.{}).build(),
            try b.fluent().adopt(stage_control).id(.{ .string = "git-stage-control" }).build(),
            try v.iconButton(b, c, .git_refresh, "Refresh", .refresh, false),
        }).build();
}

fn changedFiles(self: *const Shell, b: *ui.Ui, height: f32, notices: f32) !ui.Element {
    const c = self.colors;
    var rows: std.ArrayList(ui.Element) = .empty;
    var total: f32 = 0;
    var scroll_y: f32 = 0;
    if (self.git.status) |status| {
        const model_rows = try self.git.tree.rows(b.allocator(), status.entries);
        total = @as(f32, @floatFromInt(model_rows.len)) * row_height;
        const reserved = v.metrics.tabs + 34 + 1 + 30 + 1 + 112 + if (self.git.commits.len > 0) @as(f32, 28) else 0;
        const visible = try ui.controls.visibleRows(model_rows.len, row_height, self.git.sidebar_scroll.offset, @max(1, height - reserved - notices), 0);
        scroll_y = @max(0, -visible.top);
        for (model_rows[visible.start..visible.end]) |row| try rows.append(b.allocator(), try files.renderRow(self, b, status.entries, row));
        if (status.entries.len == 0) try rows.append(b.allocator(), try note(b, c, "Working tree clean"));
    }
    return list(b, rows.items, scroll_y, total);
}

fn branchRow(self: *const Shell, b: *ui.Ui, width: f32) !ui.Element {
    const c = self.colors;
    const branch = if (self.git.status) |status| if (status.branch.len > 0) status.branch else "Detached HEAD" else "Loading…";
    const upstream = git_controls.hasUpstream(self);
    const publish = try splitAction(b, c, if (upstream) .git_push else .git_publish, .git_network_menu, if (upstream) "Push" else "Publish", "Remote actions", .arrow_up, width >= 220, self.git.menu == .network, self.git.updating());

    return b.fluent().div()
        .h(.{ .px = 30 })
        .shrink_0()
        .padding(.{ .left = 12, .right = 8 })
        .gap_px(6)
        .items_center()
        .flex()
        .children(.{
            b.fluent().button(.{
                .label = "Switch branch",
                .on_click = null,
            })
                .flex()
                .gap_px(5)
                .grow()
                .min_w(.{ .px = 0 })
                .items_center()
                .hover_background(null)
                .overflow_hidden()
                .children(&.{
                    try v.icon(b, .branch, c.muted, 14),
                    try b.fluent().button(.{
                        .label = branch,
                    })
                        .flex()
                        .gap_px(0)
                        .grow()
                        .min_w(.{ .px = 0 })
                        .items_center()
                        .hover_background(c.hover)
                        .overflow_hidden()
                        .on_click(b.onClickWith(Shell.onCommand, Command.git_branches))
                        .children(&.{try v.text(b, branch, c.text, 12)})
                        .build(),
                }).build(),
            b.fluent().adopt(publish).id(.{ .string = "git-publish-control" }),
        }).build();
}

fn latestCommit(self: *const Shell, b: *ui.Ui) !ui.Element {
    const c = self.colors;
    const last = self.git.commits[0];
    return b.fluent().button(.{
        .label = last.subject,
    })
        .flex()
        .h(.{ .px = 28 })
        .items_center()
        .gap_px(7)
        .padding(.{ .left = 12, .right = 8 })
        .shrink_0()
        .hover_background(c.hover)
        .overflow_hidden()
        .on_click(b.onClickWith(Shell.onGitCommit, @as(u32, 0)))
        .children(&.{
            try v.icon(b, .commit, c.muted, 14),
            try v.text(b, last.subject, c.muted, 11),
        }).id(.{ .string = "latest-commit" }).build();
}
