//! Incremental LSP Content-Length framing. Messages are borrowed until the next
//! consume/feed, and input is bounded before allocating a body-sized buffer.
const std = @import("std");
pub const max_message = 8 * 1024 * 1024;
pub const Decoder = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayList(u8) = .empty,
    consumed: usize = 0,
    pub fn init(a: std.mem.Allocator) Decoder {
        return .{ .allocator = a };
    }
    pub fn deinit(self: *Decoder) void {
        self.buffer.deinit(self.allocator);
        self.* = undefined;
    }
    pub fn feed(self: *Decoder, bytes: []const u8) !void {
        if (self.consumed > 0) {
            std.mem.copyForwards(u8, self.buffer.items, self.buffer.items[self.consumed..]);
            self.buffer.items.len -= self.consumed;
            self.consumed = 0;
        }
        if (bytes.len > max_message + 8192 or self.buffer.items.len > max_message + 8192 - bytes.len) return error.MessageTooLarge;
        try self.buffer.appendSlice(self.allocator, bytes);
    }
    pub fn next(self: *Decoder) !?[]const u8 {
        const pending = self.buffer.items[self.consumed..];
        const header_end = std.mem.indexOf(u8, pending, "\r\n\r\n") orelse {
            if (pending.len > 8192) return error.HeaderTooLarge;
            return null;
        };
        if (header_end > 8192) return error.HeaderTooLarge;
        var lines = std.mem.splitSequence(u8, pending[0..header_end], "\r\n");
        var length: ?usize = null;
        while (lines.next()) |line| {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.InvalidHeader;
            if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " \t"), "Content-Length")) {
                if (length != null) return error.DuplicateContentLength;
                const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
                if (value.len == 0) return error.InvalidContentLength;
                for (value) |c| if (c < '0' or c > '9') return error.InvalidContentLength;
                length = std.fmt.parseInt(usize, value, 10) catch return error.InvalidContentLength;
            }
        }
        const body_length = length orelse return error.MissingContentLength;
        if (body_length > max_message) return error.MessageTooLarge;
        const begin = header_end + 4;
        if (pending.len - begin < body_length) return null;
        const body = pending[begin..][0..body_length];
        self.consumed += begin + body_length;
        return body;
    }
};
pub fn encode(a: std.mem.Allocator, json: []const u8) ![]u8 {
    if (json.len > max_message) return error.MessageTooLarge;
    return std.fmt.allocPrint(a, "Content-Length: {d}\r\n\r\n{s}", .{ json.len, json });
}
