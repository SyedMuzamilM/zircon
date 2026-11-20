//! Completion choices sit on the caret. The language service owns filtering and acceptance.
const std = @import("std");
const ui = @import("zircon_ui");
const shell = @import("../shell.zig");
const v = @import("components.zig");
const Shell = shell.Shell;
const row_height: f32 = 30;
const accessibility_id: u64 = 3;

pub fn render(self: *const Shell, b: *ui.Ui) !?ui.Element {
    if (self.overlay != .none) return null;
    const message = self.language.completions orelse return null;
    const items = message.data.completion.items;
    if (items.len == 0) return null;
    const colors = self.colors;
    const viewport = b.viewport();
    const start = self.language.completion_index -| 7;
    const visible = items[start..@min(start + 8, items.len)];
    var choices: std.ArrayList(ui.Element) = .empty;
    for (visible, start..) |item, index| {
        const choice = try b.fluent().button(.{ .label = item.label })
            .h_px(row_height)
            .shrink_0()
            .padding(.{ .left = 12, .right = 12 })
            .items_center()
            .gap_px(16)
            .flex()
            .background(if (index == self.language.completion_index) colors.selected else colors.panel)
            .hover_background(colors.hover)
            .overflow_hidden()
            .on_click(b.onClickWith(Shell.onCompletion, @as(u32, @intCast(index))))
            .children(.{
                b.fluent().adopt(try v.text(b, item.label, colors.text, 13)).grow().min_w(.{ .px = 0 }).overflow_hidden(),
                v.text(b, item.detail orelse "", colors.muted, 12),
            })
            .id(.{ .number = @intCast(index) })
            .build();
        var identity = std.hash.Wyhash.init(message.data.completion.id);
        std.hash.autoHash(&identity, index);
        identity.update(item.label);
        try choices.append(b.allocator(), try b.accessible(choice, .{
            .id = identity.final() | (1 << 63),
            .role = .button,
            .parent = accessibility_id,
            .label = item.label,
            .selected = index == self.language.completion_index,
        }));
    }
    const requested: ui.Size = .{ .width = @min(480, viewport.width - 24), .height = @as(f32, @floatFromInt(choices.items.len)) * row_height + 12 };
    var anchor: ui.Rect = .{ .x = if (self.sidebar_visible) self.panelWidth() + 60 else 60, .y = 100, .height = 22 };
    if (self.window) |handle| if (b.frame.app) |app| {
        if ((try app.window(handle)).frames.committed.text_input) |input| anchor = input.caret;
    };
    anchor.width = requested.width;
    const placement = v.popoverBounds(viewport, anchor, requested);
    const popup = try b.fluent().adopt(try v.floatingPanel(b, colors, .{ .width = placement.width, .height = placement.height }, ui.Insets.all(6), 0, choices.items))
        .id(.{ .string = "completion-list" })
        .build();
    return try b.fluent().div()
        .padding(.{ .top = placement.y, .left = placement.x })
        .stack()
        .children(.{try b.accessible(popup, .{ .id = accessibility_id, .role = .list, .label = "Completions" })})
        .build();
}
