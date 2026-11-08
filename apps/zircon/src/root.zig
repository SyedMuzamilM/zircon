//! Zircon application composition. Reusable UI, text, persistence and editing
//! live in separate packages; this module owns tabs, panes and workspace policy.
pub const git = @import("zircon_git");
const zircon_git_ui = @import("zircon_git_ui");
pub const language = @import("zircon_language");
const app_icon = @import("app_icon.zig");
const commands_module = @import("commands.zig");
const language_suggestions = @import("language_suggestions.zig");
pub const menus = @import("menus.zig");
const extensions = @import("services/extensions.zig");
const model = @import("settings/model.zig");
const store = @import("settings/store.zig");
const settings_view = @import("settings/view.zig");
const shell = @import("shell.zig");
pub const view = @import("view.zig");
const commit_message = @import("views/git/commit_message.zig");
pub const overlays = @import("views/overlays.zig");
pub const diff_layout = zircon_git_ui.layout;
pub const Shell = shell.Shell;
pub const CommitMessage = commit_message.Message;
pub const Command = commands_module.Command;
pub const commands = commands_module.commands;

pub const Settings = model.Settings;
pub const SettingsStore = store.Store;
pub const SettingsPatch = store.Patch;
pub const SettingsView = settings_view.View;

pub const refreshExtensions = extensions.refresh;

pub const languageSuggestion = language_suggestions.query;

pub const applicationIcon = app_icon.create;
