//! Repository menus and searchable branch, stash and remote pickers share the
//! command system. Payloads bind to the installed repository generation.
const std = @import("std");
const ui = @import("zircon_ui");
const catalogue = @import("../commands.zig");
const service = @import("../services/git.zig");
const shell = @import("../shell.zig");
const v = @import("components.zig");
const picker = @import("popovers/git_picker.zig");
const Shell = shell.Shell;
const Command = catalogue.Command;
const Target = struct { index: u32, generation: u64 };
pub const defaultRemote = picker.defaultRemote;
pub const hasUpstream = picker.hasUpstream;
pub const stashAction = picker.stashAction;
pub const input = picker.input;
fn dismiss(self: *Shell, e: *ui.Event(ui.Input), cx: *ui.Context(Shell)) void {
    if (e.data == .pointer_down and e.phase == .target) {
        self.git.menu = .none;
        e.preventDefault();
        cx.notify();
    }
}
pub fn commandRow(self: *const Shell, b: *ui.Ui, command: Command, label: []const u8, enabled: bool) !ui.Element {
    if (enabled and !self.git.updating()) return v.menuRow(b, self.colors, command, label, try self.key_bindings.shortcut(b.allocator(), command), false);
    return b.fluent().div().h(.{ .px = 30 }).shrink_0().items_center().padding(.{ .left = 10, .right = 10 }).opacity(0.45).flex().children(.{v.text(b, label, self.colors.muted, 13)}).build();
}
pub fn render(self: *const Shell, b: *ui.Ui) !ui.Element {
    const c = self.colors;
    var rows: std.ArrayList(ui.Element) = .empty;
    const refs = self.git.references;
    const remote = refs != null and refs.?.remotes.len > 0;
    const detached = if (self.git.status) |status| status.detached else true;
    const stash = refs != null and refs.?.stashes.len > 0;
    switch (self.git.menu) {
        .network => {
            inline for (.{ .{ Command.git_fetch, "Fetch", true }, .{ Command.git_fetch_from, "Fetch from…", true }, .{ Command.git_pull, "Pull", false }, .{ Command.git_pull_rebase, "Pull with rebase", false } }) |item| try rows.append(b.allocator(), try commandRow(self, b, item[0], item[1], remote and (item[2] or hasUpstream(self))));
            try rows.append(b.allocator(), try v.rule(b, c));
            try rows.append(b.allocator(), try commandRow(self, b, .git_push, "Push", hasUpstream(self) and !detached));
            try rows.append(b.allocator(), try commandRow(self, b, .git_push_to, "Push to…", remote and !detached));
            try rows.append(b.allocator(), try commandRow(self, b, .git_publish, "Publish branch", defaultRemote(self).len > 0 and !detached));
            try rows.append(b.allocator(), try commandRow(self, b, .git_force_push, "Force push with lease", hasUpstream(self) and !detached));
        },
        .changes => {
            const has_changes = self.git.status != null and self.git.status.?.entries.len > 0;
            try rows.append(b.allocator(), try commandRow(self, b, .git_stage_all, "Stage all", has_changes));
            try rows.append(b.allocator(), try commandRow(self, b, .git_unstage_all, "Unstage all", has_changes));
            try rows.append(b.allocator(), try v.rule(b, c));
            try rows.append(b.allocator(), try commandRow(self, b, .git_stash_all, "Stash all", has_changes));
            try rows.append(b.allocator(), try commandRow(self, b, .git_stash_tracked, "Stash tracked", has_changes));
            try rows.append(b.allocator(), try commandRow(self, b, .git_stash_pop, "Pop latest stash", stash));
            try rows.append(b.allocator(), try commandRow(self, b, .git_stashes, "View stashes…", stash));
        },
        .branches, .stashes, .fetch_remote, .push_remote => try picker.append(self, b, &rows),
        .none => unreachable,
    }
    if (self.status_is_error) try rows.append(b.allocator(), try v.text(b, self.status, c.warning, 12));
    const searchable = self.git.menu == .branches or self.git.menu == .stashes or self.git.menu == .fetch_remote or self.git.menu == .push_remote;
    const height = @min(if (searchable) @as(f32, 360) else @as(f32, @floatFromInt(rows.items.len)) * 30 + 12, b.viewport().height - 90);
    const placement = v.popoverBounds(b.viewport(), self.git_anchor, .{ .width = if (searchable) 440 else 300, .height = height });
    const popup = try b.fluent().adopt(try v.floatingPanel(b, c, .{ .width = placement.width, .height = placement.height }, ui.Insets.all(if (searchable) 12 else 6), if (searchable) 8 else 0, rows.items)).id(.{ .string = "git-controls" }).build();
    return b.fluent().div().padding(.{ .top = placement.y, .left = placement.x }).items(.start).stack().children(.{popup}).listeners(.{ .on_input = b.onInput(dismiss) }).modal().build();
}
