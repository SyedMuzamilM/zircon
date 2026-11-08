//! Local contribution extensions. This package validates data and never loads
//! native extension code or starts configured language-server executables.
const model = @import("model.zig");
const registry = @import("registry.zig");
pub const Registry = registry.Registry;
pub const Snapshot = registry.Snapshot;
pub const Color = model.Color;
pub const Theme = model.Theme;
pub const Colors = model.Colors;
pub const SyntaxColors = model.SyntaxColors;
pub const Icon = model.Icon;
pub const IconTheme = model.IconTheme;
pub const Language = model.Language;
pub const BlockComment = model.BlockComment;
pub const Server = model.Server;
pub const Extension = model.Extension;
pub const bundledManifest = @embedFile("oxide_manifest");
