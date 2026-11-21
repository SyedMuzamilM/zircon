//! UI-independent UTF-8 text storage, snapshots, history and literal search.
const document = @import("document.zig");
const snapshot = @import("snapshot.zig");
const types = @import("types.zig");
pub const Range = types.Range;
pub const Edit = types.Edit;
pub const Point = types.Point;
pub const Affinity = types.Affinity;
pub const Direction = types.Direction;
pub const Document = document.Document;
pub const Change = document.Change;
pub const Mapping = document.Mapping;
pub const Snapshot = snapshot.Snapshot;
pub const LineIterator = snapshot.LineIterator;
