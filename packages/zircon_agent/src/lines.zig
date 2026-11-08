//! Bounded newline framing for streamed agent protocol messages.
//! Returned lines borrow decoder storage until the next feed or deinit.
const std = @import("std");
pub const Decoder = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayList(u8) = .empty,
    consumed: usize = 0,
    pub fn init(a: std.mem.Allocator) Decoder {
        return .{ .allocator = a };
    }
    pub fn deinit(self: *Decoder) void {
        self.buffer.deinit(self.allocator);
    }
    pub fn feed(self: *Decoder, bytes: []const u8) !void {
        if (self.consumed > 0) {
            std.mem.copyForwards(u8, self.buffer.items, self.buffer.items[self.consumed..]);
            self.buffer.items.len -= self.consumed;
            self.consumed = 0;
        }
        if (self.buffer.items.len + bytes.len > 8 * 1024 * 1024) return error.MessageTooLarge;
        try self.buffer.appendSlice(self.allocator, bytes);
    }
    pub fn next(self: *Decoder) !?[]const u8 {
        while (std.mem.indexOfScalar(u8, self.buffer.items[self.consumed..], '\n')) |end| {
            const start = self.consumed;
            self.consumed += end + 1;
            const line = std.mem.trim(u8, self.buffer.items[start..][0..end], " \r\t");
            if (line.len > 0) return line;
        }
        return null;
    }
};
