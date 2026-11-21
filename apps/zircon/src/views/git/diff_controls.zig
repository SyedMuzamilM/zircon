//! Diff controls address a file/hunk in the installed patch generation. Source
//! navigation resolves against the discovered repository, including subfolders.
const std = @import("std");
const git = @import("zircon_git");
const zircon_git_ui = @import("zircon_git_ui");
const ui = @import("zircon_ui");
const commands = @import("../../commands.zig");
const git_selection = @import("../../git_selection.zig");
const services_git = @import("../../services/git.zig");
const shell = @import("../../shell.zig");
const v = @import("../components.zig");
const layout = zircon_git_ui.layout;
const Shell = shell.Shell;
const Command = commands.Command;
const a = std.heap.page_allocator;
pub const Target = struct { file: usize, generation: u64 };

const ContextTarget = struct { hunk: usize, generation: u64, direction: layout.Direction };
pub fn hunkHeader(self: *const Shell, b: *ui.Ui, index: usize, direction: layout.Direction) !ui.Element {
    const diff = self.git.diff.?;
    const hunk = diff.hunks[index];
    const c = self.colors;
    const start = if (hunk.new_count == 0) hunk.new_start else hunk.new_start -| 1;
    const previous_end = if (index > 0 and std.mem.eql(u8, diff.hunks[index - 1].path, hunk.path)) (diff.hunks[index - 1].new_start -| 1) + diff.hunks[index - 1].new_count else 0;
    var total: usize = start + hunk.new_count;
    for (diff.context_sources) |source| if (std.mem.eql(u8, source.path, hunk.path)) {
        total = source.lines.len;
        break;
    };
    const above = start > previous_end;
    if (index + 1 < diff.hunks.len and std.mem.eql(u8, diff.hunks[index + 1].path, hunk.path)) total = @min(total, layout.hunkStart(diff.hunks[index + 1]));
    const below = start + hunk.new_count < total;
    var children: std.ArrayList(ui.Element) = .empty;
    const show = if (direction == .up) above else below;
    if (show) {
        const title = if (direction == .up) "Expand context above" else "Expand context below";
        try children.append(b.allocator(), try b.fluent().button(.{
            .label = try std.fmt.allocPrint(b.allocator(), "{s} {s}", .{ title, hunk.path }),
            .tooltip = if (direction == .up) "Expand 5 lines above" else "Expand 5 lines below",
        })
            .w_px(28).h_px(24).items_center().justify_center().hover_background(c.hover)
            .on_click(b.onClickWith(expand, ContextTarget{ .hunk = index, .generation = self.git.diff_generation, .direction = direction }))
            .child(v.icon(b, if (direction == .up) .expand_up else .expand_down, c.muted, 16))
            .id(.{ .string = try std.fmt.allocPrint(b.allocator(), "git-context:{s}:{s}:{d}", .{ @tagName(direction), hunk.path, if (hunk.original) |original| original.old_start else hunk.old_start }) })
            .build());
    }
    return b.fluent().row().h_px(layout.context_height).shrink_0().items_center().padding(.{ .left = 8 }).background(c.document).children(children.items).build();
}

fn expand(self: *Shell, _: *ui.Event(ui.Click), cx: *ui.Context(Shell), target: ContextTarget) !void {
    if (target.generation != self.git.diff_generation) return;
    const diff = if (self.git.diff) |*value| value else return;
    if (target.hunk >= diff.hunks.len) return;
    try self.git.diff_view.expandContext(a, diff.hunks[target.hunk], target.direction);
    const path = diff.hunks[target.hunk].path;
    try zircon_git_ui.context.applyFile(diff, &self.git.diff_view, path);
    if (self.git.projection) |*projection| try projection.updateFile(diff.*, path);
    self.git.diff_generation +%= 1;
    try services_git.expandEditable(self, diff.*, path);
    try git_selection.rebuild(self);
    cx.notify();
}

fn resolve(self: *const Shell, target: Target) ?layout.File {
    if (target.generation != self.git.diff_generation) return null;
    const projection = self.git.projection orelse return null;
    return if (target.file < projection.files.len) projection.files[target.file] else null;
}

pub fn selectFile(self: *Shell, file: layout.File) !void {
    const owned = try services_git.selection_allocator.dupe(u8, file.path);
    services_git.selection_allocator.free(self.git.selected_path);
    self.git.selected_path = owned;
    if (self.git.diff_view.active_hunk == null or self.git.diff_view.active_hunk.? < file.first_hunk or self.git.diff_view.active_hunk.? >= file.end_hunk) self.git.diff_view.active_hunk = file.first_hunk;
}

fn toggle(self: *Shell, _: *ui.Event(ui.Click), cx: *ui.Context(Shell), target: Target) !void {
    const file = resolve(self, target) orelse return;
    try selectFile(self, file);
    try self.git.diff_view.toggle(a, file.path);
    try git_selection.rebuild(self);
    clampScroll(self);
    cx.notify();
}

fn open(self: *Shell, _: *ui.Event(ui.Click), cx: *ui.Context(Shell), target: Target) !void {
    const file = resolve(self, target) orelse return;
    try selectFile(self, file);
    const root = if (self.git.root_path.len > 0) self.git.root_path else self.workspace.root_path;
    const absolute = try std.fs.path.join(self.allocator, &.{ root, file.path });
    defer self.allocator.free(absolute);
    try self.openPath(absolute);
    cx.notify();
}

fn stage(self: *Shell, _: *ui.Event(ui.Click), cx: *ui.Context(Shell), target: Target) !void {
    const file = resolve(self, target) orelse return;
    if (self.git.selected_commit.len > 0) return;
    const entry = statusFor(self, file.path) orelse return;
    try selectFile(self, file);
    try services_git.start(self, cx, if (entry.staged and !entry.unstaged) .{ .unstage = file.path } else .{ .stage = file.path });
}

fn statusFor(self: *const Shell, path: []const u8) ?git.Entry {
    if (self.git.status) |status| for (status.entries) |entry| if (std.mem.eql(u8, entry.path, path)) return entry;
    return null;
}

pub fn header(self: *const Shell, b: *ui.Ui, file: layout.File, index: usize) !ui.Element {
    const c = self.colors;
    const target: Target = .{ .file = index, .generation = self.git.diff_generation };
    const collapsed = self.git.diff_view.collapsed.contains(file.path);
    const active = std.mem.eql(u8, self.git.selected_path, file.path);
    const entry = if (self.git.selected_commit.len == 0) statusFor(self, file.path) else null;
    var children: std.ArrayList(ui.Element) = .empty;
    try children.append(b.allocator(), try b.fluent().button(.{
        .label = try std.fmt.allocPrint(b.allocator(), "{s} {s}", .{ if (collapsed) "Expand" else "Collapse", file.path }),
    }).style(v.iconButtonStyle(c, false)).on_click(b.onClickWith(toggle, target)).children(&.{
        try v.icon(b, if (collapsed) .chevron_right else .chevron_down, c.muted, 14),
    }).build());
    if (entry) |value| try children.append(b.allocator(), try b.fluent().button(.{
        .label = try std.fmt.allocPrint(b.allocator(), "{s} {s}", .{ if (value.staged and !value.unstaged) "Unstage" else "Stage", file.path }),
        .tooltip = "Stage saved file changes",
    })
        .style(v.iconButtonStyle(c, false))
        .on_click(if (self.git.updating()) null else try b.onClickWith(stage, target))
        .children(&.{
            try v.icon(b, if (value.staged and value.unstaged) .square_mixed else if (value.staged) .square_checked else .square, c.muted, 16),
        }).build());
    try children.appendSlice(b.allocator(), &.{ try v.fileGlyph(self, b, file.path, false, false, 15), try v.text(b, std.fs.path.basename(file.path), c.text, 13) });
    if (self.git.selected_commit.len == 0 and !self.git.staged_diff and !self.git.stash_view) {
        const absolute = try std.fs.path.resolve(b.allocator(), &.{ if (self.git.root_path.len > 0) self.git.root_path else self.workspace.root_path, file.path });
        for (self.git.editing.views.items) |view| {
            const record = try self.workspace.getConst(view.document);
            if (record.path != null and std.mem.eql(u8, record.path.?, absolute) and record.dirty()) {
                try children.append(b.allocator(), try b.fluent().div().w_px(6).h_px(6).shrink_0().rounded_px(3).background(c.accent)
                    .id(.{ .string = try std.fmt.allocPrint(b.allocator(), "git-dirty:{s}", .{file.path}) }).build());
                break;
            }
        }
    }
    try children.appendSlice(b.allocator(), &.{ try b.fluent().adopt(try v.text(b, std.fs.path.dirname(file.path) orelse "", c.muted, 12))
        .style(.{
            .flex_grow = 1,
            .flex_shrink = 1,
            .min_width = .{ .px = 0 },
            .text = .{ .size = 12, .color = c.muted },
            .overflow = .hidden,
        })
        .build(), try v.text(b, try std.fmt.allocPrint(b.allocator(), "+{d}", .{file.added}), c.added, 12), try v.text(b, try std.fmt.allocPrint(b.allocator(), "−{d}", .{file.deleted}), c.deleted, 12) });
    if (active or self.git.diff_view.hover_file == index) try children.append(b.allocator(), try b.fluent().button(.{
        .label = try std.fmt.allocPrint(b.allocator(), "Open File {s}", .{file.path}),
    })
        .style(v.buttonStyle(c, false))
        .on_click(b.onClickWith(open, target))
        .children(&.{try v.text(b, "Open File", c.text, 12)})
        .build());
    const inner = try b.fluent().div()
        .h(.{ .px = 36 })
        .padding(.{ .left = 7, .right = 10 })
        .items_center()
        .gap_px(8)
        .rounded_px(v.metrics.control_radius)
        .background(if (active) c.selected else c.sidebar)
        .overflow_hidden()
        .flex()
        .children(children.items)
        .build();
    return b.fluent().div()
        .h(.{ .px = layout.file_height })
        .background(c.document)
        .padding(.{ .top = 5, .bottom = 5, .left = 6, .right = 6 })
        .shrink_0()
        .flex_col()
        .children(.{inner})
        .id(.{ .string = try std.fmt.allocPrint(b.allocator(), "diff-file:{s}", .{file.path}) })
        .build();
}

pub fn command(self: *Shell, cx: *ui.Context(Shell), which: Command) !void {
    const projection = self.git.projection orelse return;
    if (which == .git_collapse_all) {
        var all = projection.files.len > 0;
        for (projection.files) |file| all = all and self.git.diff_view.collapsed.contains(file.path);
        if (all) self.git.diff_view.expandAll(a) else for (projection.files) |file| {
            if (!self.git.diff_view.collapsed.contains(file.path)) try self.git.diff_view.toggle(a, file.path);
        }
        self.git.diff_scroll.offset = 0;
    } else {
        self.git.diff_view.mode = if (which == .git_split_view) .split else .unified;
        if (self.git.diff_view.active_hunk) |hunk| self.git.diff_scroll.offset = projection.hunkOffset(&self.git.diff_view, hunk, self.editor_options.font_size * self.editor_options.line_height) orelse 0;
    }
    clampScroll(self);
    try git_selection.rebuild(self);
    cx.notify();
}

pub fn navigate(self: *Shell, cx: *ui.Context(Shell), which: Command) !void {
    const diff = self.git.diff orelse return;
    const projection = self.git.projection orelse return;
    if (diff.hunks.len == 0) return;
    const active = self.git.diff_view.active_hunk;
    const index = if (which == .git_toggle_hunk) active orelse 0 else if (active) |i| (if (which == .git_previous_change) (i + diff.hunks.len - 1) % diff.hunks.len else (i + 1) % diff.hunks.len) else if (which == .git_previous_change) diff.hunks.len - 1 else 0;
    self.git.diff_view.active_hunk = index;
    for (projection.files) |file| if (index >= file.first_hunk and index < file.end_hunk) {
        try selectFile(self, file);
        if (which == .git_toggle_hunk or self.git.diff_view.collapsed.contains(file.path)) try self.git.diff_view.toggle(a, file.path);
        break;
    };
    self.git.diff_scroll.offset = projection.hunkOffset(&self.git.diff_view, index, self.editor_options.font_size * self.editor_options.line_height) orelse 0;
    try git_selection.rebuild(self);
    cx.notify();
}

fn clampScroll(self: *Shell) void {
    self.git.diff_scroll.offset = @min(self.git.diff_scroll.offset, @max(0, if (self.git.projection) |projection| projection.contentHeight(&self.git.diff_view, self.editor_options.font_size * self.editor_options.line_height) else 0 - 40));
}
/// Capture uses the same file heights as rendering, so descendants and blank
/// header padding have the same hover/active behavior as the visible surface.
pub fn input(self: *Shell, e: *ui.Event(ui.Input), cx: *ui.Context(Shell)) !void {
    if (e.data == .scroll) {
        self.git.editing.horizontal = @max(0, self.git.editing.horizontal - e.data.scroll.x);
        const height = if (self.git.projection) |projection| projection.contentHeight(&self.git.diff_view, self.editor_options.font_size * self.editor_options.line_height) else 0;
        self.git.diff_scroll.wheel(e.data.scroll.y, height, e.bounds.height);
        e.preventDefault();
        e.stopPropagation();
        cx.notify();
        return;
    }
    if (e.data != .pointer_move and e.data != .pointer_down and e.data != .pointer_leave) return;
    const projection = self.git.projection orelse return;
    const point: ?ui.Point = switch (e.data) {
        .pointer_move, .pointer_down => |pointer| pointer.position,
        else => null,
    };
    var hovered: ?usize = null;
    if (point) |p| {
        const y = p.y - e.bounds.y + self.git.diff_scroll.offset;
        var top: f32 = 0;
        for (projection.files, 0..) |file, index| {
            const height = file.height(&self.git.diff_view, self.editor_options.font_size * self.editor_options.line_height);
            if (y >= top and y < top + height) {
                if (y < top + layout.file_height) hovered = index;
                if (e.data == .pointer_down) {
                    try selectFile(self, file);
                    cx.notify();
                }
                break;
            }
            top += height;
        }
    }
    if (self.git.diff_view.hover_file != hovered) {
        self.git.diff_view.hover_file = hovered;
        cx.notify();
    }
}
