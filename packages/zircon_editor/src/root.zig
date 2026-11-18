//! Native-independent editing state and a Zircon UI custom canvas.
pub const annotations = @import("annotations.zig");
pub const blame_view = @import("blame_view.zig");
const canvas = @import("canvas.zig");
pub const code_line = @import("code_line.zig");
const commands = @import("commands.zig");
pub const display = @import("display.zig");
const editor = @import("editor.zig");
pub const element = @import("element.zig");
pub const indent_guides = @import("indent_guides.zig");
const profile = @import("profile.zig");
const selections = @import("selections.zig");
const source_editors = @import("source_editors.zig");
pub const syntax = @import("syntax.zig");
const theme = @import("theme.zig");
pub const vim = @import("vim.zig");
pub const wrap = @import("wrap.zig");
pub const Editor = editor.Editor;
pub const Outcome = editor.Outcome;
pub const Selection = selections.Selection;
pub const SelectionSet = selections.Set;
pub const Command = commands.Command;
pub const Move = commands.Move;
pub const gutterWidth = canvas.gutterWidth;

pub const Theme = theme.Theme;

pub const GitChange = annotations.GitChange;
pub const Blame = annotations.Blame;

pub const Profile = profile.Profile;

pub const SourceEditors = source_editors.Sources;
