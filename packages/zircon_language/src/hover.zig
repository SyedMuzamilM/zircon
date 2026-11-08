//! Normalize the LSP hover content variants to Markdown for presentation.

const std = @import("std");
pub fn contents(a: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    if (value == .null) return "";
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(a);
    try append(a, &output, value);
    if (output.items.len > 64 * 1024) return error.HoverTooLarge;
    return output.toOwnedSlice(a);
}

fn append(a: std.mem.Allocator, output: *std.ArrayList(u8), value: std.json.Value) !void {
    switch (value) {
        .string => |bytes| try output.appendSlice(a, bytes),
        .array => |items| for (items.items, 0..) |item, i| {
            if (i > 0) try output.appendSlice(a, "\n\n");
            try append(a, output, item);
        },
        .object => |object| {
            const text = object.get("value") orelse return error.InvalidHover;
            if (text != .string) return error.InvalidHover;
            if (object.get("language")) |language| {
                if (language != .string) return error.InvalidHover;
                try output.appendSlice(a, "```");
                try output.appendSlice(a, language.string);
                try output.append(a, '\n');
                try output.appendSlice(a, text.string);
                try output.appendSlice(a, "\n```");
            } else try output.appendSlice(a, text.string);
        },
        else => return error.InvalidHover,
    }
}
