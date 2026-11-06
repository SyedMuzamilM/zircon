//! Zircon application composition. Reusable UI, text, persistence and editing
//! live in separate packages; this module owns tabs, panes and workspace policy.
pub const Shell = @import("shell.zig").Shell;
pub const Command = @import("commands.zig").Command;
pub const commands = @import("commands.zig").commands;

pub const view = @import("view.zig");
pub const Settings = @import("settings/model.zig").Settings;
pub const SettingsStore = @import("settings/store.zig").Store;
pub const SettingsPatch = @import("settings/store.zig").Patch;
pub const SettingsView = @import("settings/view.zig").View;

pub const refreshExtensions = @import("services/extensions.zig").refresh;
