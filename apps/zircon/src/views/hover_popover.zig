//! One card for a diagnostic on the caret and for symbol documentation.
const std = @import("std");
const editing = @import("zircon_editor");
const ui = @import("zircon_ui");
const shell = @import("../shell.zig");
const v = @import("components.zig");
const Shell = shell.Shell;

pub fn bounds(self: *const Shell, viewport: ui.Size) ui.Rect {
    const target = self.symbol_hover.target.?;
    const width = @min(self.symbol_hover.width, @max(80, viewport.width - 16));
    const height = @min(self.symbol_hover.height, @max(40, viewport.height - 16));
    const y = target.anchor.y + target.anchor.height + 6;
    return .{ .x = std.math.clamp(target.anchor.x - 12, 8, @max(8, viewport.width - width - 8)), .y = std.math.clamp(if (y + height <= viewport.height - 8) y else target.anchor.y - height - 6, 8, @max(8, viewport.height - height - 8)), .width = width, .height = height };
}

pub fn render(self: *const Shell, b: *ui.Ui) !?ui.Element {
    if (self.symbol_hover.target == null) return null;
    if (!self.symbol_hover.requested) try b.requestFrameAfter(@max(0.001, self.symbol_hover.due - b.frame.time));
    if (self.symbol_hover.note == null and self.symbol_hover.preview == null) return null;
    var children: std.ArrayList(ui.Element) = .empty;
    if (self.symbol_hover.note) |note| {
        const tint = editing.element.color(self.editor_options.theme, note.severity);
        const message = if (note.source.len == 0) note.message else try std.fmt.allocPrint(b.allocator(), "{s} · {s}", .{ note.message, note.source });
        try children.append(b.allocator(), try b.fluent().row().h_px(28).shrink_0().items_center().gap_px(8).overflow_hidden().children(.{
            b.fluent().div().w_px(2).h_px(16).shrink_0().background(tint),
            try v.text(b, message, tint, 12),
        }).build());
    }
    if (self.symbol_hover.preview) |preview| try children.append(b.allocator(), try preview.render(b));
    const area = bounds(self, b.viewport());
    const content = try b.fluent().div().flex_col().overflow_hidden().children(children.items).listeners(.{ .on_input = b.onInput(input) }).build();
    const card = try v.floatingPanel(b, self.colors, .{ .width = area.width, .height = area.height }, ui.Insets.all(4), 0, &.{content});
    return try b.fluent().adopt(card).margin(.{ .top = area.y, .left = area.x }).id(.{ .string = "symbol-hover" }).build();
}

fn input(self: *Shell, e: *ui.Event(ui.Input), cx: *ui.Context(Shell)) !void {
    if (e.data == .scroll) if (self.symbol_hover.preview) |*preview| {
        _ = try preview.handle(e);
        e.preventDefault();
        e.stopPropagation();
        cx.notify();
    };
}
