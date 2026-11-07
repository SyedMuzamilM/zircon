//! Frame-local node identity and stable logical keys have distinct lifetimes.
pub const Element = struct { index: u32, frame_epoch: u64 };
pub const Key = union(enum) {
    string: []const u8,
    number: u64,
    pub fn named(value: []const u8) Key {
        return .{ .string = value };
    }
};
