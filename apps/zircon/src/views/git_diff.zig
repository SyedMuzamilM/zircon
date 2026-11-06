//! Inline repository patches with source numbers, semantic change colors and
//! lexical code runs. Only visible rows become UI nodes, including partial rows.
const std = @import("std");
const ui = @import("zircon_ui");
const git = @import("zircon_git");
const Shell = @import("../shell.zig").Shell;
const Command = @import("../commands.zig").Command;
const v = @import("components.zig");
const file_height: f32 = 38;
const context_height: f32 = 26;

pub fn contentHeight(diff: git.Diff, line_height: f32) f32 {
    if (diff.hunks.len == 0) return @as(f32, @floatFromInt(std.mem.count(u8, diff.text, "\n") + 1)) * line_height;
    var total: f32 = 0;
    var previous: []const u8 = "";
    for (diff.hunks) |hunk| {
        if (!std.mem.eql(u8, previous, hunk.path)) total += file_height;
        total += context_height + @as(f32, @floatFromInt(hunk.lines.len)) * line_height;
        previous = hunk.path;
    }
    return total;
}
pub fn render(self: *const Shell, b: *ui.Ui) !ui.Element {
    const c = self.colors;
    const font = self.editor_options.font_size;
    const line_height = font * self.editor_options.line_height;
    var rows: std.ArrayList(ui.Element) = .empty;
    var tools: std.ArrayList(ui.Element) = .empty;
    if (self.git.selected_commit.len > 0) {
        try tools.appendSlice(b.allocator(), &.{ try v.icon(b, .commit, c.muted, 16), try v.text(b, try std.fmt.allocPrint(b.allocator(), "{s} {s}", .{ if (self.git.stash_view) "Stash" else "Commit", self.git.selected_commit[0..@min(7, self.git.selected_commit.len)] }), c.text, 12) });
    } else if (self.git.selected_path.len > 0 and !self.git.combined) {
        try tools.appendSlice(b.allocator(), &.{ try comparison(b, c, .git_working_diff, "Worktree", !self.git.staged_diff), try comparison(b, c, .git_staged_diff, "Staged", self.git.staged_diff) });
    } else try tools.append(b.allocator(), try b.styled(try v.text(b, if (self.git.combined) "All uncommitted changes · HEAD → worktree" else "Uncommitted changes", c.muted, 12), .{ .flex_shrink = 1, .min_width = .{ .px = 0 }, .overflow = .hidden, .text = .{ .size = 12, .color = c.muted } }));
    try tools.append(b.allocator(), try b.div(.{ .flex_grow = 1, .min_width = .{ .px = 0 } }, &.{}));
    if (self.git.diff) |diff| {
        var added: usize = 0;
        var deleted: usize = 0;
        for (diff.hunks) |hunk| for (hunk.lines) |line| {
            if (line.kind == .addition) added += 1;
            if (line.kind == .deletion) deleted += 1;
        };
        if (b.viewport().width > 950) try tools.appendSlice(b.allocator(), &.{ try v.text(b, try std.fmt.allocPrint(b.allocator(), "+{d}", .{added}), c.added, 12), try v.text(b, try std.fmt.allocPrint(b.allocator(), "−{d}", .{deleted}), c.deleted, 12) });
    }
    const labels = b.viewport().width - self.panelWidth() > 660;
    if (self.git.selected_commit.len == 0) {
        if (self.git.selected_path.len > 0) try tools.appendSlice(b.allocator(), &.{ try action(b, c, .git_stage, "Stage file", "Stage", .plus, labels), try action(b, c, .git_unstage, "Unstage file", "Unstage", .minus, labels), try action(b, c, .git_open_file, "Open file", "Open file", .file, labels) }) else try tools.append(b.allocator(), try action(b, c, .git_stage_all, "Stage all", "Stage all", .plus, true));
    }
    try tools.append(b.allocator(), try v.iconButton(b, c, .back_to_editor, "Editor", .close, false));
    try rows.append(b.allocator(), try b.row(.{ .height = .{ .px = 38 }, .flex_shrink = 0, .align_items = .center, .gap = 4, .padding = .{ .left = 10, .right = 8 }, .overflow = .hidden }, tools.items));
    try rows.append(b.allocator(), try v.rule(b, c));
    var lines: std.ArrayList(ui.Element) = .empty;
    const top = self.git.diff_scroll.offset;
    const bottom = top + b.viewport().height;
    var position: f32 = 0;
    var first: ?f32 = null;
    if (self.git.diff) |diff| {
        var previous: []const u8 = "";
        for (diff.hunks) |hunk| {
            if (position >= bottom) break;
            if (!std.mem.eql(u8, previous, hunk.path)) {
                if (visible(position, file_height, top, bottom)) {
                    if (first == null) first = position;
                    try lines.append(b.allocator(), try fileHeader(b, c, hunk.path));
                }
                position += file_height;
            }
            previous = hunk.path;
            if (visible(position, context_height, top, bottom)) {
                if (first == null) first = position;
                try lines.append(b.allocator(), try b.row(.{ .height = .{ .px = context_height }, .align_items = .center, .padding = .{ .left = 60 }, .flex_shrink = 0, .background = c.sidebar }, &.{try v.text(b, hunk.header, c.muted, 11)}));
            }
            position += context_height;
            for (hunk.lines) |line| {
                if (position >= bottom) break;
                if (visible(position, line_height, top, bottom)) {
                    if (first == null) first = position;
                    try lines.append(b.allocator(), try codeRow(self, b, line, hunk.path));
                }
                position += line_height;
            }
        }
        if (diff.hunks.len == 0) {
            var iterator = std.mem.splitScalar(u8, diff.text, '\n');
            while (iterator.next()) |line| : (position += line_height) {
                if (position >= bottom) break;
                if (visible(position, line_height, top, bottom)) {
                    if (first == null) first = position;
                    try lines.append(b.allocator(), try codeRow(self, b, .{ .kind = .metadata, .text = line }, ""));
                }
            }
        }
        if (diff.text.len == 0) try lines.append(b.allocator(), try message(b, c, "No changes in this comparison."));
    } else try lines.append(b.allocator(), try message(b, c, "Select a changed file or choose View diff."));
    try rows.append(b.allocator(), try b.listen(try b.key(.{ .string = "git-diff-lines" }, try b.column(.{ .flex_grow = 1, .min_height = .{ .px = 0 }, .scroll_y = if (first) |origin| @max(0, top - origin) else 0, .overflow = .hidden }, lines.items)), .{ .on_input = b.onInput(Shell.onGitScroll) }));
    return b.key(.{ .string = "git-diff" }, try b.column(.{ .flex_grow = 1, .min_width = .{ .px = 0 }, .background = c.document, .overflow = .hidden }, rows.items));
}
fn visible(y: f32, height: f32, top: f32, bottom: f32) bool {
    return y + height > top and y < bottom;
}
fn action(b: *ui.Ui, c: v.Palette, command: Command, name: []const u8, title: []const u8, icon: v.Icon, label: bool) !ui.Element {
    var children: std.ArrayList(ui.Element) = .empty;
    try children.append(b.allocator(), try v.icon(b, icon, c.muted, 14));
    if (label) try children.append(b.allocator(), try v.text(b, title, c.text, 12));
    var style = v.buttonStyle(c, false);
    style.background = null;
    return b.button(.{ .label = name, .children = children.items, .on_click = try b.onClickWith(command, Shell.onCommand), .style = style });
}
fn comparison(b: *ui.Ui, c: v.Palette, command: Command, name: []const u8, selected: bool) !ui.Element {
    var style = v.buttonStyle(c, false);
    style.background = if (selected) c.element else null;
    return b.button(.{ .label = name, .on_click = try b.onClickWith(command, Shell.onCommand), .style = style });
}
fn fileHeader(b: *ui.Ui, c: v.Palette, path: []const u8) !ui.Element {
    const name = std.fs.path.basename(path);
    const parent = std.fs.path.dirname(path) orelse "";
    return b.row(.{ .height = .{ .px = file_height }, .flex_shrink = 0, .align_items = .center, .gap = 8, .padding = .{ .left = 14, .right = 12 }, .background = c.sidebar, .overflow = .hidden }, &.{ try v.icon(b, v.fileIcon(path), v.fileColor(c, path), 16), try v.text(b, name, c.text, 13), try b.styled(try v.text(b, parent, c.muted, 12), .{ .flex_shrink = 1, .min_width = .{ .px = 0 }, .text = .{ .size = 12, .color = c.muted }, .overflow = .hidden }) });
}
fn message(b: *ui.Ui, c: v.Palette, bytes: []const u8) !ui.Element {
    return b.styled(try v.text(b, bytes, c.muted, 13), .{ .padding = ui.Insets.all(16), .text = .{ .size = 13, .color = c.muted } });
}
fn codeRow(self: *const Shell, b: *ui.Ui, line: git.Line, path: []const u8) !ui.Element {
    const c = self.colors;
    const changed = line.kind == .addition or line.kind == .deletion;
    const tint = if (line.kind == .addition) c.added else if (line.kind == .deletion) c.deleted else self.editor_options.theme.line_number;
    var fill = tint;
    fill.a = 0.14;
    const number = if (line.new_line orelse line.old_line) |n| try std.fmt.allocPrint(b.allocator(), "{d}", .{n}) else "";
    const code = try @import("code_line.zig").element(b, line.text, path, self.editor_options.font_size, self.editor_options.font_size * self.editor_options.line_height, self.editor_options.theme, &.{});
    return b.row(.{ .height = .{ .px = self.editor_options.font_size * self.editor_options.line_height }, .flex_shrink = 0, .align_items = .stretch, .gap = 8, .background = if (changed) fill else null, .overflow = .hidden }, &.{ try b.div(.{ .width = .{ .px = 3 }, .background = if (changed) tint else null, .flex_shrink = 0 }, &.{}), try b.column(.{ .width = .{ .px = 38 }, .flex_shrink = 0, .justify_content = .center, .align_items = .end }, &.{try b.styled(try v.text(b, number, tint, 12), .{ .text = .{ .size = 12, .mono = true, .color = tint } })}), try b.div(.{ .width = .{ .px = 1 }, .flex_shrink = 0, .background = c.border_subtle }, &.{}), code });
}
