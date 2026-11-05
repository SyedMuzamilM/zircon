//! Streaming literal matching across rope leaves. Insensitive search folds ASCII
//! only. Whole words treat ASCII letters/digits/_ and all non-ASCII code points
//! as word characters; this is a documented policy, not Unicode segmentation.
const std = @import("std");
const text = @import("zircon_text");
const types = @import("types.zig");
pub const Matcher = struct {
    query: types.Query,
    prefix: []usize,
    pub fn init(a: std.mem.Allocator, query: types.Query) !Matcher {
        const table = try a.alloc(usize, query.text.len);
        table[0] = 0;
        var n: usize = 0;
        for (1..query.text.len) |i| {
            const byte = fold(query.text[i], query.case_sensitive);
            while (n > 0 and byte != fold(query.text[n], query.case_sensitive)) n = table[n - 1];
            if (byte == fold(query.text[n], query.case_sensitive)) n += 1;
            table[i] = n;
        }
        return .{ .query = query, .prefix = table };
    }
    pub fn collect(self: Matcher, a: std.mem.Allocator, snapshot: text.Snapshot, max_matches: usize, cancel: types.Cancellation) !struct { matches: []const types.Match, truncated: bool } {
        var matches: std.ArrayList(types.Match) = .empty;
        var iterator = try snapshot.chunks(.{ .start = 0, .end = snapshot.byteLen() });
        var offset: usize = 0;
        var n: usize = 0;
        while (iterator.next()) |part| for (part) |original| {
            if (offset % 4096 == 0) try cancel.check();
            const byte = fold(original, self.query.case_sensitive);
            while (n > 0 and byte != fold(self.query.text[n], self.query.case_sensitive)) n = self.prefix[n - 1];
            if (byte == fold(self.query.text[n], self.query.case_sensitive)) n += 1;
            offset += 1;
            if (n == self.query.text.len) {
                const range: text.Range = .{ .start = offset - self.query.text.len, .end = offset };
                const accepted = !self.query.whole_word or ((range.start == 0 or !word(try snapshot.byteAt(range.start - 1))) and (range.end == snapshot.byteLen() or !word(try snapshot.byteAt(range.end))));
                if (accepted) {
                    if (matches.items.len == max_matches) return .{ .matches = matches.items, .truncated = true };
                    const point = try snapshot.pointAt(range.start);
                    try matches.append(a, .{ .range = range, .line = point.line, .column = point.byte_column });
                    n = 0;
                } else n = self.prefix[n - 1];
            }
        };
        try cancel.check();
        return .{ .matches = matches.items, .truncated = false };
    }
};
fn fold(byte: u8, sensitive: bool) u8 {
    return if (sensitive) byte else std.ascii.toLower(byte);
}
fn word(byte: u8) bool {
    return byte >= 0x80 or std.ascii.isAlphanumeric(byte) or byte == '_';
}
