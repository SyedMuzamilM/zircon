//! Cache identities include the logical ancestor path. Hash semantic fields,
//! never struct padding or inactive union payloads.

const std = @import("std");
const tree = @import("tree.zig");
pub fn hash(seed: u64, value: anytype) u64 {
    var result = std.hash.Wyhash.init(seed);
    append(&result, value);
    return result.final();
}
fn append(result: *std.hash.Wyhash, value: anytype) void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .@"struct" => |info| inline for (info.field_names) |name| append(result, @field(value, name)),
        .@"union" => switch (value) {
            inline else => |payload, tag| {
                result.update(@tagName(tag));
                append(result, payload);
            },
        },
        .optional => if (value) |payload| {
            result.update(&.{1});
            append(result, payload);
        } else result.update(&.{0}),
        .@"enum" => result.update(@tagName(value)),
        .bool => result.update(&.{@intFromBool(value)}),
        .int, .float => result.update(std.mem.asBytes(&value)),
        .void => {},
        .array => for (value) |item| append(result, item),
        .pointer => |info| {
            if (info.size != .slice) @compileError("cache hash requires a value or slice");
            append(result, value.len);
            for (value) |item| append(result, item);
        },
        else => @compileError("unsupported cache key type " ++ @typeName(T)),
    }
}

pub fn scoped(frame: *const tree.Frame, index: u32) u64 {
    const node = frame.nodes.items[index];
    const parent_hash = if (node.parent) |parent| scoped(frame, parent) else 0;
    if (node.key) |key| return hash(parent_hash, key);
    var ordinal: usize = 0;
    if (node.parent) |parent| for (frame.nodes.items[parent].children, 0..) |child, position| {
        if (child == index) {
            ordinal = position;
            break;
        }
    };
    return hash(hash(parent_hash, @as(u8, 2)), ordinal);
}
