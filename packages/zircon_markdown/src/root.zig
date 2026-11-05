//! Source-ranged Markdown blocks and inline spans. No UI or HTML execution.
pub const Range = @import("types.zig").Range;
pub const Inline = @import("types.zig").Inline;
pub const Block = @import("types.zig").Block;
pub const Table = @import("types.zig").Table;
pub const Document = @import("parser.zig").Document;
pub const parse = @import("parser.zig").parse;
