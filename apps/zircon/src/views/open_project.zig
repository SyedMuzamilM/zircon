//! Explicit project-opening modes. Native browsing and typed paths reach the
//! same validation/opening functions; existing workspace buffers stay open.
const std = @import("std");
const ui = @import("zircon_ui");
const commands = @import("../commands.zig");
const projects = @import("../projects.zig");
const shell = @import("../shell.zig");
const v = @import("components.zig");
const field_input = @import("input.zig");
const Shell = shell.Shell;

pub const Fields = struct {
    path: field_input.Handle,
    destination: field_input.Handle,

    pub fn init(cx: *ui.Context(Shell), a: std.mem.Allocator) !Fields {
        return .{
            .path = try field_input.create(cx, a, .{ .placeholder = "Folder path or Git repository URL" }),
            .destination = try field_input.create(cx, a, .{ .placeholder = "Clone destination folder" }),
        };
    }
};

const Kind = projects.Kind;
pub fn render(self: *const Shell, b: *ui.Ui) !ui.Element {
    const c = self.colors;
    var rows: std.ArrayList(ui.Element) = .empty;
    try rows.append(b.allocator(), try v.text(b, "Open a project", c.text, 18));
    inline for (.{ .{ Kind.local_folder, "Local folder", v.Icon.folder_open, "Open a folder from this Mac." }, .{ Kind.git_repository, "Git repository", v.Icon.branch, "Open an existing checkout and detect its repository root." }, .{ Kind.clone, "Clone repository", v.Icon.arrow_down, "Clone an HTTPS/SSH repository into a new local directory." } }) |entry| {
        try rows.append(b.allocator(), try b.fluent().button(.{
            .label = entry[1],
        })
            .flex()
            .h(.{ .px = 64 })
            .shrink_0()
            .items_center()
            .gap_px(12)
            .padding(ui.Insets.all(10))
            .rounded_px(ui.controls.metrics.control_radius)
            .background(if (self.open_kind == entry[0]) c.selected else c.document)
            .hover_background(c.hover)
            .on_click(b.onClickWith(Shell.onOpenKind, entry[0]))
            .children(&.{
                try v.icon(b, entry[2], if (self.open_kind == entry[0]) c.accent else c.muted, 20),
                try b.fluent().div().gap_px(5).grow().min_w(.{ .px = 0 }).overflow_hidden().flex_col().children(.{
                    v.text(b, entry[1], c.text, 14),
                    v.text(b, entry[3], c.muted, 12),
                }).build(),
            }).build());
    }
    if (self.fields) |fields| {
        try rows.append(b.allocator(), try v.text(b, if (self.open_kind == .clone) "Repository URL or absolute local repository path" else "Folder path", c.muted, 12));
        const input = try b.fluent().view(fields.project.path).id(.{ .string = "project-path" }).style(.{
            .height = .{ .px = 34 },
            .flex_grow = 1,
            .min_width = .{ .px = 0 },
        }).build();
        try rows.append(b.allocator(), try b.fluent().div()
            .h(.{ .px = 34 })
            .shrink_0()
            .gap_px(8)
            .items_center()
            .flex()
            .children(if (self.open_kind == .clone) &.{try b.fluent().adopt(input)
                .autofocus()
                .build()} else &.{ try b.fluent().adopt(input)
                .autofocus()
                .build(), try v.actionButton(b, c, .browse_project, "Browse…", false) })
            .build());
        if (self.open_kind == .clone) {
            try rows.append(b.allocator(), try v.text(b, "Destination directory", c.muted, 12));
            try rows.append(b.allocator(), try b.fluent().view(fields.project.destination)
                .id(.{ .string = "clone-destination" })
                .style(.{ .height = .{ .px = 34 }, .flex_shrink = 0 })
                .build());
        }
    }
    try rows.append(b.allocator(), try v.text(b, "Projects open in a new window. Current buffers stay open.", c.muted, 12));
    if (self.status_is_error and self.status.len > 0) try rows.append(b.allocator(), try v.text(b, self.status, c.warning, 12));
    try rows.append(b.allocator(), try b.fluent().div()
        .h(.{ .px = 28 })
        .shrink_0()
        .gap_px(8)
        .justify(.end)
        .flex()
        .children(.{
            v.actionButton(b, c, .dismiss, "Cancel", false),
            b.fluent().button(.{
                .label = if (self.cloning) "Cloning…" else if (self.open_kind == .clone) "Clone and open" else "Open project",
            })
                .style(v.buttonStyle(c, true))
                .on_click(if (self.cloning) null else try b.onClickWith(Shell.onCommand, commands.Command.submit_project)),
        }).build());
    const height: f32 = if (self.open_kind == .clone) 500 else 432;
    const panel = try b.fluent().div()
        .w(.{ .px = @min(600, b.viewport().width - 32) })
        .h(.{ .px = @min(height, b.viewport().height - 32) })
        .padding(ui.Insets.all(20))
        .gap_px(12)
        .background(c.panel)
        .rounded_px(ui.controls.metrics.popover_radius)
        .overflow_hidden()
        .flex_col()
        .children(rows.items)
        .id(.{ .string = "dialog" })
        .build();
    return b.fluent().div()
        .items_center()
        .justify_center()
        .background(.{ .r = 0, .g = 0, .b = 0, .a = 0.35 })
        .stack()
        .children(.{panel})
        .modal()
        .build();
}

pub fn command(self: *Shell, cx: *ui.Context(Shell), which: commands.Command) !bool {
    switch (which) {
        .open_project => {
            self.overlay = .open_project;
            self.open_kind = .local_folder;
            try field_input.reset(cx, self.fields.?.project.path, "", .{ .placeholder = "Folder path or Git repository URL" });
        },
        .browse_project => {
            if (try (try cx.app.window(self.window.?)).surface.?.choosePath(self.allocator, .folder)) |path| {
                defer self.allocator.free(path);
                try field_input.reset(cx, self.fields.?.project.path, path, .{ .placeholder = "Folder path" });
            }
        },
        .submit_project => {
            const path = try field_input.read(cx, self.fields.?.project.path, self.allocator);
            defer self.allocator.free(path);
            const requested = std.mem.trim(u8, path, " \t");
            if (requested.len == 0) return error.InvalidPath;
            if (self.open_kind == .clone) {
                const destination = try field_input.read(cx, self.fields.?.project.destination, self.allocator);
                defer self.allocator.free(destination);
                if (std.mem.trim(u8, destination, " \t").len == 0) return error.InvalidPath;
                try projects.clone(self, cx, requested, destination);
            } else _ = try projects.open(self, cx, requested, self.open_kind);
        },
        else => return false,
    }
    return true;
}
