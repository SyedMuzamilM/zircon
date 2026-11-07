const std = @import("std");
const ui = @import("zircon_ui");
const Shell = @import("../shell.zig").Shell;
const v = @import("components.zig");
const service = @import("../services/buffer_find.zig");
const Option = enum { replace, case_sensitive, whole_word, regex, close };
pub fn render(self: *const Shell, b: *ui.Ui) !ui.Element {
    const c = self.colors;
    const fields = self.fields.?;
    var top: std.ArrayList(ui.Element) = .empty;
    try top.append(b.allocator(), try button(b, c, .replace, "Toggle replace", if (self.find.replace) .chevron_down else .chevron_right, self.find.replace));
    var input = try b.styled(try b.key(.{ .string = "buffer-query" }, try b.view(fields.find_query)), .{ .flex_grow = 1, .min_width = .{ .px = 60 }, .height = .{ .px = 30 }, .flex_shrink = 1 });
    input = try b.requestFocus(input, if (self.find.focus_replacement) 0 else self.find.focus);
    input = try b.listen(try b.div(.{ .flex_grow = 1, .min_width = .{ .px = 60 }, .height = .{ .px = 30 }, .flex_shrink = 1 }, &.{input}), .{ .on_capture = b.onInputWith(fieldKeys, false) });
    try top.append(b.allocator(), input);
    inline for (.{ .{ Option.case_sensitive, "Aa", "Match case" }, .{ Option.whole_word, "Wd", "Whole word" }, .{ Option.regex, ".*", "Regular expression" } }) |option| {
        var style = v.iconButtonStyle(c, @field(self.find, @tagName(option[0])));
        style.width = .{ .px = 27 };
        style.text = .{ .size = 12, .color = c.text };
        try top.append(b.allocator(), try b.button(.{ .label = option[2], .tooltip = option[2], .tooltip_colors = .{ c.panel, c.text, c.line }, .children = &.{try v.text(b, option[1], c.text, 12)}, .on_click = b.onClickWith(toggle, option[0]), .style = style }));
    }
    try top.appendSlice(b.allocator(), &.{ try v.iconButton(b, c, .find_previous, "Previous match", .chevron_left, false), try v.iconButton(b, c, .find_next, "Next match", .chevron_right, false) });
    const count = if (self.find.result) |r| r.value.matches.len else 0;
    var selected: usize = 0;
    if (self.find.document) |id| if (self.workspace.getConst(id)) |_| {
        const state = if (self.find.pane == 1 and self.secondary != null) &self.secondary.?.editor else if (self.tabs.items.len > 0) &self.tabs.items[self.active].editor else null;
        if (state) |editor| if (self.find.result) |r| for (r.value.matches, 0..) |match, i| if (editor.primary().head >= match.start and editor.primary().head <= match.end) {
            selected = i + 1;
            break;
        };
    } else |_| {};
    const counter = if (self.find.waiting or self.find.busy) "…" else try std.fmt.allocPrint(b.allocator(), "{d}/{d}", .{ selected, count });
    try top.append(b.allocator(), try v.text(b, counter, c.muted, 11));
    try top.append(b.allocator(), try button(b, c, .close, "Close buffer search", .close, false));
    var rows: std.ArrayList(ui.Element) = .empty;
    try rows.append(b.allocator(), try b.row(.{ .height = .{ .px = 38 }, .flex_shrink = 0, .align_items = .center, .gap = 4 }, top.items));
    if (self.find.replace) {
        var replacement = try b.styled(try b.key(.{ .string = "buffer-replacement" }, try b.view(fields.replacement)), .{ .flex_grow = 1, .min_width = .{ .px = 60 } });
        replacement = try b.requestFocus(replacement, if (self.find.focus_replacement) self.find.focus else 0);
        replacement = try b.listen(try b.div(.{ .flex_grow = 1, .min_width = .{ .px = 60 } }, &.{replacement}), .{ .on_capture = b.onInputWith(fieldKeys, true) });
        try rows.append(b.allocator(), try b.row(.{ .height = .{ .px = 38 }, .flex_shrink = 0, .align_items = .center, .gap = 6, .padding = .{ .left = 28 } }, &.{ replacement, try v.actionButton(b, c, .replace_one, "Replace", false), try v.actionButton(b, c, .replace_all, "Replace all", false) }));
    }
    if (self.find.error_text.len > 0) try rows.append(b.allocator(), try v.text(b, self.find.error_text, c.warning, 11));
    if (self.find.result) |result| if (result.value.truncated) try rows.append(b.allocator(), try v.text(b, "First 20,000 matches shown. Narrow the search to replace all.", c.warning, 11));
    try rows.append(b.allocator(), try v.rule(b, c));
    return b.listen(try b.key(.{ .string = "buffer-find" }, try b.column(.{ .flex_shrink = 0, .padding = .{ .left = 8, .right = 8 }, .background = c.document, .overflow = .hidden }, rows.items)), .{ .on_capture = b.onInput(inputKeys) });
}
fn button(b: *ui.Ui, c: v.Palette, option: Option, label: []const u8, name: v.Icon, selected: bool) !ui.Element {
    return b.button(.{ .label = label, .tooltip = label, .tooltip_colors = .{ c.panel, c.text, c.line }, .children = &.{try v.icon(b, name, c.muted, 14)}, .on_click = b.onClickWith(toggle, option), .style = v.iconButtonStyle(c, selected) });
}
fn toggle(self: *Shell, _: *ui.Event(ui.Click), cx: *ui.Context(Shell), option: Option) !void {
    switch (option) {
        .close => {
            service.close(self, cx);
            return;
        },
        .replace => self.find.replace = !self.find.replace,
        .case_sensitive => self.find.case_sensitive = !self.find.case_sensitive,
        .whole_word => self.find.whole_word = !self.find.whole_word,
        .regex => self.find.regex = !self.find.regex,
    }
    try service.changed(self, cx);
}
fn inputKeys(self: *Shell, e: *ui.Event(ui.Input), cx: *ui.Context(Shell)) !void {
    if (e.data == .pointer_down) {
        self.active_pane = if (self.find.pane == 1) .secondary else .primary;
        cx.notify();
    }
    if (e.data != .key_down or e.data.key_down.key != .enter) return;
    try service.action(self, cx, if (e.data.key_down.modifiers.shift != self.find.backward) .find_previous else .find_next);
    if (self.vim_find_pending and self.find.queued == null) service.close(self, cx);
    e.preventDefault();
    e.stopPropagation();
    cx.notify();
}
fn fieldKeys(self: *Shell, e: *ui.Event(ui.Input), cx: *ui.Context(Shell), replacement: bool) void {
    if (!self.find.replace or e.data != .key_down or e.data.key_down.key != .tab) return;
    if (e.data.key_down.modifiers.shift != replacement) return;
    self.find.focus_replacement = !replacement;
    self.find.focus +%= 1;
    e.preventDefault();
    e.stopPropagation();
    cx.notify();
}
