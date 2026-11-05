//! One command catalogue drives shortcuts, toolbar controls and the palette.
const ui = @import("zircon_ui");
pub const Command = enum { new_file, open_path, quick_open, save, save_as, close_tab, split, toggle_sidebar, palette, find, replace, find_next, find_previous, replace_one, replace_all, undo, redo, select_all, zoom_in, zoom_out, quit, dismiss, submit_path, save_dirty, discard_dirty };
pub const Entry = struct { command: Command, label: []const u8, shortcut: []const u8 = "" };
pub const commands = [_]Entry{
    .{ .command = .new_file, .label = "New file", .shortcut = "⌘N" },
    .{ .command = .open_path, .label = "Open file by path", .shortcut = "⌘O" },
    .{ .command = .quick_open, .label = "Go to file", .shortcut = "⌘P" },
    .{ .command = .save, .label = "Save", .shortcut = "⌘S" },
    .{ .command = .save_as, .label = "Save as…", .shortcut = "⇧⌘S" },
    .{ .command = .close_tab, .label = "Close tab", .shortcut = "⌘W" },
    .{ .command = .split, .label = "Split editor", .shortcut = "⌥⌘S" },
    .{ .command = .toggle_sidebar, .label = "Toggle project sidebar", .shortcut = "⌘B" },
    .{ .command = .find, .label = "Find in document", .shortcut = "⌘F" },
    .{ .command = .replace, .label = "Find and replace", .shortcut = "⌥⌘F" },
    .{ .command = .undo, .label = "Undo", .shortcut = "⌘Z" },
    .{ .command = .redo, .label = "Redo", .shortcut = "⇧⌘Z" },
    .{ .command = .select_all, .label = "Select all", .shortcut = "⌘A" },
    .{ .command = .zoom_in, .label = "Increase font size" },
    .{ .command = .zoom_out, .label = "Decrease font size" },
};
pub const bindings = [_]ui.Keymap(Command).Binding{
    .{ .chord = .{ .key = .n, .modifiers = .{ .command = true } }, .action = .new_file },
    .{ .chord = .{ .key = .o, .modifiers = .{ .command = true } }, .action = .open_path },
    .{ .chord = .{ .key = .p, .modifiers = .{ .command = true } }, .action = .quick_open },
    .{ .chord = .{ .key = .p, .modifiers = .{ .command = true, .shift = true } }, .action = .palette },
    .{ .chord = .{ .key = .s, .modifiers = .{ .command = true } }, .action = .save },
    .{ .chord = .{ .key = .s, .modifiers = .{ .command = true, .shift = true } }, .action = .save_as },
    .{ .chord = .{ .key = .s, .modifiers = .{ .command = true, .alt = true } }, .action = .split },
    .{ .chord = .{ .key = .w, .modifiers = .{ .command = true } }, .action = .close_tab },
    .{ .chord = .{ .key = .f, .modifiers = .{ .command = true } }, .action = .find },
    .{ .chord = .{ .key = .f, .modifiers = .{ .command = true, .alt = true } }, .action = .replace },
    .{ .chord = .{ .key = .b, .modifiers = .{ .command = true } }, .action = .toggle_sidebar },
    .{ .chord = .{ .key = .q, .modifiers = .{ .command = true } }, .action = .quit },
};
