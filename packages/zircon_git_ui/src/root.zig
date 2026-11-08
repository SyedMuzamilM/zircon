//! Git display projections, source excerpts and editing presentation.
pub const content = @import("content.zig");
const editors = @import("editors.zig");
pub const layout = @import("layout.zig");
pub const sources = @import("sources.zig");
pub const Editors = editors.Model;
pub const SourceEditor = editors.View;
