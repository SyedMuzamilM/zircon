//! Git display projections, source excerpts and editing presentation.
const editing = @import("zircon_editor");
const ws = @import("zircon_workspace");
pub const content = @import("content.zig");
pub const hunks = @import("hunks.zig");
pub const layout = @import("layout.zig");
pub const sources = @import("sources.zig");
pub const Editors = editing.SourceEditors(ws.DocumentId);
pub const SourceEditor = Editors.View;
