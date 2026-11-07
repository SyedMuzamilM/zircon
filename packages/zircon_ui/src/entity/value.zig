//! Entity results and callback payloads share the same copied-value boundary.
pub fn containsPointer(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => true,
        inline .@"struct", .@"union" => |info| blk: {
            for (info.field_types) |Field| if (containsPointer(Field)) break :blk true;
            break :blk false;
        },
        inline .array, .optional => |info| containsPointer(info.child),
        .error_union => |info| containsPointer(info.payload),
        else => false,
    };
}
