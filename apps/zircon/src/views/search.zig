//! Persistent project-search tab with source-linked excerpts. Buffers override
//! disk files; clicking a row opens the original document, never a copied buffer.
const std = @import("std");
const search = @import("zircon_search");
const ui = @import("zircon_ui");
const shell = @import("../shell.zig");
const code = @import("code_line.zig");
const v = @import("components.zig");
const Shell = shell.Shell;
pub const Target = struct { group: u32, match: u32, generation: u64 };
const header_height: f32 = 36;
pub fn contentHeight(results: search.Results, line_height: f32) f32 {
    var total: f32 = 0;
    for (results.groups) |group| {
        total += header_height;
        for (group.excerpts) |excerpt| total += @as(f32, @floatFromInt(std.mem.count(u8, excerpt.bytes, "\n") + 1)) * line_height + 12;
    }
    return total;
}
pub fn render(self: *const Shell, b: *ui.Ui) !ui.Element {
    const c = self.colors;
    const line_height = self.editor_options.font_size * self.editor_options.line_height;
    var content: std.ArrayList(ui.Element) = .empty;
    if (self.fields) |fields| {
        const query = try b.fluent().view(fields.project_query).style(.{ .flex_grow = 1, .min_width = .{ .px = 0 }, .height = .{ .px = 32 } }).id(.{ .string = "project-query" }).request_focus(self.search_focus_request).build();
        try content.append(b.allocator(), try b.fluent().div().h(.{ .px = 56 }).shrink_0().items_center().gap_px(8).padding(.{ .left = 14, .right = 14 }).background(c.document).flex().children(.{ query, v.actionButton(b, c, .run_project_search, if (self.search.busy) "Searching…" else "Search", false) }).listeners(.{ .on_input = b.onInput(Shell.onSearchQuery) }).build());
    }
    const summary = if (self.search.results) |results| try std.fmt.allocPrint(b.allocator(), "{d} matches in {d} files and buffers{s}", .{ results.total_matches, results.groups.len, if (results.truncated) " · results limited" else "" }) else "Search all project files, including unsaved and untitled buffers";
    try content.append(b.allocator(), try b.fluent().div().h(.{ .px = 28 }).items_center().shrink_0().padding(.{ .left = 14 }).flex().children(.{v.text(b, summary, c.muted, 12)}).build());
    try content.append(b.allocator(), try v.rule(b, c));
    const viewport = @max(1, b.viewport().height - v.metrics.titlebar - v.metrics.tabs - v.metrics.status - 85);
    const total = if (self.search.results) |results| contentHeight(results, line_height) else 0;
    const top = @min(self.search.scroll.offset, @max(0, total - viewport));
    const bottom = top + viewport;
    var y: f32 = 0;
    var first: ?f32 = null;
    var rows: std.ArrayList(ui.Element) = .empty;
    if (self.search.results) |results| {
        for (results.groups, 0..) |group, group_index| {
            if (y >= bottom) break;
            const target: Target = .{ .group = @intCast(group_index), .match = 0, .generation = results.generation };
            if (visible(y, header_height, top, bottom)) {
                if (first == null) first = y;
                var path = group.path() orelse group.title;
                if (std.mem.startsWith(u8, path, self.workspace.root_path)) path = std.mem.trimStart(u8, path[self.workspace.root_path.len..], "/");
                const label = try std.fmt.allocPrint(b.allocator(), "{s}    {d} matches", .{ path, group.matches.len });
                try rows.append(b.allocator(), try b.fluent().button(.{ .label = label, .children = &.{ try v.fileGlyph(self, b, path, false, false, 16), try v.text(b, path, c.text, 13), try v.text(b, try std.fmt.allocPrint(b.allocator(), "{d} matches{s}", .{ group.matches.len, if (group.source == .buffer) " · open buffer" else "" }), c.muted, 11) }, .on_click = b.onClickWith(Shell.onSearchResult, target), .style = .{ .direction = .row, .height = .{ .px = header_height }, .flex_shrink = 0, .gap = 8, .align_items = .center, .padding = .{ .left = 14, .right = 14 }, .background = c.panel, .hover_background = c.hover, .overflow = .hidden } }).id(.{ .number = @intCast(group_index) }).build());
            }
            y += header_height;
            var match_cursor: usize = 0;
            for (group.excerpts) |excerpt| {
                if (y >= bottom) break;
                var lines = std.mem.splitScalar(u8, excerpt.bytes, '\n');
                var row = excerpt.start_line;
                var offset = excerpt.source_range.start;
                while (lines.next()) |line| {
                    if (y >= bottom) break;
                    while (match_cursor < group.matches.len and group.matches[match_cursor].line < row) match_cursor += 1;
                    if (visible(y, line_height, top, bottom)) {
                        if (first == null) first = y;
                        var ranges: std.ArrayList(code.Highlight) = .empty;
                        var index = match_cursor;
                        var fill = c.accent;
                        fill.a = 0.23;
                        while (index < group.matches.len and group.matches[index].line == row) : (index += 1) {
                            const range = group.matches[index].range;
                            try ranges.append(b.allocator(), .{ .start = @min(line.len, range.start -| offset), .end = @min(line.len, range.end -| offset), .color = fill });
                        }
                        var destination = target;
                        destination.match = @intCast(@min(match_cursor, group.matches.len -| 1));
                        const number = try std.fmt.allocPrint(b.allocator(), "{d}", .{row + 1});
                        const label = try std.fmt.allocPrint(b.allocator(), "{s}   {s}", .{ number, line });
                        try rows.append(b.allocator(), try b.fluent().button(.{ .label = label, .children = &.{ try b.fluent().div().w(.{ .px = 45 }).shrink_0().items(.end).justify_center().flex_col().children(.{v.text(b, number, self.editor_options.theme.line_number, 12)}).build(), try b.fluent().div().w(.{ .px = 1 }).shrink_0().background(c.border_subtle).children(.{}).build(), try code.element(b, line, group.path() orelse group.title, self.editor_options.font_size, line_height, self.editor_options.theme, ranges.items) }, .on_click = b.onClickWith(Shell.onSearchResult, destination), .style = .{ .direction = .row, .height = .{ .px = line_height }, .gap = 10, .flex_shrink = 0, .hover_background = c.hover, .overflow = .hidden } }).build());
                    }
                    y += line_height;
                    offset += line.len + 1;
                    row += 1;
                }
                if (visible(y, 12, top, bottom)) {
                    if (first == null) first = y;
                    try rows.append(b.allocator(), try b.fluent().div().h(.{ .px = 12 }).shrink_0().children(.{}).build());
                }
                y += 12;
            }
        }
        if (results.groups.len == 0) try rows.append(b.allocator(), try note(b, c, "No matches. Try a different query."));
        if (results.errors.len > 0) try rows.append(b.allocator(), try note(b, c, try std.fmt.allocPrint(b.allocator(), "{d} sources could not be searched.", .{results.errors.len})));
    } else try rows.append(b.allocator(), try note(b, c, "Enter a query and press Enter to search this project."));
    try content.append(b.allocator(), try b.fluent().div().grow().min_h(.{ .px = 0 }).scroll_y_px(if (first) |origin| @max(0, top - origin) else 0).overflow_hidden().flex_col().children(rows.items).id(.{ .string = "search-excerpts" }).listeners(.{ .on_input = b.onInput(Shell.onSearchScroll) }).build());
    return b.fluent().div().grow().min_h(.{ .px = 0 }).background(c.document).overflow_hidden().flex_col().children(content.items).build();
}
fn visible(y: f32, height: f32, top: f32, bottom: f32) bool {
    return y + height > top and y < bottom;
}
fn note(b: *ui.Ui, c: v.Palette, text: []const u8) !ui.Element {
    return b.fluent().adopt(try v.text(b, text, c.muted, 13)).style(.{ .padding = ui.Insets.all(18), .text = .{ .size = 13, .color = c.muted } }).build();
}
