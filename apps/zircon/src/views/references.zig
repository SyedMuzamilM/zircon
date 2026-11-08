//! LSP reference locations rendered as a source-linked result panel.
const std = @import("std");
const lsp = @import("zircon_language");
const ui = @import("zircon_ui");
const shell = @import("../shell.zig");
const v = @import("components.zig");
const Shell = shell.Shell;

pub fn render(self: *const Shell, b: *ui.Ui) !ui.Element {
    const colors = self.colors;
    const locations = if (self.language.references) |message| message.data.locations.items else &.{};
    var rows: std.ArrayList(ui.Element) = .empty;
    try rows.append(b.allocator(), try b.fluent().div()
        .h(.{ .px = 48 })
        .shrink_0()
        .padding(.{ .left = 14, .right = 14 })
        .items_center()
        .flex()
        .children(.{v.text(b, try std.fmt.allocPrint(b.allocator(), "{d} references", .{locations.len}), colors.text, 14)})
        .build());
    try rows.append(b.allocator(), try v.rule(b, colors));
    for (locations, 0..) |location, index| {
        const label = try std.fmt.allocPrint(b.allocator(), "{s}:{d}:{d}", .{ location.uri, location.range.start.line + 1, location.range.start.character + 1 });
        try rows.append(b.allocator(), try b.fluent().button(.{ .label = label })
            .h(.{ .px = 32 })
            .shrink_0()
            .padding(.{ .left = 14, .right = 10 })
            .items_center()
            .hover_background(colors.hover)
            .on_click(b.onClickWith(Shell.onReference, @as(u32, @intCast(index))))
            .children(.{v.text(b, label, colors.text, 12)})
            .build());
    }
    if (locations.len == 0) try rows.append(b.allocator(), try v.text(b, "No references found.", colors.muted, 13));
    return b.fluent().div()
        .grow()
        .min_h(.{ .px = 0 })
        .background(colors.document)
        .overflow_hidden()
        .flex_col()
        .children(rows.items)
        .id(.{ .string = "references-panel" })
        .build();
}
