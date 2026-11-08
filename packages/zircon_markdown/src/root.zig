//! Source-ranged Markdown blocks and inline spans. No UI or HTML execution.
const parser = @import("parser.zig");
const types = @import("types.zig");
pub const Range = types.Range;
pub const Inline = types.Inline;
pub const Block = types.Block;
pub const Table = types.Table;
pub const Document = parser.Document;
pub const parse = parser.parse;
