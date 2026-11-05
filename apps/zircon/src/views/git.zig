//! Virtualized repository views. Buttons operate on real index/worktree state;
//! no repository command runs during render.
const std = @import("std");
const ui = @import("zircon_ui");
const Shell = @import("../shell.zig").Shell;
const view = @import("../view.zig");
pub fn sidebar(self: *const Shell, b: *ui.Ui, width: f32, height: f32) !ui.Element {
    const c = self.colors;
    var rows: std.ArrayList(ui.Element) = .empty;
    try rows.append(b.allocator(), try b.row(.{ .height = .{ .px = 34 }, .flex_shrink = 0, .gap = 6, .padding = .{ .left = 8, .right = 8, .top = 4 } }, &.{ try view.commandButton(b, c, .git_changes, "Changes", self.left_panel == .git_changes), try view.commandButton(b, c, .git_history, "Log", self.left_panel == .git_history), try view.commandButton(b, c, .project_files, "Files", false), try view.commandButton(b, c, .git_refresh, "↻", false) }));
    if (!self.git.repository) {
        try rows.append(b.allocator(), try label(b, "No Git repository", c.muted, 13));
    } else {
        const branch = if (self.git.status) |status| if (status.branch.len > 0) status.branch else "Detached HEAD" else "Loading…";
        try rows.append(b.allocator(), try label(b, branch, c.text, 13));
        if (self.left_panel == .git_changes) {
            try rows.append(b.allocator(), try b.row(.{ .height = .{ .px = 30 }, .gap = 6 }, &.{ try view.commandButton(b, c, .git_stage_all, "Stage all", false), try view.commandButton(b, c, .git_unstage_all, "Unstage all", false) }));
            if (self.fields) |fields| try rows.append(b.allocator(), try b.key(.{ .string = "commit-message" }, try b.view(fields.commit)));
            try rows.append(b.allocator(), try view.commandButton(b, c, .git_commit, "Commit staged changes", false));
            try rows.append(b.allocator(), try label(b, "Staging uses saved files on disk.", c.muted, 11));
        }
        var entries: std.ArrayList(ui.Element) = .empty;
        if (self.left_panel == .git_history) {
            const visible = try ui.controls.visibleRows(self.git.commits.len, 54, self.git.sidebar_scroll.offset, @max(1, height - 90), 0);
            for (self.git.commits[visible.start..visible.end], visible.start..) |commit, index| {
                const title = commit.subject;
                const detail = try std.fmt.allocPrint(b.allocator(), "{s} · {s}", .{ commit.oid[0..@min(7, commit.oid.len)], commit.author });
                try entries.append(b.allocator(), try b.key(.{ .number = @intCast(index) }, try b.button(.{ .label = title, .children = &.{ try label(b, title, c.text, 12), try label(b, detail, c.muted, 11) }, .on_click = try b.onClickWith(@as(u32, @intCast(index)), Shell.onGitCommit), .style = .{ .height = .{ .px = 54 }, .gap = 5, .flex_shrink = 0, .padding = .{ .left = 10, .top = 8, .right = 6 }, .background = if (std.mem.eql(u8, self.git.selected_commit, commit.oid)) c.selected else c.sidebar, .text = .{ .size = 12, .color = c.text }, .overflow = .hidden } })));
            }
        } else if (self.git.status) |status| {
            const visible = try ui.controls.visibleRows(status.entries.len, 54, self.git.sidebar_scroll.offset, @max(1, height - 230), 0);
            for (status.entries[visible.start..visible.end], visible.start..) |entry, index| {
                const title = entry.path;
                const detail = try std.fmt.allocPrint(b.allocator(), "{s}{s}{s}", .{ if (entry.staged) "Staged " else "", if (entry.unstaged) "Worktree " else "", if (entry.conflicted) "Conflict" else "" });
                try entries.append(b.allocator(), try b.key(.{ .number = @intCast(index) }, try b.button(.{ .label = title, .children = &.{ try label(b, title, c.text, 12), try label(b, detail, if (entry.conflicted) c.warning else c.muted, 11) }, .on_click = try b.onClickWith(@as(u32, @intCast(index)), Shell.onGitFile), .style = .{ .height = .{ .px = 54 }, .gap = 5, .flex_shrink = 0, .padding = .{ .left = 10, .top = 8, .right = 6 }, .background = if (std.mem.eql(u8, self.git.selected_path, entry.path)) c.selected else c.sidebar, .text = .{ .size = 12, .color = if (entry.conflicted) c.warning else c.text }, .overflow = .hidden } })));
            }
            if (status.entries.len == 0) try entries.append(b.allocator(), try label(b, "Working tree clean", c.muted, 12));
        }
        try rows.append(b.allocator(), try b.listen(try b.key(.{ .string = "git-list" }, try b.column(.{ .flex_grow = 1, .min_height = .{ .px = 0 }, .overflow = .hidden }, entries.items)), .{ .on_input = try b.onInputWith(@as(u8, 0), Shell.onGitScroll) }));
    }
    if (self.git.busy) try rows.append(b.allocator(), try label(b, "Updating repository…", c.muted, 11));
    if (self.git.error_text.len > 0) try rows.append(b.allocator(), try label(b, self.git.error_text, c.warning, 11));
    return b.key(.{ .string = "git-sidebar" }, try b.column(.{ .width = .{ .px = width }, .flex_shrink = 0, .gap = 8, .padding = .{ .left = 8, .right = 8, .bottom = 8 }, .background = c.sidebar, .overflow = .hidden }, rows.items));
}
pub fn diffPane(self: *const Shell, b: *ui.Ui) !ui.Element {
    const c = self.colors;
    var rows: std.ArrayList(ui.Element) = .empty;
    const heading = if (self.git.selected_commit.len > 0) self.git.selected_commit else if (self.git.selected_path.len > 0) self.git.selected_path else "Repository diff";
    try rows.append(b.allocator(), try b.row(.{ .height = .{ .px = 38 }, .flex_shrink = 0, .gap = 8, .align_items = .center, .padding = .{ .left = 12, .right = 12 }, .background = c.chrome }, &.{ try view.commandButton(b, c, .back_to_editor, "Editor", false), try label(b, heading, c.text, 12) }));
    if (self.git.selected_path.len > 0 and self.git.selected_commit.len == 0) try rows.append(b.allocator(), try b.row(.{ .height = .{ .px = 36 }, .flex_shrink = 0, .gap = 8, .padding = .{ .left = 12 } }, &.{ try view.commandButton(b, c, .git_working_diff, "Worktree", false), try view.commandButton(b, c, .git_staged_diff, "Staged", false), try view.commandButton(b, c, .git_stage, "Stage file", false), try view.commandButton(b, c, .git_unstage, "Unstage file", false), try view.commandButton(b, c, .git_open_file, "Open file", false) }));
    var lines: std.ArrayList(ui.Element) = .empty;
    if (self.git.diff) |diff| {
        var iterator = std.mem.splitScalar(u8, diff.text, '\n');
        var number: usize = 0;
        const first: usize = @intFromFloat(@floor(self.git.diff_scroll.offset / 22));
        const end = first + @as(usize, @intFromFloat(@max(1, b.viewport().height / 22))) + 1;
        while (iterator.next()) |line| : (number += 1) {
            if (number < first) continue;
            if (number >= end) break;
            const added = std.mem.startsWith(u8, line, "+");
            const removed = std.mem.startsWith(u8, line, "-");
            const color = if (added) ui.Color.rgb(0xa4cc9b) else if (removed) ui.Color.rgb(0xe59898) else if (std.mem.startsWith(u8, line, "@@")) c.accent else c.text;
            try lines.append(b.allocator(), try b.key(.{ .number = @intCast(number) }, try b.styled(try b.text(line), .{ .height = .{ .px = 22 }, .flex_shrink = 0, .padding = .{ .left = 16 }, .background = if (added) ui.Color.rgb(0x2b3d30) else if (removed) ui.Color.rgb(0x452e33) else c.document, .text = .{ .size = 13, .mono = true, .color = color }, .overflow = .hidden })));
        }
        if (diff.text.len == 0) try lines.append(b.allocator(), try label(b, "No changes in this comparison.", c.muted, 13));
    } else try lines.append(b.allocator(), try label(b, "Select a changed file or commit.", c.muted, 13));
    try rows.append(b.allocator(), try b.listen(try b.key(.{ .string = "git-diff-lines" }, try b.column(.{ .flex_grow = 1, .min_height = .{ .px = 0 }, .overflow = .hidden }, lines.items)), .{ .on_input = try b.onInputWith(@as(u8, 1), Shell.onGitScroll) }));
    return b.key(.{ .string = "git-diff" }, try b.column(.{ .flex_grow = 1, .min_width = .{ .px = 0 }, .background = c.document, .overflow = .hidden }, rows.items));
}
fn label(b: *ui.Ui, bytes: []const u8, color: ui.Color, size: f32) !ui.Element {
    return b.styled(try b.text(bytes), .{ .text = .{ .size = size, .color = color }, .overflow = .hidden });
}
