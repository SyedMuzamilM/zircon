//! Feature command routing for the Git sidebar, picker and working comparison.
const std = @import("std");
const ui = @import("zircon_ui");
const catalogue = @import("../../commands.zig");
const services_git = @import("../../services/git.zig");
const shell = @import("../../shell.zig");
const field_input = @import("../input.zig");
const commit = @import("commit.zig");
const git_diff_controls = @import("diff_controls.zig");
const git_controls = @import("menus.zig");
const picker = @import("picker.zig");
const Shell = shell.Shell;

pub fn execute(self: *Shell, cx: *ui.Context(Shell), which: catalogue.Command) !bool {
    switch (which) {
        .git_changes => {
            self.git.showWorking();
            if (self.sidebar_visible and self.left_panel == .git_changes) {
                self.sidebar_visible = false;
                return true;
            }
            self.git.stash_view = false;
            services_git.selection_allocator.free(self.git.selected_commit);
            self.git.selected_commit = &.{};
            services_git.selection_allocator.free(self.git.selected_path);
            self.git.selected_path = &.{};
            self.git.combined = true;
            self.showTool(.git_diff);
            self.left_panel = .git_changes;
            self.git.sidebar_scroll.offset = 0;
            self.sidebar_visible = true;
            try services_git.start(self, cx, .all_diff);
        },
        .git_history => {
            self.left_panel = .git_history;
            self.git.sidebar_scroll.offset = 0;
            self.sidebar_visible = true;
            try services_git.start(self, cx, .refresh);
        },
        .git_network_menu => self.git.menu = .network,
        .git_changes_menu => self.git.menu = .changes,
        .git_branches => {
            self.git.needs_metadata = true;
            self.git.picker_index = 0;
            self.git.picker_scroll.offset = 0;
            self.git.menu = .branches;
            try picker.prepare(self, cx, .branches);
            try services_git.start(self, cx, .refresh);
        },
        .git_stashes => {
            self.git.needs_metadata = true;
            self.git.picker_index = 0;
            self.git.picker_scroll.offset = 0;
            services_git.selection_allocator.free(self.git.stash_oid);
            self.git.stash_oid = &.{};
            self.git.menu = .stashes;
            self.git.stash_selected = null;
            try picker.prepare(self, cx, .stashes);
            try services_git.start(self, cx, .refresh);
        },
        .git_fetch_from, .git_push_to => {
            self.git.picker_index = 0;
            self.git.picker_scroll.offset = 0;
            self.git.menu = if (which == .git_fetch_from) .fetch_remote else .push_remote;
            try picker.prepare(self, cx, self.git.menu);
        },
        .git_fetch => try services_git.start(self, cx, .{ .network = .{ .fetch = "" } }),
        .git_pull, .git_pull_rebase => try services_git.start(self, cx, .{ .network = .{ .pull = which == .git_pull_rebase } }),
        .git_push, .git_publish, .git_force_push => {
            const remote = git_controls.defaultRemote(self);
            try services_git.start(self, cx, .{ .network = .{ .push = .{ .remote = if (which == .git_publish) remote else "", .publish = which == .git_publish, .force_with_lease = which == .git_force_push } } });
        },
        .git_stash_all, .git_stash_tracked => try services_git.start(self, cx, .{ .stash_save = which == .git_stash_all }),
        .git_stash_pop, .git_stash_apply, .git_stash_show => try git_controls.stashAction(self, cx, which),
        .git_create_branch => {
            const name = try field_input.read(cx, self.fields.?.git_picker.query, self.allocator);
            defer self.allocator.free(name);
            try services_git.start(self, cx, .{ .switch_branch = .{ .name = std.mem.trim(u8, name, " "), .create = true } });
            self.git.menu = .none;
        },
        .git_refresh => {
            self.git.needs_metadata = true;
            try services_git.start(self, cx, .refresh);
        },
        .git_diff_all => {
            self.git.showWorking();
            self.git.stash_view = false;
            self.git.combined = true;
            services_git.selection_allocator.free(self.git.selected_path);
            services_git.selection_allocator.free(self.git.selected_commit);
            self.git.selected_path = &.{};
            self.git.selected_commit = &.{};
            self.showTool(.git_diff);
            try services_git.start(self, cx, .all_diff);
        },
        .git_collapse_all, .git_unified_view, .git_split_view => try git_diff_controls.command(self, cx, which),
        .git_prepare_commit => {
            self.sidebar_visible = true;
            self.left_panel = .git_changes;
            self.git.commit_focus +%= 1;
        },
        .git_stage => try services_git.start(self, cx, .{ .stage = self.git.selected_path }),
        .git_unstage => try services_git.start(self, cx, .{ .unstage = self.git.selected_path }),
        .git_stage_all => try services_git.start(self, cx, .stage_all),
        .git_unstage_all => try services_git.start(self, cx, .unstage_all),
        .git_commit => try commit.submit(self, cx),
        .git_working_diff, .git_staged_diff => {
            self.git.showWorking();
            self.git.combined = false;
            services_git.selection_allocator.free(self.git.selected_commit);
            self.git.selected_commit = &.{};
            self.showTool(.git_diff);
            try services_git.start(self, cx, .{ .diff = .{ .path = self.git.selected_path, .staged = which == .git_staged_diff } });
        },
        .git_open_file => {
            const absolute = try std.fs.path.join(self.allocator, &.{ if (self.git.root_path.len > 0) self.git.root_path else self.workspace.root_path, self.git.selected_path });
            defer self.allocator.free(absolute);
            try self.openPath(absolute);
        },
        else => return false,
    }
    return true;
}
