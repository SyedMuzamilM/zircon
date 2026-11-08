//! Platform application menus share the existing command dispatcher.
const ui = @import("zircon_ui");
const commands = @import("commands.zig");
const Command = commands.Command;
fn item(label: []const u8, command: Command, key: []const u8) ui.MenuItem {
    return .{ .label = label, .action = @backingInt(command), .key = key };
}
fn shifted(label: []const u8, command: Command, key: []const u8) ui.MenuItem {
    var result = item(label, command, key);
    result.modifiers.shift = true;
    return result;
}
pub const groups = [_]ui.Menu{
    .{ .label = "Zircon", .items = &.{ item("Settings…", .settings, ","), item("Extensions", .extensions, ""), .{}, item("Quit Zircon", .quit, "q") } },
    .{ .label = "File", .items = &.{ item("New File", .new_file, "n"), item("Open File…", .open_path, "o"), shifted("Open Folder…", .open_project, "o"), item("Open Recent…", .recent_projects, ""), .{}, item("Save", .save, "s"), shifted("Save As…", .save_as, "s"), .{}, item("Close Tab", .close_tab, "w") } },
    .{ .label = "Edit", .items = &.{ item("Undo", .undo, "z"), shifted("Redo", .redo, "z"), .{}, item("Cut", .cut, "x"), item("Copy", .copy, "c"), item("Paste", .paste, "v"), .{}, item("Find", .find, "f"), item("Find and Replace", .replace, ""), item("Toggle Line Comment", .toggle_comment, "/") } },
    .{ .label = "Selection", .items = &.{ item("Select All", .select_all, "a"), item("Delete Line", .delete_line, "") } },
    .{ .label = "View", .items = &.{ shifted("Command Palette", .palette, "p"), item("Project Panel", .toggle_sidebar, "b"), item("Git Panel", .git_changes, ""), item("Word Wrap", .toggle_soft_wrap, ""), .{}, item("Split Right", .split_right, ""), item("Split Down", .split_down, ""), item("Close Split", .close_split, ""), .{}, item("Increase Font Size", .zoom_in, ""), item("Decrease Font Size", .zoom_out, "") } },
    .{ .label = "Go", .items = &.{ item("Go to File…", .quick_open, "p"), shifted("Search Project", .project_search, "f"), .{}, item("Next Change", .git_next_change, ""), item("Previous Change", .git_previous_change, "") } },
    .{ .label = "Git", .items = &.{ item("Uncommitted Changes", .git_diff_all, ""), item("Commit History", .git_history, ""), item("Branches…", .git_branches, ""), .{}, item("Stage All", .git_stage_all, ""), item("Unstage All", .git_unstage_all, ""), item("Commit…", .git_prepare_commit, ""), .{}, item("Unified Diff", .git_unified_view, ""), item("Split Diff", .git_split_view, ""), item("Refresh", .git_refresh, "") } },
    .{ .label = "Terminal", .items = &.{ item("Toggle Terminal", .toggle_terminal, ""), item("New Terminal", .new_terminal, ""), .{}, item("Dock at Bottom", .terminal_bottom, ""), item("Dock at Right", .terminal_right, "") } },
    .{ .label = "Window", .items = &.{item("Editor Layout", .layout_classic, "")} },
    .{ .label = "Help", .items = &.{ item("Command Palette", .palette, ""), item("Language Server Status", .language_servers, "") } },
};
