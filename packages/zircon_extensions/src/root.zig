//! Local contribution extensions. This package validates data and never loads
//! native extension code or starts configured language-server executables.
pub const Registry = @import("registry.zig").Registry;
pub const Snapshot = @import("registry.zig").Snapshot;
pub const Color = @import("model.zig").Color;
pub const Theme = @import("model.zig").Theme;
pub const Colors = @import("model.zig").Colors;
pub const SyntaxColors = @import("model.zig").SyntaxColors;
pub const Icon = @import("model.zig").Icon;
pub const IconTheme = @import("model.zig").IconTheme;
pub const Language = @import("model.zig").Language;
pub const BlockComment = @import("model.zig").BlockComment;
pub const Server = @import("model.zig").Server;
pub const Extension = @import("model.zig").Extension;
pub const bundledManifest = @embedFile("oxide_manifest");
