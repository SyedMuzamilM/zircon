//! Diagnostic underline geometry shared by the editor canvas and excerpt rows.

const text = @import("zircon_text");
const ui = @import("zircon_ui");
const theme_module = @import("theme.zig");
pub const Severity = enum { hint, information, warning, @"error" };

pub const Mark = struct {
    range: text.Range,
    severity: Severity,
    message: []const u8,
    source: []const u8 = "",
};

/// The next visual row owns a wrap boundary. The last row also owns end-of-line.
pub fn containsPoint(offset: usize, start: usize, end: usize, line_len: usize) bool {
    return offset >= start and (offset < end or (offset == end and end == line_len));
}

pub fn color(theme: theme_module.Theme, severity: Severity) ui.Color {
    return switch (severity) {
        .@"error" => theme.git_deleted,
        .warning => theme.git_modified,
        .information => theme.caret,
        .hint => theme.line_number,
    };
}

/// A 2px sawtooth on the text baseline. A zero-width mark still covers the caret column.
pub fn paint(cx: *ui.PaintCx, x: f32, width: f32, line_y: f32, line_height: f32, tint: ui.Color) !void {
    const span = @max(width, 4);
    const baseline = line_y + line_height - 3;
    var cursor = x;
    const end = x + span;
    var raised = false;
    while (cursor < end) {
        const piece = @min(@as(f32, 2), end - cursor);
        if (piece > 0) try cx.painter.fillRect(.{ .bounds = .{ .x = cursor, .y = baseline - if (raised) @as(f32, 2) else 0, .width = piece, .height = 1 }, .color = tint });
        cursor += 2;
        raised = !raised;
    }
}
