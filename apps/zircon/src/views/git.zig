//! Repository chrome and viewport-bounded numbered hunks. Mutations run in the
//! Git service; rendering only reads its last installed repository snapshot.
const std = @import("std");
const ui = @import("zircon_ui");
const git = @import("zircon_git");
const Shell = @import("../shell.zig").Shell;
const Command = @import("../commands.zig").Command;
const v = @import("components.zig");
pub const change_row_height: f32 = 30;
pub const history_row_height: f32 = 54;
pub const diff_row_height: f32 = 22;

fn action(b: *ui.Ui, c: v.Palette, command: Command, name: []const u8) !ui.Element {
    return b.button(.{ .label = name, .on_click = try b.onClickWith(command, Shell.onCommand), .style = .{ .height = .{ .px = 26 }, .flex_shrink = 0, .padding = .{ .left = 8, .right = 8, .top = 5 }, .radius = 3, .hover_background = c.hover, .text = .{ .size = 12, .color = c.text } } });
}
pub fn sidebar(self: *const Shell, b: *ui.Ui, width: f32, height: f32) !ui.Element {
    const c = self.colors;
    const history = self.left_panel == .git_history;
    var rows: std.ArrayList(ui.Element) = .empty;
    try rows.append(b.allocator(), try b.row(.{ .height = .{ .px = 32 }, .flex_shrink = 0, .align_items = .center, .padding = .{ .left = 12, .right = 6 }, .gap = 2 }, &.{ try v.text(b, if (history) "Git history" else "Git", c.text, 13), try b.div(.{ .flex_grow = 1 }, &.{}), try v.iconButton(b, c, if (history) .git_changes else .git_history, if (history) "Changes" else "Log", if (history) .branch else .history, false), try v.iconButton(b, c, .git_refresh, "Refresh", .refresh, false) }));
    try rows.append(b.allocator(), try v.rule(b, c));
    if (!self.git.repository) {
        try rows.append(b.allocator(), try paddedLabel(b, "No Git repository", c.muted));
    } else {
        const branch = if (self.git.status) |status| if (status.branch.len > 0) status.branch else "Detached HEAD" else "Loading…";
        try rows.append(b.allocator(), try b.row(.{ .height = .{ .px = 38 }, .flex_shrink = 0, .align_items = .center, .padding = .{ .left = 12 }, .gap = 8 }, &.{ try v.icon(b, .branch, c.muted, 15), try v.text(b, branch, c.text, 13) }));
        if (!history) try rows.append(b.allocator(), try b.row(.{ .height = .{ .px = 30 }, .flex_shrink = 0, .align_items = .center, .padding = .{ .left = 12, .right = 4 } }, &.{ try v.text(b, "Changes", c.muted, 12), try b.div(.{ .flex_grow = 1 }, &.{}), try v.iconButton(b, c, .git_stage_all, "Stage all", .plus, false), try v.iconButton(b, c, .git_unstage_all, "Unstage all", .close, false) }));
        var entries: std.ArrayList(ui.Element) = .empty;
        const list_height = @max(1, height - if (history) @as(f32, 72) else @as(f32, 228));
        if (history) {
            const visible = try ui.controls.visibleRows(self.git.commits.len, history_row_height, self.git.sidebar_scroll.offset, list_height, 0);
            for (self.git.commits[visible.start..visible.end], visible.start..) |commit, index| {
                const detail = try std.fmt.allocPrint(b.allocator(), "{s}  {s}", .{ commit.oid[0..@min(7, commit.oid.len)], commit.author });
                try entries.append(b.allocator(), try b.key(.{ .number = @intCast(index) }, try b.button(.{ .label = commit.subject, .children = &.{ try v.text(b, commit.subject, c.text, 12), try v.text(b, detail, c.muted, 11) }, .on_click = try b.onClickWith(@as(u32, @intCast(index)), Shell.onGitCommit), .style = .{ .height = .{ .px = history_row_height }, .gap = 5, .flex_shrink = 0, .padding = .{ .left = 12, .top = 9, .right = 8 }, .background = if (std.mem.eql(u8, self.git.selected_commit, commit.oid)) c.selected else null, .hover_background = c.hover, .overflow = .hidden } })));
            }
        } else if (self.git.status) |status| {
            const visible = try ui.controls.visibleRows(status.entries.len, change_row_height, self.git.sidebar_scroll.offset, list_height, 0);
            for (status.entries[visible.start..visible.end], visible.start..) |entry, index| {
                const change = if (entry.conflicted) git.Change.unmerged else if (entry.unstaged) entry.worktree else entry.index;
                const tint = changeColor(c, change);
                try entries.append(b.allocator(), try b.key(.{ .number = @intCast(index) }, try b.button(.{ .label = entry.path, .children = &.{ try v.icon(b, v.fileIcon(entry.path), v.fileColor(c, entry.path), 15), try b.styled(try v.text(b, entry.path, c.text, 12), .{ .flex_grow = 1, .min_width = .{ .px = 0 }, .text = .{ .size = 12, .color = c.text }, .overflow = .hidden }), try v.text(b, changeMark(change), tint, 11), try v.icon(b, if (entry.staged) .check else .plus, if (entry.staged) c.accent else c.muted, 13) }, .on_click = try b.onClickWith(@as(u32, @intCast(index)), Shell.onGitFile), .style = .{ .direction = .row, .height = .{ .px = change_row_height }, .gap = 8, .align_items = .center, .flex_shrink = 0, .padding = .{ .left = 12, .right = 12 }, .background = if (std.mem.eql(u8, self.git.selected_path, entry.path)) c.selected else null, .hover_background = c.hover, .overflow = .hidden } })));
            }
            if (status.entries.len == 0) try entries.append(b.allocator(), try paddedLabel(b, "Working tree clean", c.muted));
        }
        const row_height = if (history) history_row_height else change_row_height;
        const list = try b.column(.{ .flex_grow = 1, .min_height = .{ .px = 0 }, .scroll_y = @mod(self.git.sidebar_scroll.offset, row_height), .overflow = .hidden }, entries.items);
        try rows.append(b.allocator(), try b.listen(try b.key(.{ .string = "git-list" }, list), .{ .on_input = try b.onInputWith(@as(u8, 0), Shell.onGitScroll) }));
        if (!history) {
            try rows.append(b.allocator(), try v.rule(b, c));
            var commit: std.ArrayList(ui.Element) = .empty;
            if (self.fields) |fields| try commit.append(b.allocator(), try b.key(.{ .string = "commit-message" }, try b.styled(try b.view(fields.commit), .{ .height = .{ .px = 44 }, .flex_shrink = 0 })));
            try commit.append(b.allocator(), try b.button(.{ .label = "Commit staged changes", .on_click = try b.onClickWith(Command.git_commit, Shell.onCommand), .style = .{ .height = .{ .px = 28 }, .padding = .{ .top = 6, .left = 10 }, .radius = 3, .background = c.selected, .hover_background = c.hover, .text = .{ .size = 12, .color = c.text }, .flex_shrink = 0 } }));
            try commit.append(b.allocator(), try v.text(b, "Staging uses saved files on disk.", c.muted, 10));
            try rows.append(b.allocator(), try b.column(.{ .height = .{ .px = 120 }, .flex_shrink = 0, .padding = ui.Insets.all(10), .gap = 8 }, commit.items));
        }
    }
    if (self.git.busy) try rows.append(b.allocator(), try paddedLabel(b, "Updating repository…", c.muted));
    if (self.git.error_text.len > 0) try rows.append(b.allocator(), try paddedLabel(b, self.git.error_text, c.warning));
    return b.key(.{ .string = "git-sidebar" }, try b.column(.{ .width = .{ .px = width }, .flex_shrink = 0, .background = c.sidebar, .overflow = .hidden }, rows.items));
}
fn paddedLabel(b: *ui.Ui, bytes: []const u8, color: ui.Color) !ui.Element {
    return b.styled(try v.text(b, bytes, color, 12), .{ .padding = ui.Insets.all(12), .flex_shrink = 0, .text = .{ .size = 12, .color = color }, .overflow = .hidden });
}
fn changeMark(change: git.Change) []const u8 {
    return switch (change) {
        .clean => "",
        .added => "A",
        .modified => "M",
        .deleted => "D",
        .renamed => "R",
        .copied => "C",
        .unmerged => "!",
        .untracked => "?",
        .ignored => "I",
        .type_changed => "T",
        .unknown => "?",
    };
}
fn changeColor(c: v.Palette, change: git.Change) ui.Color {
    return switch (change) {
        .added, .untracked => ui.Color.rgb(0x8cbf88),
        .deleted, .unmerged => ui.Color.rgb(0xe58b8b),
        .modified, .type_changed => c.warning,
        else => c.muted,
    };
}
/// Includes file boundaries so history patches never mislabel a later file.
pub fn diffRowCount(diff: git.Diff) usize {
    if (diff.hunks.len == 0) return std.mem.count(u8, diff.text, "\n") + 1;
    var count: usize = 0;
    var previous: []const u8 = "";
    for (diff.hunks) |hunk| {
        if (!std.mem.eql(u8, previous, hunk.path)) count += 1;
        previous = hunk.path;
        count += 1 + hunk.lines.len;
    }
    return count;
}
pub fn diffPane(self: *const Shell, b: *ui.Ui) !ui.Element {
    const c = self.colors;
    var rows: std.ArrayList(ui.Element) = .empty;
    const heading = if (self.git.selected_commit.len > 0) try std.fmt.allocPrint(b.allocator(), "Commit {s}", .{self.git.selected_commit[0..@min(7, self.git.selected_commit.len)]}) else if (self.git.selected_path.len > 0) self.git.selected_path else "Uncommitted changes";
    try rows.append(b.allocator(), try b.row(.{ .height = .{ .px = 34 }, .flex_shrink = 0, .gap = 8, .align_items = .center, .padding = .{ .left = 10, .right = 10 } }, &.{ try v.iconButton(b, c, .back_to_editor, "Editor", .chevron_left, false), try v.text(b, heading, c.text, 12) }));
    if (self.git.selected_path.len > 0 and self.git.selected_commit.len == 0) try rows.append(b.allocator(), try b.row(.{ .height = .{ .px = 34 }, .flex_shrink = 0, .gap = 3, .padding = .{ .left = 10, .right = 10 }, .align_items = .center }, &.{ try action(b, c, .git_working_diff, "Worktree"), try action(b, c, .git_staged_diff, "Staged"), try b.div(.{ .flex_grow = 1 }, &.{}), try action(b, c, .git_stage, "Stage file"), try action(b, c, .git_unstage, "Unstage file"), try action(b, c, .git_open_file, "Open file") }));
    try rows.append(b.allocator(), try v.rule(b, c));
    var lines: std.ArrayList(ui.Element) = .empty;
    if (self.git.diff) |diff| {
        const first: usize = @intFromFloat(@floor(self.git.diff_scroll.offset / diff_row_height));
        const end = first + @as(usize, @intFromFloat(@max(1, b.viewport().height / diff_row_height))) + 1;
        var number: usize = 0;
        var previous: []const u8 = "";
        for (diff.hunks) |hunk| {
            if (number >= end) break;
            if (!std.mem.eql(u8, previous, hunk.path)) {
                if (number >= first and number < end) try lines.append(b.allocator(), try diffHeader(b, c, hunk.path));
                number += 1;
            }
            previous = hunk.path;
            if (number >= first and number < end) try lines.append(b.allocator(), try diffHeader(b, c, hunk.header));
            number += 1;
            for (hunk.lines) |line| {
                if (number >= end) break;
                if (number >= first) try lines.append(b.allocator(), try numberedLine(b, c, line));
                number += 1;
            }
        }
        // Binary, mode-only and rename-only patches still show their metadata.
        if (diff.hunks.len == 0) {
            var iterator = std.mem.splitScalar(u8, diff.text, '\n');
            while (iterator.next()) |line| : (number += 1) {
                if (number >= end) break;
                if (number >= first) try lines.append(b.allocator(), try diffHeader(b, c, line));
            }
        }
        if (diff.text.len == 0) try lines.append(b.allocator(), try paddedLabel(b, "No changes in this comparison.", c.muted));
    } else try lines.append(b.allocator(), try paddedLabel(b, "Select a changed file or commit.", c.muted));
    try rows.append(b.allocator(), try b.listen(try b.key(.{ .string = "git-diff-lines" }, try b.column(.{ .flex_grow = 1, .min_height = .{ .px = 0 }, .scroll_y = @mod(self.git.diff_scroll.offset, diff_row_height), .overflow = .hidden }, lines.items)), .{ .on_input = try b.onInputWith(@as(u8, 1), Shell.onGitScroll) }));
    return b.key(.{ .string = "git-diff" }, try b.column(.{ .flex_grow = 1, .min_width = .{ .px = 0 }, .background = c.document, .overflow = .hidden }, rows.items));
}
fn diffHeader(b: *ui.Ui, c: v.Palette, bytes: []const u8) !ui.Element {
    return b.styled(try v.text(b, bytes, c.muted, 12), .{ .height = .{ .px = diff_row_height }, .flex_shrink = 0, .padding = .{ .left = 16, .top = 3 }, .background = c.sidebar, .text = .{ .size = 12, .mono = true, .color = c.muted }, .overflow = .hidden });
}
fn numberedLine(b: *ui.Ui, c: v.Palette, line: git.Line) !ui.Element {
    const added = line.kind == .addition;
    const removed = line.kind == .deletion;
    const tint = if (added) ui.Color.rgb(0x8cbf88) else if (removed) ui.Color.rgb(0xe58b8b) else c.text;
    var background = if (added) ui.Color.rgb(0x4b9b63) else ui.Color.rgb(0xc45b63);
    background.a = 0.13;
    const old = if (line.old_line) |n| try std.fmt.allocPrint(b.allocator(), "{d}", .{n}) else "";
    const new = if (line.new_line) |n| try std.fmt.allocPrint(b.allocator(), "{d}", .{n}) else "";
    return b.row(.{ .height = .{ .px = diff_row_height }, .flex_shrink = 0, .align_items = .center, .background = if (added or removed) background else null, .overflow = .hidden, .gap = 8, .padding = .{ .left = 12 } }, &.{ try lineNumber(b, c, old), try lineNumber(b, c, new), try b.styled(try v.text(b, if (added) "+" else if (removed) "−" else " ", tint, 13), .{ .width = .{ .px = 12 }, .text = .{ .size = 13, .mono = true, .color = tint } }), try b.styled(try v.text(b, line.text, c.text, 13), .{ .flex_grow = 1, .min_width = .{ .px = 0 }, .text = .{ .size = 13, .mono = true, .color = c.text }, .overflow = .hidden }) });
}
fn lineNumber(b: *ui.Ui, c: v.Palette, bytes: []const u8) !ui.Element {
    return b.styled(try v.text(b, bytes, c.muted, 11), .{ .width = .{ .px = 38 }, .flex_shrink = 0, .text = .{ .size = 11, .mono = true, .color = c.muted }, .overflow = .hidden });
}
