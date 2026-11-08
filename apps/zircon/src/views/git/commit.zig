//! Commit message input, appearance, validation and submission live together.
const std = @import("std");
const ui = @import("zircon_ui");
const service = @import("../../services/git.zig");
const shell = @import("../../shell.zig");
const v = @import("../components.zig");
const input = @import("../input.zig");
const Shell = shell.Shell;

pub const Fields = struct {
    message: input.Handle,

    pub fn init(cx: *ui.Context(Shell), a: std.mem.Allocator) !Fields {
        return .{ .message = try input.create(cx, a, .{
            .placeholder = "Commit message…",
            .borderless = true,
        }) };
    }

    pub fn style(self: Fields, cx: *ui.Context(Shell), colors: v.Palette) !void {
        try input.appearance(cx, self.message, v.inputAppearance(colors), true);
    }
};

pub fn submit(self: *Shell, cx: *ui.Context(Shell)) !void {
    const message = try input.read(cx, self.fields.?.git_commit.message, self.allocator);
    defer self.allocator.free(message);
    if (std.mem.trim(u8, message, " \t\r\n").len == 0) return error.EmptyCommitMessage;
    try service.start(self, cx, .{ .commit = message });
}

pub fn render(self: *const Shell, b: *ui.Ui) !ui.Element {
    const f = b.fluent();
    const c = self.colors;
    var staged = false;
    var tracked = false;
    var dirty_tracked = false;
    var conflicted = false;
    if (self.git.status) |status| for (status.entries) |entry| {
        staged = staged or entry.staged;
        conflicted = conflicted or entry.conflicted;
        tracked = tracked or (entry.index != .untracked and entry.worktree != .untracked and entry.index != .added and entry.worktree != .added);
    };
    // A clean tracked file can be dirty only in its buffer and absent from status.
    for (self.tabs.items) |tab| {
        const record = self.workspace.getConst(tab.document) catch continue;
        if (!record.dirty() or record.path == null or self.git.root_path.len == 0) continue;
        const path = record.path.?;
        const root = std.mem.trimEnd(u8, self.git.root_path, "/");
        if (path.len <= root.len or !std.mem.startsWith(u8, path, root) or path[root.len] != '/') continue;
        const entry = self.git.entryForPath(path);
        if (entry == null or (entry.?.index != .untracked and entry.?.worktree != .untracked)) dirty_tracked = true;
    }
    const message = if (self.fields) |fields| try input.text(b, fields.git_commit.message) else "";
    const ready = (staged or tracked or dirty_tracked) and !conflicted and !self.git.updating() and std.mem.trim(u8, message, " \t\r\n").len > 0;
    const editor = if (self.fields) |fields| try f.view(fields.git_commit.message)
        .h_px(48).shrink_0()
        .id(.named("commit-message"))
        .request_focus(self.git.commit_focus)
        .build() else try f.div().h_px(48).build();
    const submit_button = f.button(.{
        .label = if (staged) "Commit staged changes" else "Commit tracked changes",
        .on_click = if (ready) b.onClickWith(Shell.onCommand, .git_commit) else null,
    })
        .style(v.buttonStyle(c, ready))
        .background(if (ready) c.primary else c.hover)
        .child(f.text(if (staged) "Commit staged" else "Commit tracked").text_size(12).text_color(if (ready) c.on_primary else c.muted));
    return f.column()
        .h_px(112).shrink_0().p_px(8).gap_px(12).bg(c.document)
        .child(editor)
        .child(f.row().items_center()
            .child(v.icon(b, .commit, c.muted, 15))
            .child(f.div().grow())
            .child(submit_button))
        .build();
}

/// Only clear the submitted text after success; retain any message typed while
/// the operation was running and retain the original message on failure.
pub fn completed(self: *Shell, cx: *ui.Context(Shell), submitted: []const u8) !void {
    const fields = self.fields orelse return;
    const current = try input.read(cx, fields.git_commit.message, self.allocator);
    defer self.allocator.free(current);
    if (std.mem.eql(u8, current, submitted)) try input.reset(cx, fields.git_commit.message, "", .{ .placeholder = "Commit message…", .borderless = true });
}
