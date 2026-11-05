//! Tab expansion stores mappings only where tabs change byte positions. Normal
//! UTF-8 text borrows its frame-owned source without per-code-point metadata.
const std = @import("std");
const ui = @import("zircon_ui");
pub const Line = struct {
    bytes: []const u8,
    source: []const usize,
    display: []const usize,
    pub fn build(a: std.mem.Allocator, original: []const u8, tab_width: usize) !Line {
        if (tab_width == 0 or tab_width > 32) return error.InvalidTabWidth;
        if (!std.unicode.utf8ValidateSlice(original)) return error.InvalidUtf8;
        if (std.mem.indexOfScalar(u8, original, '\t') == null) return .{ .bytes = original, .source = &.{}, .display = &.{} };
        var bytes: std.ArrayList(u8) = .empty;
        var sources: std.ArrayList(usize) = .empty;
        var displays: std.ArrayList(usize) = .empty;
        var cursor: usize = 0;
        var column: usize = 0;
        while (cursor < original.len) {
            const n = std.unicode.utf8ByteSequenceLength(original[cursor]) catch unreachable;
            if (original[cursor] == '\t') {
                try sources.append(a, cursor);
                try displays.append(a, bytes.items.len);
                const spaces = tab_width - column % tab_width;
                try bytes.appendNTimes(a, ' ', spaces);
                try sources.append(a, cursor + 1);
                try displays.append(a, bytes.items.len);
                column += spaces;
            } else {
                try bytes.appendSlice(a, original[cursor..][0..n]);
                column += 1;
            }
            cursor += n;
        }
        return .{ .bytes = bytes.items, .source = sources.items, .display = displays.items };
    }
    pub fn displayOffset(self: Line, offset: usize) usize {
        var extra: usize = 0;
        var i: usize = 1;
        while (i < self.source.len) : (i += 2) {
            if (offset < self.source[i]) break;
            extra = self.display[i] - self.source[i];
        }
        return @min(self.bytes.len, offset + extra);
    }
    pub fn sourceOffset(self: Line, offset: usize) usize {
        var extra: usize = 0;
        var i: usize = 0;
        while (i < self.display.len) : (i += 2) {
            if (offset < self.display[i]) break;
            if (offset < self.display[i + 1]) {
                return if (offset - self.display[i] < self.display[i + 1] - offset) self.source[i] else self.source[i + 1];
            }
            extra = self.display[i + 1] - self.source[i + 1];
        }
        return offset -| extra;
    }
    pub fn caret(self: Line, metrics: ui.layout.Measurer, style: ui.TextStyle, offset: usize) f32 {
        return metrics.caret(self.bytes, style, self.displayOffset(offset));
    }
    pub fn index(self: Line, metrics: ui.layout.Measurer, style: ui.TextStyle, x: f32) usize {
        return self.sourceOffset(metrics.index(self.bytes, style, x));
    }
};
