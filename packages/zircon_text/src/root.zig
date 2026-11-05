//! UI-independent UTF-8 text storage, snapshots, history and literal search.
pub const Range = @import("types.zig").Range;
pub const Edit = @import("types.zig").Edit;
pub const Point = @import("types.zig").Point;
pub const Affinity = @import("types.zig").Affinity;
pub const Direction = @import("types.zig").Direction;
pub const Document = @import("document.zig").Document;
pub const Change = @import("document.zig").Change;
pub const Snapshot = @import("snapshot.zig").Snapshot;
