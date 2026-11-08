//! Virtualized Git multibuffer content. Layout, painting, hit testing and hunk
//! navigation share one row projection for unified and split comparisons.

const std = @import("std");
const editor = @import("zircon_editor");
const git = @import("zircon_git");
const ui = @import("zircon_ui");
const widgets = @import("zircon_widgets");
const layout = @import("layout.zig");
pub const Content = struct {
    diff: git.Diff,
    projection: ?layout.Projection,
    state: *const layout.State,
    scroll: f32,
    font: f32,
    line_height: f32,
    theme: editor.Theme,
    colors: widgets.Palette,

    /// Hooks only build the application-owned file controls and source input
    /// listeners. No host value or borrowed patch escapes this render call.
    pub fn render(self: Content, b: *ui.Ui, host: anytype, comptime Hooks: type) !ui.Element {
        var elements: std.ArrayList(ui.Element) = .empty;
        const bottom = self.scroll + b.viewport().height;
        var first: ?f32 = null;
        var top: f32 = 0;
        if (self.projection) |projection| for (projection.files, 0..) |file, index| {
            const height = file.height(self.state, self.line_height);
            if (top >= bottom) break;
            if (top + height <= self.scroll) {
                top += height;
                continue;
            }
            if (top + layout.file_height > self.scroll) {
                if (first == null) first = top;
                try elements.append(b.allocator(), try Hooks.header(host, b, file, index));
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
                        .hunk => |h| try elements.append(b.allocator(), try self.hunkHeader(b, self.diff.hunks[h].header)),
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
                                    if (try Hooks.liveBlock(host, b, lines[at], file.path, end - row_index)) |block| {
                                        try elements.append(b.allocator(), block);
                                        row_index = end - 1;
                                        continue;
                                    }
                                }
                                try elements.append(b.allocator(), try self.line(b, host, Hooks, lines[at], file.path, pairedLine(lines, at), true));
                            } else {
                                const left = if (code.old) |at| try self.line(b, host, Hooks, lines[at], file.path, if (code.new) |n| lines[n].text else null, false) else try self.blank(b);
                                const right = if (code.new) |at| try self.line(b, host, Hooks, lines[at], file.path, if (code.old) |n| lines[n].text else null, true) else try self.blank(b);
                                try elements.append(b.allocator(), try b.fluent().row().h_px(self.line_height).shrink_0().children(.{
                                    b.fluent().adopt(left).w(.{ .percent = 50 }).min_w_px(0).shrink_0(),
                                    b.fluent().div().w_px(1).shrink_0().background(self.colors.line),
                                    b.fluent().adopt(right).grow().min_w_px(0).shrink_by(1),
                                }).id(.{ .string = try std.fmt.allocPrint(b.allocator(), "git-split:{s}:{d}:{d}", .{ file.path, code.hunk, row.code_before }) }).build());
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
                try elements.append(b.allocator(), try self.line(b, host, Hooks, .{ .kind = .metadata, .text = bytes }, "", null, false));
            }
        }
        if (self.diff.text.len == 0) try elements.append(b.allocator(), try b.fluent().adopt(try widgets.text(b, "No uncommitted changes", self.colors.muted, 13)).padding(ui.Insets.all(16)).build());
        return b.fluent().column().grow().min_h_px(0).scroll_y_px(if (first) |origin| @max(0, self.scroll - origin) else 0).overflow_hidden().children(elements.items).id(.{ .string = "git-diff-lines" }).build();
    }
    fn hunkHeader(self: Content, b: *ui.Ui, label: []const u8) !ui.Element {
        return b.fluent().row().h_px(layout.context_height).shrink_0().items_center().padding(.{ .left = 76 }).background(self.colors.sidebar).children(.{widgets.text(b, label, self.colors.muted, 11)}).build();
    }
    fn blank(self: Content, b: *ui.Ui) !ui.Element {
        return b.fluent().div().h_px(self.line_height).shrink_0().background(self.colors.sidebar).build();
    }
    fn line(self: Content, b: *ui.Ui, host: anytype, comptime Hooks: type, original: git.Line, path: []const u8, paired: ?[]const u8, live: bool) !ui.Element {
        const c = self.colors;
        const changed = original.kind == .addition or original.kind == .deletion;
        const tint = if (original.kind == .addition) c.added else if (original.kind == .deletion) c.deleted else self.theme.line_number;
        var fill = tint;
        fill.a = 0.14;
        const number = if (original.new_line orelse original.old_line) |n| try std.fmt.allocPrint(b.allocator(), "{d}", .{n}) else "";
        var highlights: [1]editor.code_line.Highlight = undefined;
        var ranges: []const editor.code_line.Highlight = &.{};
        if (paired) |other| {
            const columns = editor.annotations.changedColumns(other, original.text);
            var strong = tint;
            strong.a = 0.3;
            highlights[0] = .{ .start = columns.start, .end = columns.end, .color = strong };
            ranges = &highlights;
        }
        const code = try editor.code_line.element(b, original.text, path, self.font, self.line_height, self.theme, ranges);
        const row = try b.fluent().row().h_px(self.line_height).shrink_0().items(.stretch).background(if (changed) fill else null).overflow_hidden().children(.{
            b.fluent().div().w_px(5).background(if (changed) tint else null).shrink_0(),
            b.fluent().column().w_px(35).shrink_0().justify_center().items(.end).child(b.fluent().text(number).text_size(12).style(.{ .text = .{ .size = 12, .color = tint, .mono = true } })),
            b.fluent().div().w_px(1).shrink_0().background(c.border_subtle),
            b.fluent().div().w_px(35).shrink_0(),
            code,
        }).build();
        var value = original;
        if (!live) value.new_line = null;
        const result = try Hooks.liveRow(host, b, value, path, row);
        if (value.new_line) |n| return b.fluent().adopt(result).id(.{ .string = try std.fmt.allocPrint(b.allocator(), "git-live:{s}:{d}", .{ path, n }) }).build();
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
