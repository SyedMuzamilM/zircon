//! Changed-file rows, staging targets, folder disclosure and count badges.
const std = @import("std");
const git = @import("zircon_git");
const ui = @import("zircon_ui");
const tree = @import("../../models/git_tree.zig");
const service = @import("../../services/git.zig");
const shell = @import("../../shell.zig");
const v = @import("../components.zig");
const Shell = shell.Shell;
pub const row_height: f32 = 26;
const Target = struct { index: u32, generation: u64 };
const DirectoryTarget = struct { target: Target, prefix_len: u32 };

pub fn renderRow(self: *const Shell, b: *ui.Ui, entries: []const git.Entry, row: tree.Row) !ui.Element {
    const c = self.colors;
    switch (row) {
        .section => |section| {
            const name: []const u8 = switch (section.group) {
                .tracked => "Tracked",
                .untracked => "Untracked",
                .conflicts => "Conflicts",
            };
            return b.fluent().button(.{
                .label = name,
            })
                .flex()
                .h(.{ .px = row_height })
                .shrink_0()
                .gap_px(5)
                .items_center()
                .padding(.{ .left = 10, .right = 8 })
                .hover_background(c.hover)
                .on_click(b.onClickWith(toggleSection, section.group))
                .children(&.{
                    try v.icon(b, if (self.git.tree.sections[@backingInt(section.group)]) .chevron_right else .chevron_down, c.muted, 12),
                    try v.text(b, name, c.muted, 12),
                    try v.text(b, try std.fmt.allocPrint(b.allocator(), "({d})", .{section.count}), c.muted, 11),
                }).id(.{ .number = @backingInt(section.group) }).build();
        },
        .directory => |directory| return b.fluent().button(.{
            .label = directory.path,
        })
            .flex()
            .h(.{ .px = row_height })
            .gap_px(5)
            .items_center()
            .shrink_0()
            .padding(.{ .left = 12 + @as(f32, @floatFromInt(directory.depth)) * 14 })
            .hover_background(c.hover)
            .overflow_hidden()
            .on_click(b.onClickWith(toggleDirectory, DirectoryTarget{ .target = .{ .index = directory.entry, .generation = self.git.status_generation }, .prefix_len = @intCast(directory.path.len) }))
            .children(&.{
                try v.icon(b, if (self.git.tree.directories.contains(directory.path)) .chevron_right else .chevron_down, c.muted, 12),
                try v.icon(b, .folder, c.muted, 15),
                try v.text(b, directory.label, c.muted, 12),
            })
            .id(.{ .string = try std.fmt.allocPrint(b.allocator(), "{s}:{s}", .{ @tagName(directory.group), directory.path }) })
            .build(),
        .file => |file| {
            const entry = entries[file.index];
            const color = v.gitFileColor(c, entry);
            const selected = std.mem.eql(u8, self.git.selected_path, entry.path);
            var style = v.iconButtonStyle(c, false);
            const name = try std.fmt.allocPrint(b.allocator(), "{s} {s}", .{ if (entry.staged and !entry.unstaged) "Unstage" else "Stage", entry.path });
            const staging = try b.fluent().button(.{
                .label = name,
                .tooltip = name,
                .tooltip_colors = .{ c.panel, c.text, c.line },
            })
                .style(style)
                .on_click(b.onClickWith(stage, Target{ .index = file.index, .generation = self.git.status_generation }))
                .children(&.{
                    try v.icon(b, if (entry.staged and entry.unstaged) .square_mixed else if (entry.staged) .square_checked else .square, if (entry.staged) c.accent else c.muted, 16),
                }).build();
            style = .{
                .direction = .row,
                .height = .{ .px = row_height },
                .flex_grow = 1,
                .min_width = .{ .px = 0 },
                .gap = 6,
                .align_items = .center,
                .padding = .{ .left = 26 + @as(f32, @floatFromInt(file.depth)) * 14 },
                .overflow = .hidden,
            };
            const parent = if (self.git.tree.mode == .list) std.fs.path.dirname(entry.path) orelse "" else "";
            const target = try b.fluent().button(.{
                .label = entry.path,
            })
                .style(style)
                .on_click(b.onClickWith(openFile, Target{ .index = file.index, .generation = self.git.status_generation }))
                .children(&.{
                    try v.fileGlyph(self, b, entry.path, false, false, 15),
                    try b.fluent().adopt(try v.text(b, std.fs.path.basename(entry.path), color, 12)).style(.{
                        .flex_grow = 1,
                        .min_width = .{ .px = 0 },
                        .text = .{ .size = 12, .color = color },
                        .overflow = .hidden,
                    }).build(),
                    try v.text(b, parent, c.muted, 11),
                    try changeBadges(b, c, entry),
                }).build();
            return b.fluent().div()
                .h(.{ .px = row_height })
                .shrink_0()
                .items_center()
                .padding(.{ .right = 6 })
                .background(if (selected) c.selected else null)
                .hover_background(c.hover)
                .flex()
                .children(.{ target, staging })
                .id(.{ .string = entry.path })
                .build();
        },
    }
}

fn toggleSection(self: *Shell, _: *ui.Event(ui.Click), cx: *ui.Context(Shell), group: tree.Group) void {
    const index = @backingInt(group);
    self.git.tree.sections[index] = !self.git.tree.sections[index];
    self.git.sidebar_scroll.offset = 0;
    cx.notify();
}

fn resolve(self: *const Shell, target: Target) ?git.Entry {
    if (target.generation != self.git.status_generation) return null;
    const status = self.git.status orelse return null;
    return if (target.index < status.entries.len) status.entries[target.index] else null;
}

fn toggleDirectory(self: *Shell, _: *ui.Event(ui.Click), cx: *ui.Context(Shell), directory: DirectoryTarget) !void {
    const entry = resolve(self, directory.target) orelse return;
    if (directory.prefix_len >= entry.path.len or entry.path[directory.prefix_len] != '/') return;
    try self.git.tree.toggleDirectory(std.heap.page_allocator, entry.path[0..directory.prefix_len]);
    self.git.sidebar_scroll.offset = 0;
    cx.notify();
}

fn stage(self: *Shell, _: *ui.Event(ui.Click), cx: *ui.Context(Shell), target: Target) !void {
    const entry = resolve(self, target) orelse return;
    service.start(self, cx, if (entry.staged and !entry.unstaged) .{ .unstage = entry.path } else .{ .stage = entry.path }) catch |err| try self.reportError(err);
    cx.notify();
}

fn openFile(self: *Shell, e: *ui.Event(ui.Click), cx: *ui.Context(Shell), target: Target) !void {
    _ = resolve(self, target) orelse return;
    try self.onGitFile(e, cx, target.index);
}

fn changeBadges(b: *ui.Ui, c: v.Palette, entry: git.Entry) !ui.Element {
    var badges: std.ArrayList(ui.Element) = .empty;
    if (entry.stats) |stats| {
        if (stats.binary) return badge(b, "Binary", c.muted);
        if (stats.added > 0) try badges.append(b.allocator(), try badge(b, try std.fmt.allocPrint(b.allocator(), "+{d}", .{stats.added}), c.added));
        if (stats.deleted > 0) try badges.append(b.allocator(), try badge(b, try std.fmt.allocPrint(b.allocator(), "−{d}", .{stats.deleted}), c.deleted));
    } else try badges.append(b.allocator(), try badge(b, "…", c.muted));
    return b.fluent().div().gap_px(3).items_center().shrink_0().flex().children(badges.items).build();
}

fn badge(b: *ui.Ui, label: []const u8, color: ui.Color) !ui.Element {
    return b.fluent().div()
        .h(.{ .px = 18 })
        .items_center()
        .shrink_0()
        .flex()
        .children(.{v.text(b, label, color, 11)})
        .build();
}
