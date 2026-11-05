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
