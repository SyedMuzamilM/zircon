//! Zircon application composition. Reusable UI, text, persistence and editing
//! live in separate packages; this module owns tabs, panes and workspace policy.
pub const Shell = @import("shell.zig").Shell;
pub const Command = @import("commands.zig").Command;
pub const commands = @import("commands.zig").commands;

pub const view = @import("view.zig");
