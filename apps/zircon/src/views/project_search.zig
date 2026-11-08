//! Persistent project-search tab with source-linked excerpts. Buffers override
//! disk files; excerpts edit their source documents and headers open source tabs.
const std = @import("std");
const ui = @import("zircon_ui");
const search_editing = @import("../search_editing.zig");
const shell = @import("../shell.zig");
const v = @import("components.zig");
const field_input = @import("input.zig");
const Shell = shell.Shell;

pub const Fields = struct {
    query: field_input.Handle,

    pub fn init(cx: *ui.Context(Shell), a: std.mem.Allocator) !Fields {
        return .{ .query = try field_input.create(cx, a, .{ .placeholder = "Search project files and open buffers…", .icon = .search }) };
    }
};

pub const Target = struct { group: u32, match: u32, generation: u64 };
const header_height: f32 = 36;
pub fn contentHeight(self: *const Shell) !f32 {
    const results = self.search.results orelse return 0;
    const line_height = self.editor_options.font_size * self.editor_options.line_height;
    var total: f32 = 0;
    for (results.groups, 0..) |group, group_index| {
        total += header_height;
        for (group.excerpts, 0..) |_, index| {
            if (try search_editing.excerpt(self, group_index, index)) |source| total += @as(f32, @floatFromInt(source.rows)) * line_height + 12 else total += 40;
        }
    }
    return total;
}

pub fn render(self: *const Shell, b: *ui.Ui, pane: u8) !ui.Element {
    const c = self.colors;
    const line_height = self.editor_options.font_size * self.editor_options.line_height;
    var content: std.ArrayList(ui.Element) = .empty;
    if (self.fields) |fields| {
        const query = try b.fluent().view(fields.project_search.query).style(.{
            .flex_grow = 1,
            .min_width = .{ .px = 0 },
            .height = .{ .px = 32 },
        })
            .id(.{ .string = "project-query" }).request_focus(self.search_focus_request)
            .build();
        try content.append(b.allocator(), try b.fluent().div()
            .h(.{ .px = 56 })
            .shrink_0()
            .items_center()
            .gap_px(8)
            .padding(.{ .left = 14, .right = 14 })
            .background(c.document)
            .flex()
            .children(.{
                query,
                v.actionButton(b, c, .run_project_search, if (self.search.busy) "Searching…" else "Search", false),
            }).listeners(.{ .on_input = b.onInput(Shell.onSearchQuery) })
            .build());
    }
    const summary = if (self.search.results) |results| try std.fmt.allocPrint(b.allocator(), "{d} matches in {d} files and buffers{s}", .{ results.total_matches, results.groups.len, if (results.truncated) " · results limited" else "" }) else "Search all project files, including unsaved and untitled buffers";
    try content.append(b.allocator(), try b.fluent().div()
        .h(.{ .px = 28 })
        .items_center()
        .shrink_0()
        .padding(.{ .left = 14 })
        .flex()
        .children(.{v.text(b, summary, c.muted, 12)})
        .build());
    try content.append(b.allocator(), try v.rule(b, c));
    const viewport = self.search.editing.viewport[pane] orelse @max(1, b.viewport().height - v.metrics.titlebar - v.metrics.tabs - v.metrics.status - 85);
    const total = try contentHeight(self);
    const top = @min(self.search.editing.scroll[pane].offset, @max(0, total - viewport));
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
                try rows.append(b.allocator(), try b.fluent().button(.{
                    .label = label,
                })
                    .flex()
                    .h(.{ .px = header_height })
                    .shrink_0()
                    .gap_px(8)
                    .items_center()
                    .padding(.{ .left = 14, .right = 14 })
                    .background(c.panel)
                    .hover_background(c.hover)
                    .overflow_hidden()
                    .on_click(b.onClickWith(Shell.onSearchResult, target))
                    .children(&.{
                        try v.fileGlyph(self, b, path, false, false, 16),                                                                                                         try v.text(b, path, c.text, 13),
                        try v.text(b, try std.fmt.allocPrint(b.allocator(), "{d} {s}", .{ group.matches.len, if (group.matches.len == 1) "match" else "matches" }), c.muted, 11),
                    })
                    .id(.{ .number = @intCast(group_index) })
                    .build());
            }
            y += header_height;
            for (group.excerpts, 0..) |_, excerpt_index| {
                const source = try search_editing.excerpt(self, group_index, excerpt_index) orelse {
                    if (visible(y, 40, top, bottom)) {
                        if (first == null) first = y;
                        try rows.append(b.allocator(), try b.fluent().div()
                            .h(.{ .px = 40 })
                            .shrink_0()
                            .padding(.{ .left = 14 })
                            .items_center()
                            .children(.{v.text(b, "This source changed. Run the search again.", c.muted, 12)})
                            .build());
                    }
                    y += 40;
                    continue;
                };
                const height = @as(f32, @floatFromInt(source.rows)) * line_height;
                if (visible(y, height, top, bottom)) {
                    const skipped: usize = @intFromFloat(@floor(@max(0, top - y) / line_height));
                    const shown: usize = @min(source.rows - skipped, @as(usize, @intFromFloat(@ceil((bottom - @max(y, top)) / line_height))) + 1);
                    const origin = y + @as(f32, @floatFromInt(skipped)) * line_height;
                    if (first == null) first = origin;
                    const record = try self.workspace.getConst(source.document);
                    try rows.append(b.allocator(), try search_editing.render(self, b, .{
                        .group = @intCast(group_index),
                        .excerpt = @intCast(excerpt_index),
                        .generation = self.search.editing.generation,
                        .revision = record.doc.revision(),
                        .first_row = source.first_row + skipped,
                        .pane = pane,
                    }, source, source.first_row + skipped, shown));
                }
                y += height;
                if (visible(y, 12, top, bottom)) {
                    if (first == null) first = y;
                    try rows.append(b.allocator(), try b.fluent().div()
                        .h(.{ .px = 12 })
                        .shrink_0()
                        .children(.{})
                        .build());
                }
                y += 12;
            }
        }
        if (results.groups.len == 0) try rows.append(b.allocator(), try note(b, c, "No matches. Try a different query."));
        if (results.errors.len > 0) try rows.append(b.allocator(), try note(b, c, try std.fmt.allocPrint(b.allocator(), "{d} sources could not be searched.", .{results.errors.len})));
    } else try rows.append(b.allocator(), try note(b, c, "Enter a query and press Enter to search this project."));
    try content.append(b.allocator(), try b.fluent().div()
        .grow()
        .min_h(.{ .px = 0 })
        .scroll_y_px(if (first) |origin| @max(0, top - origin) else 0)
        .overflow_hidden()
        .flex_col()
        .children(rows.items)
        .id(.{ .string = "search-excerpts" })
        .listeners(.{ .on_input = b.onInputWith(onScroll, pane) })
        .build());
    return b.fluent().div()
        .grow()
        .min_h(.{ .px = 0 })
        .background(c.document)
        .overflow_hidden()
        .flex_col()
        .children(content.items)
        .build();
}

fn visible(y: f32, height: f32, top: f32, bottom: f32) bool {
    return y + height > top and y < bottom;
}

fn note(b: *ui.Ui, c: v.Palette, text: []const u8) !ui.Element {
    return b.fluent().adopt(try v.text(b, text, c.muted, 13)).style(.{
        .padding = ui.Insets.all(18),
        .text = .{ .size = 13, .color = c.muted },
    })
        .build();
}

fn onScroll(self: *Shell, event: *ui.Event(ui.Input), cx: *ui.Context(Shell), pane: u8) !void {
    if (event.data != .scroll) return;
    self.search.editing.viewport[pane] = event.bounds.height;
    self.search.editing.scroll[pane].wheel(event.data.scroll.y, try contentHeight(self), event.bounds.height);
    event.preventDefault();
    cx.notify();
}
