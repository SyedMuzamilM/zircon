//! Virtualized Git multibuffer content. Layout, painting, hit testing and hunk
//! navigation share one row projection for unified and split comparisons.

const std = @import("std");
const editor = @import("zircon_editor");
const git = @import("zircon_git");
const ui = @import("zircon_ui");
const widgets = @import("zircon_widgets");
const layout = @import("layout.zig");
const review_model = @import("review.zig");
pub const Content = struct {
    diff: git.Diff,
    projection: ?layout.Projection,
    state: *const layout.State,
    scroll: f32,
    font: f32,
    line_height: f32,
    width: f32 = 800,
    line_numbers: bool = true,
    indent_guides: bool = true,
    tab_width: usize = 4,
    horizontal: f32 = 0,
    theme: editor.Theme,
    colors: widgets.Palette,
    review: ?*const review_model.Review = null,

    /// Hooks only build the application-owned file controls and source input
    /// listeners. No host value or borrowed patch escapes this render call.
    pub fn render(self: Content, b: *ui.Ui, host: anytype, comptime Hooks: type) !ui.Element {
        var elements: std.ArrayList(ui.Element) = .empty;
        const bottom = self.scroll + b.viewport().height;
        var first: ?f32 = null;
        var top: f32 = 0;
        var sticky: ?ui.Element = null;
        var push: f32 = 0;
        if (self.projection) |projection| for (projection.files, 0..) |file, index| {
            const height = file.height(self.state, self.line_height);
            if (top >= bottom) break;
            if (top + height <= self.scroll) {
                top += height;
                continue;
            }
            const pinned = widgets.sticky_header.offset(top, top + height, layout.file_height, self.scroll);
            if (pinned) |offset| {
                sticky = try Hooks.header(host, b, file, index);
                push = offset;
            }
            if (top + layout.file_height > self.scroll) {
                if (first == null) first = top;
                try elements.append(b.allocator(), if (pinned != null) try b.fluent().div().h_px(layout.file_height).shrink_0().build() else try Hooks.header(host, b, file, index));
            }
            if (!self.state.collapsed.contains(file.path)) {
                const rows = file.rows(self.state.mode);
                const start = layout.visibleStart(rows, self.line_height, self.scroll - top - layout.file_height);
                var row_index = start;
                while (row_index < rows.len) : (row_index += 1) {
                    const row = rows[row_index];
                    const y = top + layout.file_height + row.top(self.line_height);
                    if (y >= bottom) break;
                    if (first == null) first = y;
                    switch (row.kind) {
                        .hunk => |h| try elements.append(b.allocator(), try Hooks.hunkHeader(host, b, h, row.direction)),
                        .code => |code| {
                            const lines = self.diff.hunks[code.hunk].lines;
                            if (self.state.mode == .unified) {
                                const at = code.new orelse code.old.?;
                                if (code.new != null and lines[at].new_line != null) {
                                    var end = row_index + 1;
                                    while (end < rows.len and rows[end].kind == .code) : (end += 1) {
                                        const next = rows[end].kind.code;
                                        if (next.hunk != code.hunk or next.new == null) break;
                                        const line_at = next.new.?;
                                        if (lines[line_at].kind != lines[at].kind or lines[line_at].new_line == null or lines[line_at].new_line.? != lines[at].new_line.? + end - row_index) break;
                                        if (top + layout.file_height + rows[end].top(self.line_height) >= bottom) break;
                                    }
                                    if (try Hooks.liveBlock(host, b, lines[at], file.path, end - row_index, self.width)) |block| {
                                        try elements.append(b.allocator(), block);
                                        row_index = end - 1;
                                        continue;
                                    }
                                }
                                try elements.append(b.allocator(), try self.line(b, host, Hooks, lines[at], file.path, pairedLine(lines, at), true, .{ .hunk = code.hunk, .line = at, .side = .unified }, row));
                            } else {
                                const left = if (code.old) |at| try self.line(b, host, Hooks, lines[at], file.path, if (code.new) |n| lines[n].text else null, false, .{ .hunk = code.hunk, .line = at, .side = .old }, row) else try self.blank(b, row.height(self.line_height));
                                const right = if (code.new) |at| try self.line(b, host, Hooks, lines[at], file.path, if (code.old) |n| lines[n].text else null, true, .{ .hunk = code.hunk, .line = at, .side = .new }, row) else try self.blank(b, row.height(self.line_height));
                                try elements.append(b.allocator(), try b.fluent().row()
                                    .h_px(row.height(self.line_height))
                                    .shrink_0()
                                    .children(.{
                                        b.fluent().adopt(left).w_px((self.width - 1) / 2).min_w_px(0).shrink_0(),
                                        b.fluent().div().w_px(1).shrink_0().background(self.colors.line),
                                        b.fluent().adopt(right).grow().min_w_px(0).shrink_by(1),
                                    })
                                    .id(.{ .string = try std.fmt.allocPrint(b.allocator(), "git-split:{s}:{d}:{d}", .{ file.path, code.hunk, row.code_before }) })
                                    .build());
                            }
                        },
                    }
                }
            }
            top += height;
        };
        if (self.diff.hunks.len == 0) {
            var lines = std.mem.splitScalar(u8, self.diff.text, '\n');
            var y: f32 = 0;
            while (lines.next()) |bytes| : (y += self.line_height) {
                if (y >= bottom) break;
                if (y + self.line_height <= self.scroll) continue;
                if (first == null) first = y;
                try elements.append(b.allocator(), try self.line(b, host, Hooks, .{ .kind = .metadata, .text = bytes }, "", null, false, null, null));
            }
        }
        if (self.diff.text.len == 0) try elements.append(b.allocator(), try b.fluent().adopt(try widgets.text(b, "No uncommitted changes", self.colors.muted, 13))
            .padding(ui.Insets.all(16))
            .build());
        const content = try b.fluent().column()
            .grow()
            .min_h_px(0)
            .scroll_y_px(if (first) |origin| @max(0, self.scroll - origin) else 0)
            .overflow_hidden()
            .children(elements.items)
            .build();
        return b.fluent().adopt(if (sticky) |header| try widgets.sticky_header.overlay(b, content, header, layout.file_height, push) else content)
            .id(.{ .string = "git-diff-lines" }).build();
    }
    fn blank(self: Content, b: *ui.Ui, height: f32) !ui.Element {
        return b.fluent().div().h_px(height).shrink_0().background(self.colors.sidebar).build();
    }
    fn indentCells(self: Content, loc: Location, bytes: []const u8, live: bool) usize {
        if (!editor.indent_guides.blank(bytes)) return editor.indent_guides.cells(bytes, self.tab_width);
        const lines = self.diff.hunks[loc.hunk].lines;
        var before: ?[]const u8 = null;
        var after: ?[]const u8 = null;
        for (0..@min(1024, lines.len)) |distance| {
            if (before == null and loc.line > distance) {
                const line_value = lines[loc.line - distance - 1];
                if ((if (live) line_value.new_line != null else line_value.old_line != null) and !editor.indent_guides.blank(line_value.text)) before = line_value.text;
            }
            if (after == null and loc.line + distance + 1 < lines.len) {
                const line_value = lines[loc.line + distance + 1];
                if ((if (live) line_value.new_line != null else line_value.old_line != null) and !editor.indent_guides.blank(line_value.text)) after = line_value.text;
            }
            if (before != null and after != null) return editor.indent_guides.between(before.?, after.?, self.tab_width);
        }
        return 0;
    }
    const Location = struct { hunk: usize, line: usize, side: review_model.Side };
    fn line(self: Content, b: *ui.Ui, host: anytype, comptime Hooks: type, original: git.Line, path: []const u8, paired: ?[]const u8, live: bool, location: ?Location, projected: ?layout.Row) !ui.Element {
        const changed = original.kind == .addition or original.kind == .deletion;
        const tint = if (original.kind == .addition) self.theme.git_added else if (original.kind == .deletion) self.theme.git_deleted else self.theme.line_number;
        var fill = tint;
        fill.a = 0.14;
        const number = if (if (live) original.new_line orelse original.old_line else original.old_line) |n| try std.fmt.allocPrint(b.allocator(), "{d}", .{n}) else "";
        var highlights: [2]editor.code_line.Highlight = undefined;
        var range_count: usize = 0;
        if (paired) |other| {
            const columns = editor.annotations.changedColumns(other, original.text);
            var strong = tint;
            strong.a = 0.3;
            highlights[0] = .{ .start = columns.start, .end = columns.end, .color = strong };
            range_count += 1;
        }
        if (location) |loc| if (self.review) |review| if (review.selected(loc.hunk, loc.line, loc.side)) |selected| {
            highlights[range_count] = .{ .start = selected.start, .end = selected.end, .color = self.theme.selection };
            range_count += 1;
        };
        const segments = if (projected) |r| (if (location.?.side == .old or !live) r.visual.?.old else r.visual.?.new) else &.{};
        var gutter: f32 = if (self.line_numbers) 76 else 20;
        if (location) |loc| if (self.projection) |p| for (p.files) |file| {
            if (loc.hunk >= file.first_hunk and loc.hunk < file.end_hunk) {
                if (self.line_numbers) gutter = editor.gutterWidth(file.max_line, self.font);
                break;
            }
        };
        const code = try editor.code_line.element(b, original.text, path, self.font, self.line_height, self.theme, highlights[0..range_count], .{ .tab_width = self.tab_width, .horizontal = self.horizontal, .segments = segments, .indent_guides = self.indent_guides, .indent_cells = if (location) |loc| self.indentCells(loc, original.text, live) else null });
        const row = try b.fluent().row()
            .h_px(if (projected) |r| r.height(self.line_height) else self.line_height)
            .shrink_0()
            .items(.stretch)
            .background(if (changed) fill else null)
            .overflow_hidden()
            .cursor(.text)
            .children(.{
                b.fluent().div().w_px(6).background(if (changed) tint else null).shrink_0(),
                b.fluent().column()
                    .w_px(if (self.line_numbers) gutter - 42 else 0)
                    .shrink_0()
                    .justify(.start)
                    .items(.end)
                    .child(b.fluent().text(if (self.line_numbers) number else "")
                    .h_px(self.line_height)
                    .text_size(self.font - 1)
                    .style(.{ .height = .{ .px = self.line_height }, .text = .{ .size = self.font - 1, .color = self.theme.line_number, .mono = true } })),
                b.fluent().div().w_px(if (self.line_numbers) 36 else 14).shrink_0(),
                code,
            }).build();
        var value = original;
        if (!live) value.new_line = null;
        const result = try Hooks.liveRow(host, b, value, path, row, if (self.state.mode == .split) (self.width - 1) / 2 else self.width);
        if (value.new_line) |n| return b.fluent().adopt(result)
            .id(.{ .string = try std.fmt.allocPrint(b.allocator(), "git-live:{s}:{d}", .{ path, n }) })
            .build();
        if (location) |loc| return b.fluent().adopt(result)
            .id(.{ .string = try std.fmt.allocPrint(b.allocator(), "git-code:{s}:{d}:{d}", .{ @tagName(loc.side), loc.hunk, loc.line }) })
            .build();
        return result;
    }
};

pub fn pairedLine(lines: []const git.Line, index: usize) ?[]const u8 {
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
