//! Grouped real source excerpts. Headers/matches navigate through validated
//! source identities; result text never becomes a disposable document copy.
const std = @import("std");
const ui = @import("zircon_ui");
const Shell = @import("../shell.zig").Shell;
pub const Target = struct { group: u32, match: u32 };
pub fn render(self: *const Shell, b: *ui.Ui) !ui.Element {
    const c = self.colors;
    var content: std.ArrayList(ui.Element) = .empty;
    try content.append(b.allocator(), try b.row(.{ .height = .{ .px = 42 }, .flex_shrink = 0, .gap = 10, .align_items = .center, .padding = .{ .left = 14, .right = 14 }, .background = c.chrome }, &.{ try b.styled(try b.text(if (self.search.busy) "Searching project…" else "Project search"), .{ .flex_grow = 1, .text = .{ .size = 14, .color = c.text } }), try command(b, .project_search, "New search", c), try command(b, .back_to_editor, "Back to editor", c) }));
    if (self.fields) |fields| try content.append(b.allocator(), try b.listen(try b.row(.{ .height = .{ .px = 44 }, .flex_shrink = 0, .gap = 10, .padding = .{ .left = 14, .right = 14, .top = 5, .bottom = 5 }, .background = c.chrome }, &.{ try b.styled(try b.key(.{ .string = "project-query" }, try b.view(fields.project_query)), .{ .flex_grow = 1, .min_width = .{ .px = 0 }, .height = .{ .px = 34 } }), try command(b, .run_project_search, "Search", c) }), .{ .on_input = b.onInput(Shell.onSearchQuery) }));
    var rows: std.ArrayList(ui.Element) = .empty;
    const visible_top = self.search.scroll.offset;
    const visible_bottom = visible_top + @max(0, b.viewport().height - 120);
    var top: f32 = 0;
    if (self.search.results) |results| {
        try rows.append(b.allocator(), try b.styled(try b.textFmt("{d} matches across {d} buffers{s}", .{ results.total_matches, results.groups.len, if (results.truncated) " · results limited" else "" }), .{ .height = .{ .px = 32 }, .padding = .{ .left = 14, .top = 8 }, .text = .{ .size = 12, .color = c.muted } }));
        top += 32;
        for (results.groups, 0..) |group, group_index| {
            if (top + 42 >= visible_top and top < visible_bottom) {
                var path = group.path() orelse group.title;
                if (std.mem.startsWith(u8, path, self.workspace.root_path)) path = std.mem.trimStart(u8, path[self.workspace.root_path.len..], "/");
                const header = try std.fmt.allocPrint(b.allocator(), "{s}    {d} matches{s}", .{ path, group.matches.len, if (group.source == .buffer) " · open buffer" else "" });
                try rows.append(b.allocator(), try b.key(.{ .number = @intCast(group_index) }, try b.button(.{ .label = header, .on_click = try b.onClickWith(Target{ .group = @intCast(group_index), .match = 0 }, Shell.onSearchResult), .style = .{ .height = .{ .px = 42 }, .flex_shrink = 0, .padding = .{ .left = 14, .top = 12 }, .background = c.panel, .hover_background = c.hover, .text = .{ .size = 13, .color = c.text } } })));
            }
            top += 42;
            for (group.excerpts) |excerpt| {
                var lines = std.mem.splitScalar(u8, excerpt.bytes, '\n');
                var row = excerpt.start_line;
                var offset = excerpt.source_range.start;
                while (lines.next()) |line| {
                    const height: f32 = 22;
                    if (top + height >= visible_top and top < visible_bottom) {
                        var match_index: usize = 0;
                        var matched = false;
                        for (group.matches, 0..) |match, index| if (match.line == row) {
                            match_index = index;
                            matched = true;
                            break;
                        };
                        const text = try std.fmt.allocPrint(b.allocator(), "{d: >5}   {s}", .{ row + 1, std.mem.trimEnd(u8, line, "\r") });
                        try rows.append(b.allocator(), try b.button(.{ .label = text, .on_click = try b.onClickWith(Target{ .group = @intCast(group_index), .match = @intCast(match_index) }, Shell.onSearchResult), .style = .{ .height = .{ .px = height }, .flex_shrink = 0, .padding = .{ .left = 8, .top = 3 }, .background = if (matched) c.selected else c.document, .hover_background = c.hover, .text = .{ .size = 13, .mono = true, .color = if (matched) c.text else c.muted }, .overflow = .hidden } }));
                    }
                    top += height;
                    offset += line.len + 1;
                    row += 1;
                }
                top += 16;
            }
        }
        if (results.errors.len > 0) try rows.append(b.allocator(), try b.styled(try b.textFmt("{d} sources could not be searched.", .{results.errors.len}), .{ .text = .{ .size = 12, .color = c.warning } }));
    } else try rows.append(b.allocator(), try b.column(.{ .padding = ui.Insets.all(28), .gap = 14 }, &.{ try b.styled(try b.text("Search project files and unsaved buffers"), .{ .text = .{ .size = 18, .color = c.text } }), try command(b, .project_search, "Start a search", c) }));
    const list = try b.listen(try b.column(.{ .flex_grow = 1, .min_height = .{ .px = 0 }, .overflow = .hidden, .background = c.document }, rows.items), .{ .on_input = b.onInput(Shell.onSearchScroll) });
    try content.append(b.allocator(), list);
    return b.column(.{ .flex_grow = 1, .background = c.document, .overflow = .hidden }, content.items);
}
fn command(b: *ui.Ui, value: @import("../commands.zig").Command, label: []const u8, c: @import("../theme.zig").Palette) !ui.Element {
    return @import("components.zig").actionButton(b, c, value, label, false);
}
