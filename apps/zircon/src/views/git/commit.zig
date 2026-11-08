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
    var conflicted = false;
    if (self.git.status) |status| for (status.entries) |entry| {
        staged = staged or entry.staged;
        conflicted = conflicted or entry.conflicted;
    };
    const message = if (self.fields) |fields| try input.text(b, fields.git_commit.message) else "";
    const ready = staged and !conflicted and !self.git.updating() and std.mem.trim(u8, message, " \t\r\n").len > 0;
    const editor = if (self.fields) |fields| try f.view(fields.git_commit.message)
        .h_px(48).shrink_0()
        .id(.named("commit-message"))
        .request_focus(self.git.commit_focus)
        .build() else try f.div().h_px(48).build();
    const submit_button = f.button(.{
        .label = "Commit staged changes",
        .on_click = if (ready) b.onClickWith(Shell.onCommand, .git_commit) else null,
    })
        .style(v.buttonStyle(c, ready))
        .background(if (ready) c.primary else c.hover)
        .child(f.text("Commit staged").text_size(12).text_color(if (ready) c.on_primary else c.muted));
    return f.column()
        .h_px(112).shrink_0().p_px(8).gap_px(12).bg(c.document)
        .child(editor)
        .child(f.row().items_center()
            .child(v.icon(b, .commit, c.muted, 15))
            .child(f.div().grow())
            .child(submit_button))
        .build();
}
