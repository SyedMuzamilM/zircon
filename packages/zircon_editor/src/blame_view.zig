//! Blame hover geometry is shared by painting and input. It never inserts rows
//! into the source projection; Git hunk expansion owns that independently.
const std = @import("std");
const ui = @import("zircon_ui");
const text = @import("zircon_text");
const annotations = @import("annotations.zig");
const Theme = @import("theme.zig").Theme;
pub const Options = struct { font: f32, line_height: f32, gutter: f32, horizontal: f32, scroll: f32, tab_width: usize };
pub const Layout = struct { label: ui.Rect, card: ui.Rect, copy: ui.Rect, close: ui.Rect, message: ui.Rect, lines: []const []const u8, label_text: []const u8, content_height: f32 };
pub fn layout(a: std.mem.Allocator, snapshot: text.Snapshot, blame: annotations.Blame, changes: []const annotations.GitChange, options: Options, metrics: ui.layout.Measurer, bounds: ui.Rect) !?Layout {
    if (blame.revision != snapshot.revision() or blame.line >= snapshot.lineCount()) return null;
    const range = try snapshot.lineRange(blame.line);
    if (range.end - range.start > 65536) return null;
    const original = try snapshot.copy(a, range);
    const source = try @import("display.zig").Line.build(a, original, options.tab_width);
    const width = (try metrics.text(metrics.context, source.bytes, .{ .size = options.font, .mono = true })).width;
    const label_text = if (blame.uncommitted) "Uncommitted changes" else try std.fmt.allocPrint(a, "{s} · {s}", .{ blame.author, try annotations.date(a, blame.timestamp) });
    const measured = try metrics.text(metrics.context, label_text, .{ .size = options.font - 1 });
    const line_y = bounds.y + annotations.rowY(blame.line, options.line_height, changes) - options.scroll;
    const x = bounds.x + options.gutter + width - options.horizontal + 28;
    const label: ui.Rect = .{ .x = x, .y = line_y + (options.line_height - measured.height) / 2, .width = @max(0, @min(measured.width, bounds.x + bounds.width - x - 12)), .height = measured.height };
    const card_width = @max(0, @min(560, bounds.width - 24));
    const rows = try wrap(a, metrics, @max(1, card_width - 28), if (blame.uncommitted) "This line has changes that have not been committed." else if (blame.message.len > 0) blame.message else blame.summary);
    const card_height = @max(0, @min(88 + @as(f32, @floatFromInt(@min(rows.len, 10))) * 18, bounds.height - 16));
    const below = line_y + options.line_height + 4;
    const card_y = if (below + card_height <= bounds.y + bounds.height - 8) below else @max(bounds.y + 8, line_y - card_height - 4);
    const card: ui.Rect = .{ .x = std.math.clamp(x, bounds.x + 12, @max(bounds.x + 12, bounds.x + bounds.width - card_width - 12)), .y = card_y, .width = card_width, .height = card_height };
    return .{ .label = label, .label_text = label_text, .card = card, .close = .{ .x = card.x + card.width - 30, .y = card.y + 8, .width = 22, .height = 22 }, .copy = .{ .x = card.x + card.width - 94, .y = card.y + card.height - 30, .width = 84, .height = 22 }, .message = .{ .x = card.x + 14, .y = card.y + 42, .width = @max(0, card.width - 28), .height = @max(0, card.height - 80) }, .lines = rows, .content_height = @as(f32, @floatFromInt(rows.len)) * 18 };
}
pub fn paint(cx: *ui.PaintCx, geometry: Layout, blame: annotations.Blame, theme: Theme, font: f32, message_scroll: f32) !void {
    if (geometry.label.width > 0) try cx.painter.drawText(.{ .bounds = geometry.label, .text = geometry.label_text, .style = .{ .size = font - 1, .color = theme.line_number } });
    if (!blame.expanded) return;
    const card = geometry.card;
    try cx.painter.fillRect(.{ .bounds = .{ .x = card.x + 2, .y = card.y + 3, .width = card.width, .height = card.height }, .color = .{ .r = 0, .g = 0, .b = 0, .a = 0.15 }, .radius = ui.controls.metrics.popover_radius });
    try cx.painter.fillRect(.{ .bounds = card, .color = theme.scrollbar, .radius = ui.controls.metrics.popover_radius });
    try cx.painter.fillRect(.{ .bounds = .{ .x = card.x + 1, .y = card.y + 1, .width = @max(0, card.width - 2), .height = @max(0, card.height - 2) }, .color = theme.active_line, .radius = ui.controls.metrics.popover_radius - 1 });
    try ui.controls.icons.draw(.user, cx.painter, .{ .x = card.x + 12, .y = card.y + 13, .width = 14, .height = 14 }, theme.line_number);
    const title = if (blame.uncommitted) "Uncommitted changes" else try std.fmt.allocPrint(cx.painter.allocator, "{s} <{s}>", .{ blame.author, blame.email });
    try cx.painter.drawText(.{ .bounds = .{ .x = card.x + 34, .y = card.y + 11, .width = @max(0, card.width - 70), .height = 20 }, .text = title, .style = .{ .size = 13, .color = theme.foreground } });
    try ui.controls.icons.draw(.close, cx.painter, geometry.close, theme.line_number);
    try cx.painter.pushClip(geometry.message);
    const scroll = std.math.clamp(message_scroll, 0, @max(0, geometry.content_height - geometry.message.height));
    for (geometry.lines, 0..) |line, i| {
        const y = geometry.message.y + @as(f32, @floatFromInt(i)) * 18 - scroll;
        if (y + 18 < geometry.message.y or y >= geometry.message.y + geometry.message.height) continue;
        try cx.painter.drawText(.{ .bounds = .{ .x = geometry.message.x, .y = y, .width = geometry.message.width, .height = 18 }, .text = line, .style = .{ .size = 12, .color = theme.foreground } });
    }
    cx.painter.popClip();
    const footer = if (blame.uncommitted) "Working tree" else try std.fmt.allocPrint(cx.painter.allocator, "{s} · {s}", .{ try annotations.date(cx.painter.allocator, blame.timestamp), blame.oid[0..@min(8, blame.oid.len)] });
    try cx.painter.drawText(.{ .bounds = .{ .x = card.x + 14, .y = card.y + card.height - 28, .width = @max(0, card.width - 120), .height = 20 }, .text = footer, .style = .{ .size = 12, .color = theme.line_number } });
    if (!blame.uncommitted) {
        try ui.controls.icons.draw(.copy, cx.painter, .{ .x = geometry.copy.x, .y = geometry.copy.y + 3, .width = 14, .height = 14 }, theme.caret);
        try cx.painter.drawText(.{ .bounds = .{ .x = geometry.copy.x + 18, .y = geometry.copy.y + 2, .width = 65, .height = 20 }, .text = "Copy SHA", .style = .{ .size = 12, .color = theme.caret } });
    }
}
fn wrap(a: std.mem.Allocator, metrics: ui.layout.Measurer, width: f32, message: []const u8) ![]const []const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    var remaining = std.mem.trim(u8, message, "\r\n");
    const style: ui.TextStyle = .{ .size = 12 };
    while (remaining.len > 0) {
        const newline = std.mem.indexOfScalar(u8, remaining, '\n') orelse remaining.len;
        var end = @min(newline, metrics.index(remaining[0..newline], style, width));
        if (end == 0 and newline > 0) {
            end = 1;
            while (end < newline and remaining[end] & 0xc0 == 0x80) end += 1;
        }
        if (end < newline) if (std.mem.lastIndexOfScalar(u8, remaining[0..end], ' ')) |space| {
            if (space > 0) end = space;
        };
        try lines.append(a, remaining[0..end]);
        remaining = if (end == newline and end < remaining.len) remaining[end + 1 ..] else remaining[end..];
        remaining = std.mem.trimStart(u8, remaining, " ");
    }
    return lines.toOwnedSlice(a);
}
