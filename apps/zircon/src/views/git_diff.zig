//! Inline repository patches with source numbers, semantic change colors and
//! lexical code runs. Only visible rows become UI nodes, including partial rows.
const std = @import("std");
const ui = @import("zircon_ui");
const git = @import("zircon_git");
const Shell = @import("../shell.zig").Shell;
const Command = @import("../commands.zig").Command;
const v = @import("components.zig");
const controls = @import("git_diff_controls.zig");
const file_height = @import("../models/diff_layout.zig").file_height;
const context_height = @import("../models/diff_layout.zig").context_height;

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
pub fn fileOffset(diff: git.Diff, path: []const u8, line_height: f32) ?f32 {
    var position: f32 = 0;
    var previous: []const u8 = "";
    for (diff.hunks) |hunk| {
        if (!std.mem.eql(u8, previous, hunk.path)) {
            if (std.mem.eql(u8, path, hunk.path)) return position;
            position += file_height;
        }
        position += context_height + @as(f32, @floatFromInt(hunk.lines.len)) * line_height;
        previous = hunk.path;
    }
    return null;
}
pub fn render(self: *const Shell, b: *ui.Ui) !ui.Element {
    const c = self.colors;
    const font = self.editor_options.font_size;
    const line_height = font * self.editor_options.line_height;
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
    } else try tools.append(b.allocator(), try b.styled(try v.text(b, if (self.git.combined) "All uncommitted changes · HEAD → worktree" else "Uncommitted changes", c.muted, 12), .{ .flex_shrink = 1, .min_width = .{ .px = 0 }, .overflow = .hidden, .text = .{ .size = 12, .color = c.muted } }));
    try tools.append(b.allocator(), try b.div(.{ .flex_grow = 1, .min_width = .{ .px = 0 } }, &.{}));
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
    try rows.append(b.allocator(), try b.row(.{ .height = .{ .px = 38 }, .flex_shrink = 0, .align_items = .center, .gap = 4, .padding = .{ .left = 10, .right = 8 }, .overflow = .hidden }, tools.items));
    if (self.git.selected_commit.len > 0 and !self.git.stash_view) try rows.append(b.allocator(), try @import("commit_details.zig").render(self, b));
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
                    const file_index = if (self.git.projection) |projection| blk: {
                        var index: usize = 0;
                        for (projection.files, 0..) |file, i| if (std.mem.eql(u8, file.path, hunk.path)) {
                            index = i;
                            break;
                        };
                        break :blk index;
                    } else 0;
                    if (self.git.projection) |projection| try lines.append(b.allocator(), try controls.header(self, b, projection.files[file_index], file_index)) else try lines.append(b.allocator(), try fileHeader(self, b, c, hunk.path));
                }
                position += file_height;
            }
            previous = hunk.path;
            const collapsed = if (self.git.projection) |projection| blk: {
                var value = false;
                for (projection.files) |file| {
                    if (std.mem.eql(u8, file.path, hunk.path)) value = self.git.diff_view.collapsed.contains(file.path);
                }
                break :blk value;
            } else false;
            if (!collapsed and visible(position, context_height, top, bottom)) {
                if (first == null) first = position;
                try lines.append(b.allocator(), try b.row(.{ .height = .{ .px = context_height }, .align_items = .center, .padding = .{ .left = 60 }, .flex_shrink = 0, .background = c.sidebar }, &.{try v.text(b, hunk.header, c.muted, 11)}));
            }
            position += context_height;
            for (hunk.lines, 0..) |line, index| {
                if (collapsed) break;
                if (position >= bottom) break;
                if (visible(position, line_height, top, bottom)) {
                    if (first == null) first = position;
                    try lines.append(b.allocator(), try codeRow(self, b, line, hunk.path, pairedLine(hunk.lines, index)));
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
                    try lines.append(b.allocator(), try codeRow(self, b, .{ .kind = .metadata, .text = line }, "", null));
                }
            }
        }
        if (diff.text.len == 0) try lines.append(b.allocator(), try message(b, c, "No changes in this comparison."));
    } else try lines.append(b.allocator(), try message(b, c, "Select a changed file or choose View diff."));
    var diff_lines = try b.listen(try b.key(.{ .string = "git-diff-lines" }, try b.column(.{ .flex_grow = 1, .min_height = .{ .px = 0 }, .scroll_y = if (first) |origin| @max(0, top - origin) else 0, .overflow = .hidden }, lines.items)), .{ .on_input = b.onInput(Shell.onGitScroll) });
    if (self.git.projection != null) diff_lines = try b.listen(diff_lines, .{ .on_capture = b.onInput(controls.input) });
    try rows.append(b.allocator(), diff_lines);
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
    return b.button(.{ .label = name, .children = children.items, .on_click = b.onClickWith(Shell.onCommand, command), .style = style });
}
fn comparison(b: *ui.Ui, c: v.Palette, command: Command, name: []const u8, selected: bool) !ui.Element {
    var style = v.buttonStyle(c, false);
    style.background = if (selected) c.element else null;
    return b.button(.{ .label = name, .on_click = b.onClickWith(Shell.onCommand, command), .style = style });
}
fn fileHeader(self: *const Shell, b: *ui.Ui, c: v.Palette, path: []const u8) !ui.Element {
    const name = std.fs.path.basename(path);
    const parent = std.fs.path.dirname(path) orelse "";
    return b.row(.{ .height = .{ .px = file_height }, .flex_shrink = 0, .align_items = .center, .gap = 8, .padding = .{ .left = 14, .right = 12 }, .background = c.sidebar, .overflow = .hidden }, &.{ try v.fileGlyph(self, b, path, false, false, 16), try v.text(b, name, c.text, 13), try b.styled(try v.text(b, parent, c.muted, 12), .{ .flex_shrink = 1, .min_width = .{ .px = 0 }, .text = .{ .size = 12, .color = c.muted }, .overflow = .hidden }) });
}
fn message(b: *ui.Ui, c: v.Palette, bytes: []const u8) !ui.Element {
    return b.styled(try v.text(b, bytes, c.muted, 13), .{ .padding = ui.Insets.all(16), .text = .{ .size = 13, .color = c.muted } });
}
fn codeRow(self: *const Shell, b: *ui.Ui, line: git.Line, path: []const u8, paired: ?[]const u8) !ui.Element {
    const c = self.colors;
    const changed = line.kind == .addition or line.kind == .deletion;
    const tint = if (line.kind == .addition) c.added else if (line.kind == .deletion) c.deleted else self.editor_options.theme.line_number;
    var fill = tint;
    fill.a = 0.14;
    const number = if (line.new_line orelse line.old_line) |n| try std.fmt.allocPrint(b.allocator(), "{d}", .{n}) else "";
    var highlights: [1]@import("code_line.zig").Highlight = undefined;
    var ranges: []const @import("code_line.zig").Highlight = &.{};
    if (paired) |other| {
        const changed_columns = @import("zircon_editor").annotations.changedColumns(other, line.text);
        var strong = tint;
        strong.a = 0.3;
        highlights[0] = .{ .start = changed_columns.start, .end = changed_columns.end, .color = strong };
        ranges = &highlights;
    }
    const code = try @import("code_line.zig").element(b, line.text, path, self.editor_options.font_size, self.editor_options.font_size * self.editor_options.line_height, self.editor_options.theme, ranges);
    const rendered = try b.row(.{ .height = .{ .px = self.editor_options.font_size * self.editor_options.line_height }, .flex_shrink = 0, .align_items = .stretch, .gap = 8, .background = if (changed) fill else null, .overflow = .hidden }, &.{ try b.div(.{ .width = .{ .px = 5 }, .background = if (changed) tint else null, .flex_shrink = 0 }, &.{}), try b.column(.{ .width = .{ .px = 38 }, .flex_shrink = 0, .justify_content = .center, .align_items = .end }, &.{try b.styled(try v.text(b, number, tint, 12), .{ .text = .{ .size = 12, .mono = true, .color = tint } })}), try b.div(.{ .width = .{ .px = 1 }, .flex_shrink = 0, .background = c.border_subtle }, &.{}), code });
    const editable = try @import("../git_editing.zig").renderRow(self, b, line, path, rendered);
    if (line.new_line) |row| return b.key(.{ .string = try std.fmt.allocPrint(b.allocator(), "git-live:{s}:{d}", .{ path, row }) }, editable);
    return editable;
}

// Pair equally sized adjacent deletion/addition runs. Large or unbalanced runs
// retain their line highlight; work for one visible row is bounded.
fn pairedLine(lines: []const git.Line, index: usize) ?[]const u8 {
    const kind = lines[index].kind;
    if (kind != .deletion and kind != .addition) return null;
    var start = index;
    var end = index + 1;
    while (start > 0 and lines[start - 1].kind == kind and index - start < 256) start -= 1;
    while (end < lines.len and lines[end].kind == kind and end - start < 256) end += 1;
    if (end - start >= 256) return null;
    if (kind == .deletion) {
        var after = end;
        while (after < lines.len and lines[after].kind == .addition and after - end < 256) after += 1;
        if (end - start == after - end) return lines[end + index - start].text;
    } else {
        var before = start;
        while (before > 0 and lines[before - 1].kind == .deletion and start - before < 256) before -= 1;
        if (start - before == end - start) return lines[before + index - start].text;
    }
    return null;
}
