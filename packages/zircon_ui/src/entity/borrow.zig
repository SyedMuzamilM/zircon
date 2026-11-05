//! Runtime borrowing for callback-scoped access on the owning UI thread.
const std = @import("std");
pub const Borrow = struct {
    readers: u32 = 0,
    writer: bool = false,
    pub fn read(b: *Borrow) !void {
        if (b.writer) return error.BorrowConflict;
        if (b.readers == std.math.maxInt(u32)) return error.TooManyReaders;
        b.readers += 1;
    }
    pub fn write(b: *Borrow) !void {
        if (b.writer or b.readers != 0) return error.BorrowConflict;
        b.writer = true;
    }
    pub fn releaseRead(b: *Borrow) void {
        std.debug.assert(b.readers > 0);
        b.readers -= 1;
    }
    pub fn releaseWrite(b: *Borrow) void {
        std.debug.assert(b.writer);
        b.writer = false;
    }
    pub fn active(b: Borrow) bool {
        return b.writer or b.readers != 0;
    }
};
