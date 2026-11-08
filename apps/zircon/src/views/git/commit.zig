//! Commit message input, appearance, validation and submission live together.
const std = @import("std");
const ui = @import("zircon_ui");
const service = @import("../../services/git.zig");
const shell = @import("../../shell.zig");
const v = @import("../components.zig");
const message_input = @import("commit_message.zig");
const Shell = shell.Shell;
pub const height = message_input.height + 64;

pub const Fields = struct {
    message: ui.Entity(message_input.Message),

    pub fn init(cx: *ui.Context(Shell), a: std.mem.Allocator) !Fields {
        return .{ .message = try cx.createChild(message_input.Message, try message_input.Message.init(a)) };
    }

    pub fn style(self: Fields, cx: *ui.Context(Shell), colors: v.Palette) !void {
        try cx.update(self.message, message_input.Message.setColors, .{colors});
    }
};

pub fn submit(self: *Shell, cx: *ui.Context(Shell)) !void {
    var message: []u8 = undefined;
    try cx.read(self.fields.?.git_commit.message, message_input.Message.copy, .{ self.allocator, &message });
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
    var message: []u8 = &.{};
    if (self.fields) |fields| try b.watch(fields.git_commit.message, message_input.Message.copy, .{ b.allocator(), &message });
    const ready = (staged or tracked or dirty_tracked) and !conflicted and !self.git.updating() and std.mem.trim(u8, message, " \t\r\n").len > 0;
    const editor = if (self.fields) |fields| try f.view(fields.git_commit.message)
        .h_px(message_input.height).shrink_0()
        .id(.named("commit-message"))
        .request_focus(self.git.commit_focus)
        .listeners(.{ .on_capture = b.onInput(onInput) })
        .build() else try f.div().h_px(message_input.height).build();
    const submit_button = f.button(.{
        .label = if (staged) "Commit staged changes" else "Commit tracked changes",
        .on_click = if (ready) b.onClickWith(Shell.onCommand, .git_commit) else null,
    })
        .style(v.buttonStyle(c, ready))
        .background(if (ready) c.primary else c.hover)
        .child(f.text(if (staged) "Commit staged" else "Commit tracked").text_size(12).text_color(if (ready) c.on_primary else c.muted));
    return f.column()
        .h_px(message_input.height + 64).shrink_0().p_px(8).gap_px(12).bg(c.document)
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
    var current: []u8 = undefined;
    try cx.read(fields.git_commit.message, message_input.Message.copy, .{ self.allocator, &current });
    defer self.allocator.free(current);
    if (std.mem.eql(u8, current, submitted)) try cx.update(fields.git_commit.message, message_input.Message.replace, .{""});
}

fn onInput(self: *Shell, event: *ui.Event(ui.Input), cx: *ui.Context(Shell)) !void {
    if (event.data != .key_down) return;
    const key = event.data.key_down;
    if (key.key != .enter or !key.modifiers.command or self.git.updating()) return;
    submit(self, cx) catch |err| try self.reportError(err);
    event.preventDefault();
    event.stopPropagation();
    cx.notify();
}
