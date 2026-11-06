//! Native-independent editing state and a Zircon UI custom canvas.
pub const Editor = @import("editor.zig").Editor;
pub const Outcome = @import("editor.zig").Outcome;
pub const Selection = @import("selections.zig").Selection;
pub const SelectionSet = @import("selections.zig").Set;
pub const Command = @import("commands.zig").Command;
pub const Move = @import("commands.zig").Move;
pub const syntax = @import("syntax.zig");
pub const display = @import("display.zig");
pub const gutterWidth = @import("canvas.zig").gutterWidth;

pub const Theme = @import("theme.zig").Theme;

pub const GitChange = @import("annotations.zig").GitChange;
pub const Blame = @import("annotations.zig").Blame;
pub const blame_height = @import("annotations.zig").blame_height;

pub const Profile = @import("profile.zig").Profile;
