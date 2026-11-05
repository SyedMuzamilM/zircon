//! Offsets are UTF-8 bytes. Ranges are half-open and may not split a code point.
pub const Range = struct { start: usize, end: usize };
pub const Edit = struct { range: Range, text: []const u8 };
pub const Point = struct { line: usize, byte_column: usize };
pub const Affinity = enum { before, after };
pub const Direction = enum { forward, backward };
