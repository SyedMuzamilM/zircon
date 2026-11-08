//! Immutable commit context above the historical patch, independent of the
//! editable worktree comparison and its staging toolbar.
const std = @import("std");
const ui = @import("zircon_ui");
const Shell = @import("../shell.zig").Shell;
const v = @import("components.zig");
pub fn render(self: *const Shell, b: *ui.Ui) !ui.Element {
    const c = self.colors;
    var rows: std.ArrayList(ui.Element) = .empty;
    var subject: []const u8 = "Commit";
    for (self.git.history_tabs.items) |tab| if (std.mem.eql(u8, tab.oid, self.git.selected_commit)) {
        subject = tab.subject;
        break;
    };
    try rows.append(b.allocator(), try v.text(b, subject, c.text, 16));
    for (self.git.commits) |commit| if (std.mem.eql(u8, commit.oid, self.git.selected_commit)) {
        try rows.append(b.allocator(), try v.text(b, try std.fmt.allocPrint(b.allocator(), "{s} <{s}>", .{ commit.author, commit.email }), c.muted, 12));
        break;
    };
    try rows.append(b.allocator(), try v.text(b, self.git.selected_commit, c.muted, 11));
    var body = std.mem.splitScalar(u8, self.git.commit_message, '\n');
    _ = body.next();
    var count: usize = 0;
    while (body.next()) |line| {
        if (line.len == 0 and count == 0) continue;
        if (count == 4) break;
        try rows.append(b.allocator(), try v.text(b, line[0..@min(line.len, 1000)], c.text, 12));
        count += 1;
    }
    return b.key(.{ .string = "commit-details" }, try b.column(.{ .flex_shrink = 0, .gap = 6, .padding = ui.Insets.all(14), .background = c.sidebar, .overflow = .hidden }, rows.items));
}
