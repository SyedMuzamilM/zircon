//! View preferences for the focused editor pane.
const std = @import("std");
const ui = @import("zircon_ui");
const Shell = @import("../../shell.zig").Shell;
const v = @import("../components.zig");
const view = @import("../../view.zig");
const panel = @import("panel.zig");

pub fn render(self: *const Shell, b: *ui.Ui) !ui.Element {
    const c = self.colors;
    var rows: std.ArrayList(ui.Element) = .empty;
    const state = if (self.active_pane == .secondary and self.secondary != null) &self.secondary.?.editor else &self.tabs.items[self.active].editor;
    try rows.append(b.allocator(), try v.menuRow(b, c, .toggle_soft_wrap, "Soft wrap", if (state.soft_wrap != .none) "✓" else "", false));
    try rows.append(b.allocator(), try v.menuRow(b, c, .toggle_inline_blame, "Inline Git blame", if (self.inline_blame_enabled) "✓" else "", false));
    try rows.append(b.allocator(), try v.menuRow(b, c, .settings, "Editor settings…", "⌘,", false));
    try rows.append(b.allocator(), try v.menuRow(b, c, .toggle_line_numbers, "Line numbers", if (state.show_line_numbers) "✓" else "", false));
    try rows.append(b.allocator(), try v.menuRow(b, c, .toggle_indent_guides, "Indent guides", if (state.show_indent_guides) "✓" else "", false));
    try rows.append(b.allocator(), try v.rule(b, c));
    try rows.append(b.allocator(), try v.menuRow(b, c, .toggle_vim, "Vim mode", if (state.vim.enabled) "✓" else "", false));

    return panel.render(self, b, .{ .width = 380, .height = 194 }, rows.items);
}
