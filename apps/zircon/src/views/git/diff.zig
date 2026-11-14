//! Inline repository patches with source numbers, semantic change colors and
//! lexical code runs. Only visible rows become UI nodes, including partial rows.
const std = @import("std");
const zircon_git_ui = @import("zircon_git_ui");
const ui = @import("zircon_ui");
const zircon_widgets = @import("zircon_widgets");
const commands = @import("../../commands.zig");
const git_editing = @import("../../git_editing.zig");
const shell = @import("../../shell.zig");
const v = @import("../components.zig");
const commit_details = @import("commit_details.zig");
const controls = @import("diff_controls.zig");
const Shell = shell.Shell;
const Command = commands.Command;

pub fn render(self: *const Shell, b: *ui.Ui, width: f32) !ui.Element {
    if (self.git.selection_drag != null) try b.requestFrameAfter(1.0 / 60.0);
    const c = self.colors;
    const font = self.editor_options.font_size;
    const line_height = font * self.editor_options.line_height;
    if (self.git.projection) |projection| if (self.git.diff) |diff| {
        const handle = self.window orelse return error.NoWindow;
        const metrics = (try b.frame.app.?.window(handle)).surface.?.measurer();
        const layout_changed = try projection.ensureLayout(diff, &self.git.diff_view, width, font, self.editor_options.tab_width, self.editor_options.soft_wrap != .none, self.editor_options.line_numbers, metrics);
        if (layout_changed) if (self.git.review) |*review| review.reflow(projection, &self.git.diff_view);
    };
    var rows: std.ArrayList(ui.Element) = .empty;
    var tools: std.ArrayList(ui.Element) = .empty;
    if (self.git.projection != null) {
        try tools.appendSlice(b.allocator(), &.{
            try v.iconButton(b, c, .git_collapse_all, "Expand or collapse all files", .chevron_down, false),
            try v.iconButton(b, c, .git_unified_view, "Unified diff", .diff, self.git.diff_view.mode == .unified),
            try v.iconButton(b, c, .git_split_view, "Split diff", .split, self.git.diff_view.mode == .split),
            try v.iconButton(b, c, .git_previous_change, "Previous hunk", .arrow_up, false),
            try v.iconButton(b, c, .git_next_change, "Next hunk", .arrow_down, false),
        });
    }
    if (self.git.selected_commit.len > 0) {
        try tools.appendSlice(b.allocator(), &.{ try v.icon(b, .commit, c.muted, 16), try v.text(b, try std.fmt.allocPrint(b.allocator(), "{s} {s}", .{ if (self.git.stash_view) "Stash" else "Commit", self.git.selected_commit[0..@min(7, self.git.selected_commit.len)] }), c.text, 12) });
    } else if (self.git.selected_path.len > 0 and !self.git.combined) {
        try tools.appendSlice(b.allocator(), &.{ try comparison(b, c, .git_working_diff, "Worktree", !self.git.staged_diff), try comparison(b, c, .git_staged_diff, "Staged", self.git.staged_diff) });
    } else try tools.append(b.allocator(), try b.fluent().adopt(try v.text(b, if (self.git.combined) "All uncommitted changes · HEAD → worktree" else "Uncommitted changes", c.muted, 12))
        .style(.{
            .flex_shrink = 1,
            .min_width = .{ .px = 0 },
            .overflow = .hidden,
            .text = .{ .size = 12, .color = c.muted },
        }).build());
    try tools.append(b.allocator(), try b.fluent().div().grow().min_w(.{ .px = 0 }).children(.{}).build());
    if (self.git.diff) |diff| {
        var added: usize = 0;
        var deleted: usize = 0;
        for (diff.hunks) |hunk| for (hunk.lines) |line| {
            if (line.kind == .addition) added += 1;
            if (line.kind == .deletion) deleted += 1;
        };
        if (b.viewport().width - (if (self.sidebar_visible) self.panelWidth() else 0) >= 560) try tools.appendSlice(b.allocator(), &.{ try v.text(b, try std.fmt.allocPrint(b.allocator(), "+{d}", .{added}), c.added, 12), try v.text(b, try std.fmt.allocPrint(b.allocator(), "−{d}", .{deleted}), c.deleted, 12) });
    }
    const labels = b.viewport().width - self.panelWidth() > 660;
    if (self.git.selected_commit.len == 0) {
        if (self.git.selected_path.len > 0) try tools.appendSlice(b.allocator(), &.{ try action(b, c, .git_stage, "Stage file", "Stage", .plus, labels), try action(b, c, .git_unstage, "Unstage file", "Unstage", .minus, labels), try action(b, c, .git_open_file, "Open file", "Open file", .file, labels) }) else try tools.append(b.allocator(), try action(b, c, .git_stage_all, "Stage all", "Stage all", .plus, true));
    }
    try tools.append(b.allocator(), try v.iconButton(b, c, .back_to_editor, "Editor", .close, false));
    try rows.append(b.allocator(), try b.fluent().div()
        .h(.{ .px = 38 })
        .shrink_0()
        .items_center()
        .gap_px(4)
        .padding(.{ .left = 10, .right = 8 })
        .overflow_hidden()
        .flex()
        .children(tools.items)
        .build());
    if (self.git.selected_commit.len > 0 and !self.git.stash_view) try rows.append(b.allocator(), try commit_details.render(self, b));
    try rows.append(b.allocator(), try v.rule(b, c));
    const Hooks = struct {
        pub const header = controls.header;
        pub const hunkHeader = controls.hunkHeader;
        pub const liveRow = git_editing.renderRow;
        pub const liveBlock = git_editing.renderBlock;
    };
    var diff_lines = if (self.git.diff) |diff| try (zircon_git_ui.content.Content{
        .diff = diff,
        .projection = self.git.projection,
        .state = &self.git.diff_view,
        .scroll = self.git.diff_scroll.offset,
        .font = font,
        .line_height = line_height,
        .tab_width = self.editor_options.tab_width,
        .horizontal = if (self.editor_options.soft_wrap == .none) self.git.editing.horizontal else 0,
        .width = width,
        .line_numbers = self.editor_options.line_numbers,
        .theme = self.editor_options.theme,
        .colors = c,
        .review = if (self.git.review) |*review| review else null,
    }).render(b, self, Hooks) else try message(b, c, "Select a changed file or choose View diff.");
    diff_lines = try b.fluent().adopt(diff_lines).listeners(.{
        .focusable = true,
        .on_input = b.onInput(Shell.onGitScroll),
        .on_capture = b.onInput(capture),
    }).build();
    if (self.git.review) |review| if (review.focused and self.git.editing.active == null) {
        diff_lines = try b.fluent().adopt(diff_lines).request_focus(self.editor_focus_request).build();
    };
    try rows.append(b.allocator(), diff_lines);
    return b.fluent().div()
        .grow()
        .min_w(.{ .px = 0 })
        .background(c.document)
        .overflow_hidden()
        .flex_col()
        .children(rows.items)
        .id(.{ .string = "git-diff" })
        .build();
}

fn action(b: *ui.Ui, c: v.Palette, command: Command, name: []const u8, title: []const u8, icon: v.Icon, label: bool) !ui.Element {
    var children: std.ArrayList(ui.Element) = .empty;
    try children.append(b.allocator(), try v.icon(b, icon, c.muted, 14));
    if (label) try children.append(b.allocator(), try v.text(b, title, c.text, 12));
    var style = v.buttonStyle(c, false);
    style.background = null;
    return b.fluent().button(.{
        .label = name,
    }).style(style).on_click(b.onClickWith(Shell.onCommand, command)).children(children.items).build();
}

fn comparison(b: *ui.Ui, c: v.Palette, command: Command, name: []const u8, selected: bool) !ui.Element {
    var style = v.buttonStyle(c, false);
    style.background = if (selected) c.element else null;
    return b.fluent().button(.{
        .label = name,
    }).style(style).on_click(b.onClickWith(Shell.onCommand, command)).build();
}

fn message(b: *ui.Ui, c: v.Palette, bytes: []const u8) !ui.Element {
    return b.fluent().adopt(try v.text(b, bytes, c.muted, 13)).style(.{
        .padding = ui.Insets.all(16),
        .text = .{ .size = 13, .color = c.muted },
    }).build();
}

fn capture(self: *Shell, event: *ui.Event(ui.Input), cx: *ui.Context(Shell)) !void {
    try controls.input(self, event, cx);
    if (self.window) |handle| if (zircon_widgets.sticky_header.hit(&(try cx.app.window(handle)).frames.committed, event.data, "diff-file:")) return;
    if (!event.stopped) try git_editing.surface(self, event, cx);
}
