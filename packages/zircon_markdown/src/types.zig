//! All ranges are half-open UTF-8 source bytes, including original line endings.
pub const Range = struct { start: usize, end: usize };
pub const Inline = struct {
    kind: enum { text, code, link, image } = .text,
    source: Range,
    text: []const u8,
    target: ?[]const u8 = null,
    strong: bool = false,
    emphasis: bool = false,
};
pub const Table = struct { rows: []const Row, alignments: []const Alignment };
pub const Row = struct { cells: []const Cell, source: Range };
pub const Cell = struct { content: []const Inline, source: Range };
pub const Alignment = enum { start, center, end };
pub const Block = struct {
    kind: enum { heading, paragraph, code, list_item, quote, rule, table },
    source: Range,
    content: []const u8 = "",
    inlines: []const Inline = &.{},
    level: u8 = 0,
    ordered: bool = false,
    number: usize = 1,
    info: []const u8 = "",
    table: ?Table = null,
};
