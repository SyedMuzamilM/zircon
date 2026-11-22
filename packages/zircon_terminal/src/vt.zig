//! VT100/xterm terminal state machine: dual primary/alt screens, full SGR
//! (16/256/truecolor + attributes), scroll regions, bracketed paste, SGR mouse,
//! and OSC 0/2/7/52.

const std = @import("std");
const grid = @import("grid.zig");
pub const MouseMode = enum { none, click, drag, any };

const SavedCursor = struct {
    row: usize = 0,
    col: usize = 0,
    fg: grid.Color = .default,
    bg: grid.Color = .default,
    style: grid.Style = .{},
    pending_wrap: bool = false,
};

pub const Terminal = struct {
    primary: grid.Screen,
    alt: grid.Screen,
    in_alt_screen: bool = false,
    row: usize = 0,
    col: usize = 0,
    pending_wrap: bool = false,
    fg: grid.Color = .default,
    bg: grid.Color = .default,
    style: grid.Style = .{},
    saved_primary: SavedCursor = .{},
    saved_alt: SavedCursor = .{},
    /// Saved primary cursor while in alternate screen.
    primary_stash: SavedCursor = .{},

    cursor_visible: bool = true,
    autowrap: bool = true,
    bracketed_paste: bool = false,
    app_cursor_keys: bool = false,
    mouse_mode: MouseMode = .none,
    mouse_sgr: bool = false,
    origin_mode: bool = false,
    graphic_sets: [2]bool = @splat(false),
    active_charset: u1 = 0,
    designating_charset: ?u1 = null,

    title: []u8 = &.{},
    cwd: []u8 = &.{},
    pending_clipboard: ?[]u8 = null,
    /// Outbound VT replies (e.g. DSR 6n cursor position report) to flush to PTY.
    responses: std.ArrayList(u8) = .empty,

    parser: enum { text, escape, csi, osc, osc_escape, charset, control_string, control_escape } = .text,
    csi_buf: [256]u8 = undefined,
    csi_len: usize = 0,
    csi_overflow: bool = false,
    osc_overflow: bool = false,
    osc_buf: std.ArrayList(u8) = .empty,
    utf8: [4]u8 = undefined,
    utf8_len: usize = 0,

    pub const default_history = 10_000;

    pub fn init(a: std.mem.Allocator, cols: usize, rows: usize, max_history: usize) !Terminal {
        var primary = try grid.Screen.init(a, cols, rows, max_history);
        errdefer primary.deinit(a);
        const alt = try grid.Screen.init(a, cols, rows, 0);
        return .{ .primary = primary, .alt = alt };
    }

    pub fn deinit(self: *Terminal, a: std.mem.Allocator) void {
        self.primary.deinit(a);
        self.alt.deinit(a);
        a.free(self.title);
        a.free(self.cwd);
        if (self.pending_clipboard) |clip| a.free(clip);
        self.responses.deinit(a);
        self.osc_buf.deinit(a);
        self.* = undefined;
    }

    pub fn activeScreen(self: *Terminal) *grid.Screen {
        return if (self.in_alt_screen) &self.alt else &self.primary;
    }

    pub fn activeScreenConst(self: *const Terminal) *const grid.Screen {
        return if (self.in_alt_screen) &self.alt else &self.primary;
    }

    pub fn resize(self: *Terminal, a: std.mem.Allocator, cols: usize, rows: usize) !void {
        const c = @max(1, cols);
        const r = @max(1, rows);
        if (self.in_alt_screen) {
            self.row = try self.alt.resize(a, c, r, self.row);
            self.col = @min(self.col, c - 1);
            self.primary_stash.row = try self.primary.resize(a, c, r, self.primary_stash.row);
        } else {
            self.row = try self.primary.resize(a, c, r, self.row);
            self.col = @min(self.col, c - 1);
            self.saved_alt.row = try self.alt.resize(a, c, r, @min(self.saved_alt.row, self.alt.rows - 1));
        }
        self.pending_wrap = false;
    }

    pub fn clear(self: *Terminal) void {
        self.activeScreen().clearAll(!self.in_alt_screen);
        self.row = 0;
        self.col = 0;
        self.pending_wrap = false;
    }

    pub fn takeClipboard(self: *Terminal) ?[]u8 {
        const val = self.pending_clipboard;
        self.pending_clipboard = null;
        return val;
    }

    pub fn feed(self: *Terminal, a: std.mem.Allocator, bytes: []const u8) !void {
        for (bytes) |byte| switch (self.parser) {
            .text => {
                if (self.utf8_len != 0 and byte & 0xc0 != 0x80) {
                    self.utf8_len = 0;
                    try self.putCodepoint(a, 0xfffd);
                }
                if (byte == 0x1b) {
                    self.parser = .escape;
                    self.utf8_len = 0;
                } else if (byte == '\r') {
                    self.col = 0;
                    self.pending_wrap = false;
                } else if (byte == '\n' or byte == 0x0b or byte == 0x0c) {
                    try self.lineFeed(a, false);
                } else if (byte == 0x08) {
                    if (self.pending_wrap) {
                        self.pending_wrap = false;
                    } else {
                        self.col -|= 1;
                    }
                } else if (byte == '\t') {
                    self.pending_wrap = false;
                    const cols = self.activeScreenConst().cols;
                    self.col = @min(cols - 1, (self.col / 8 + 1) * 8);
                } else if (byte == 0x0e or byte == 0x0f) {
                    self.active_charset = if (byte == 0x0e) 1 else 0;
                } else if (byte == 0x07 or byte < 0x20 or byte == 0x7f) {
                    // Bell & unhandled C0 controls ignored.
                } else if (byte < 0x80) {
                    self.utf8_len = 0;
                    try self.putCodepoint(a, if (self.graphic_sets[self.active_charset]) decGraphic(byte) else byte);
                } else {
                    if (self.utf8_len == 0) {
                        const expected = std.unicode.utf8ByteSequenceLength(byte) catch {
                            try self.putCodepoint(a, 0xfffd);
                            continue;
                        };
                        self.utf8[0] = byte;
                        self.utf8_len = 1;
                        if (expected == 1) {
                            self.utf8_len = 0;
                            try self.putCodepoint(a, 0xfffd);
                        }
                    } else {
                        if (self.utf8_len < 4) {
                            self.utf8[self.utf8_len] = byte;
                            self.utf8_len += 1;
                        }
                        const expected = std.unicode.utf8ByteSequenceLength(self.utf8[0]) catch {
                            self.utf8_len = 0;
                            continue;
                        };
                        if (self.utf8_len == expected) {
                            const cp = std.unicode.utf8Decode(self.utf8[0..expected]) catch 0xfffd;
                            self.utf8_len = 0;
                            try self.putCodepoint(a, cp);
                        }
                    }
                }
            },
            .escape => {
                switch (byte) {
                    '[' => {
                        self.csi_len = 0;
                        self.csi_overflow = false;
                        self.parser = .csi;
                    },
                    ']' => {
                        self.osc_buf.clearRetainingCapacity();
                        self.osc_overflow = false;
                        self.parser = .osc;
                    },
                    '(', ')', '*', '+' => {
                        self.designating_charset = switch (byte) {
                            '(' => 0,
                            ')' => 1,
                            else => null,
                        };
                        self.parser = .charset;
                    },
                    'P', 'X', '^', '_' => self.parser = .control_string,
                    '7' => {
                        self.saveCursor();
                        self.parser = .text;
                    },
                    '8' => {
                        self.restoreCursor();
                        self.parser = .text;
                    },
                    'D' => {
                        try self.lineFeed(a, false);
                        self.parser = .text;
                    },
                    'E' => {
                        self.col = 0;
                        try self.lineFeed(a, false);
                        self.parser = .text;
                    },
                    'M' => {
                        self.reverseIndex();
                        self.parser = .text;
                    },
                    'c' => {
                        self.reset();
                        self.parser = .text;
                    },
                    else => self.parser = .text,
                }
            },
            .charset => {
                if (self.designating_charset) |slot| self.graphic_sets[slot] = byte == '0';
                self.parser = .text;
            },
            .control_string => if (byte == 0x1b) {
                self.parser = .control_escape;
            } else if (byte == 0x18 or byte == 0x1a) {
                self.parser = .text;
            },
            .control_escape => {
                self.parser = if (byte == '\\') .text else .control_string;
            },
            .csi => {
                if (byte >= 0x40 and byte <= 0x7e) {
                    if (!self.csi_overflow) try self.handleCsi(a, byte);
                    self.parser = .text;
                } else if (byte == 0x1b) {
                    self.parser = .escape;
                } else if (byte == 0x18 or byte == 0x1a) {
                    self.parser = .text;
                } else if (self.csi_len < self.csi_buf.len) {
                    self.csi_buf[self.csi_len] = byte;
                    self.csi_len += 1;
                } else self.csi_overflow = true;
            },
            .osc => {
                if (byte == 0x07) {
                    if (!self.osc_overflow) try self.handleOsc(a);
                    self.parser = .text;
                } else if (byte == 0x1b) {
                    self.parser = .osc_escape;
                } else if (self.osc_buf.items.len < 65536) {
                    try self.osc_buf.append(a, byte);
                } else self.osc_overflow = true;
            },
            .osc_escape => {
                if (byte == '\\') {
                    if (!self.osc_overflow) try self.handleOsc(a);
                    self.parser = .text;
                } else {
                    self.parser = .text;
                }
            },
        };
    }

    fn blankCell(self: *const Terminal) grid.Cell {
        return .{ .code = ' ', .fg = .default, .bg = self.bg, .style = .{} };
    }

    fn lineFeed(self: *Terminal, a: std.mem.Allocator, wrapped: bool) !void {
        const s = self.activeScreen();
        if (!wrapped) {
            const row = s.viewRow(self.row);
            row.wrapped = false;
            row.wrap_padding = false;
        }
        self.pending_wrap = false;
        if (self.row == s.scroll_bottom) {
            try s.scrollUp(a, 1, self.blankCell());
        } else if (self.row + 1 < s.rows) {
            self.row += 1;
        }
    }

    fn reverseIndex(self: *Terminal) void {
        const s = self.activeScreen();
        self.pending_wrap = false;
        if (self.row == s.scroll_top) {
            s.scrollDown(1, self.blankCell());
        } else {
            self.row -|= 1;
        }
    }

    fn putCodepoint(self: *Terminal, a: std.mem.Allocator, cp: u21) !void {
        const width = charWidth(cp);
        if (width == 0) return;
        const s = self.activeScreen();
        if (self.pending_wrap) {
            if (self.autowrap) {
                s.viewRow(self.row).wrapped = true;
                s.viewRow(self.row).wrap_padding = false;
                self.col = 0;
                try self.lineFeed(a, true);
            } else {
                self.col = s.cols - 1;
                self.pending_wrap = false;
            }
        }
        if (width == 2 and self.col + 1 >= s.cols) {
            if (self.autowrap and s.cols >= 2) {
                const row = s.viewRow(self.row);
                row.erase(self.col, self.col + 1, self.blankCell());
                row.wrapped = true;
                row.wrap_padding = true;
                self.col = 0;
                try self.lineFeed(a, true);
            } else {
                return;
            }
        }
        const cells = s.viewRow(self.row).cells;
        // Clear orphaned half of a previous wide glyph if overwriting part of it.
        if (cells[self.col].style.wide_trail and self.col > 0) {
            cells[self.col - 1] = self.blankCell();
        }
        if (cells[self.col].style.wide_lead and self.col + 1 < s.cols) {
            cells[self.col + 1] = self.blankCell();
        }
        var st = self.style;
        st.wide_lead = width == 2;
        st.wide_trail = false;
        cells[self.col] = .{ .code = cp, .fg = self.fg, .bg = self.bg, .style = st };
        if (width == 2 and self.col + 1 < s.cols) {
            if (cells[self.col + 1].style.wide_lead and self.col + 2 < s.cols) {
                cells[self.col + 2] = self.blankCell();
            }
            var trail = self.style;
            trail.wide_lead = false;
            trail.wide_trail = true;
            cells[self.col + 1] = .{ .code = ' ', .fg = self.fg, .bg = self.bg, .style = trail };
        }
        if (self.col + width >= s.cols) {
            self.col = s.cols - 1;
            self.pending_wrap = true;
        } else {
            self.col += width;
        }
    }

    fn saveCursor(self: *Terminal) void {
        const snapshot: SavedCursor = .{
            .row = self.row,
            .col = self.col,
            .fg = self.fg,
            .bg = self.bg,
            .style = self.style,
            .pending_wrap = self.pending_wrap,
        };
        if (self.in_alt_screen) self.saved_alt = snapshot else self.saved_primary = snapshot;
    }

    fn restoreCursor(self: *Terminal) void {
        const snapshot = if (self.in_alt_screen) self.saved_alt else self.saved_primary;
        const s = self.activeScreenConst();
        self.row = @min(snapshot.row, s.rows - 1);
        self.col = @min(snapshot.col, s.cols - 1);
        self.fg = snapshot.fg;
        self.bg = snapshot.bg;
        self.style = snapshot.style;
        self.pending_wrap = snapshot.pending_wrap;
    }

    fn enterAltScreen(self: *Terminal) void {
        if (self.in_alt_screen) return;
        self.primary_stash = .{
            .row = self.row,
            .col = self.col,
            .fg = self.fg,
            .bg = self.bg,
            .style = self.style,
            .pending_wrap = self.pending_wrap,
        };
        self.in_alt_screen = true;
        self.alt.clearAll(true);
        self.row = 0;
        self.col = 0;
        self.pending_wrap = false;
    }

    fn leaveAltScreen(self: *Terminal) void {
        if (!self.in_alt_screen) return;
        self.in_alt_screen = false;
        self.row = @min(self.primary_stash.row, self.primary.rows - 1);
        self.col = @min(self.primary_stash.col, self.primary.cols - 1);
        self.fg = self.primary_stash.fg;
        self.bg = self.primary_stash.bg;
        self.style = self.primary_stash.style;
        self.pending_wrap = self.primary_stash.pending_wrap;
    }

    fn reset(self: *Terminal) void {
        self.in_alt_screen = false;
        self.primary.clearAll(false);
        self.alt.clearAll(true);
        self.primary.scroll_top = 0;
        self.primary.scroll_bottom = self.primary.rows - 1;
        self.row = 0;
        self.col = 0;
        self.pending_wrap = false;
        self.fg = .default;
        self.bg = .default;
        self.style = .{};
        self.cursor_visible = true;
        self.autowrap = true;
        self.bracketed_paste = false;
        self.app_cursor_keys = false;
        self.mouse_mode = .none;
        self.mouse_sgr = false;
        self.origin_mode = false;
        self.graphic_sets = @splat(false);
        self.active_charset = 0;
    }

    fn handleCsi(self: *Terminal, a: std.mem.Allocator, final: u8) !void {
        const seq = self.csi_buf[0..self.csi_len];
        const private = seq.len > 0 and seq[0] == '?';
        if (seq.len > 0 and seq[0] == '>') {
            if (final == 'c') try self.responses.appendSlice(a, "\x1b[>0;0;0c");
            return;
        }
        const body = if (private) seq[1..] else seq;
        var args: [32]usize = @splat(0);
        var argc: usize = 0;
        if (body.len > 0) {
            var it = std.mem.splitScalar(u8, body, ';');
            while (it.next()) |part| {
                if (argc == args.len) break;
                if (std.mem.indexOfScalar(u8, part, ':') != null) {
                    if (final != 'm' or private) return;
                    argc += parseSgrSubparams(part, args[argc..]);
                } else {
                    args[argc] = if (part.len == 0) 0 else std.fmt.parseInt(usize, part, 10) catch return;
                    argc += 1;
                }
            }
        }
        const p0 = @max(1, args[0]);
        const s = self.activeScreen();

        if (private) {
            if (final == 'h' or final == 'l') {
                const enable = final == 'h';
                for (args[0..@max(1, argc)]) |mode| switch (mode) {
                    1 => self.app_cursor_keys = enable,
                    6 => {
                        self.origin_mode = enable;
                        self.row = if (enable) s.scroll_top else 0;
                        self.col = 0;
                        self.pending_wrap = false;
                    },
                    7 => self.autowrap = enable,
                    25 => self.cursor_visible = enable,
                    1000 => self.mouse_mode = if (enable) .click else .none,
                    1002 => self.mouse_mode = if (enable) .drag else .none,
                    1003 => self.mouse_mode = if (enable) .any else .none,
                    1006 => self.mouse_sgr = enable,
                    47, 1047, 1049 => {
                        if (enable) self.enterAltScreen() else self.leaveAltScreen();
                    },
                    2004 => self.bracketed_paste = enable,
                    else => {},
                };
            }
            return;
        }

        switch (final) {
            'A' => {
                self.pending_wrap = false;
                const min_row = if (self.row >= s.scroll_top) s.scroll_top else 0;
                self.row = @max(min_row, self.row -| p0);
            },
            'B', 'e' => {
                self.pending_wrap = false;
                const max_row = if (self.row <= s.scroll_bottom) s.scroll_bottom else s.rows - 1;
                self.row = @min(max_row, self.row +| p0);
            },
            'C', 'a' => {
                self.pending_wrap = false;
                self.col = @min(s.cols - 1, self.col +| p0);
            },
            'D' => {
                self.pending_wrap = false;
                self.col -|= p0;
            },
            'E' => {
                self.pending_wrap = false;
                self.row = @min(s.rows - 1, self.row +| p0);
                self.col = 0;
            },
            'F' => {
                self.pending_wrap = false;
                self.row -|= p0;
                self.col = 0;
            },
            'G', '`' => {
                self.pending_wrap = false;
                self.col = @min(s.cols - 1, p0 - 1);
            },
            'd', 'H', 'f' => {
                self.pending_wrap = false;
                self.row = if (self.origin_mode) @min(s.scroll_bottom, s.scroll_top +| (p0 - 1)) else @min(s.rows - 1, p0 - 1);
                if (final == 'd') return;
                self.col = @min(s.cols - 1, @max(1, args[1]) - 1);
            },
            'J' => {
                self.pending_wrap = false;
                const blank = self.blankCell();
                switch (args[0]) {
                    0 => {
                        const row = s.viewRow(self.row);
                        row.erase(self.col, s.cols, blank);
                        row.wrapped = false;
                        row.wrap_padding = false;
                        for (self.row + 1..s.rows) |y| {
                            const r = s.viewRow(y);
                            @memset(r.cells, blank);
                            r.wrapped = false;
                            r.wrap_padding = false;
                        }
                    },
                    1 => {
                        for (0..self.row) |y| {
                            const r = s.viewRow(y);
                            @memset(r.cells, blank);
                            r.wrapped = false;
                            r.wrap_padding = false;
                        }
                        const row = s.viewRow(self.row);
                        row.erase(0, self.col + 1, blank);
                    },
                    2 => {
                        for (0..s.rows) |y| {
                            const r = s.viewRow(y);
                            @memset(r.cells, blank);
                            r.wrapped = false;
                            r.wrap_padding = false;
                        }
                    },
                    3 => s.clearAll(true),
                    else => {},
                }
            },
            'K' => {
                self.pending_wrap = false;
                const blank = self.blankCell();
                const row = s.viewRow(self.row);
                const c = @min(self.col, s.cols);
                switch (args[0]) {
                    0 => {
                        row.erase(c, s.cols, blank);
                        row.wrapped = false;
                        row.wrap_padding = false;
                    },
                    1 => row.erase(0, @min(s.cols, c + 1), blank),
                    2 => {
                        @memset(row.cells, blank);
                        row.wrapped = false;
                        row.wrap_padding = false;
                    },
                    else => {},
                }
            },
            'L' => s.insertLines(self.row, p0, self.blankCell()),
            'M' => try s.deleteLines(a, self.row, p0, self.blankCell()),
            '@' => {
                const row = s.viewRow(self.row);
                const n = @min(p0, s.cols -| self.col);
                if (n > 0) {
                    std.mem.copyBackwards(grid.Cell, row.cells[self.col + n .. s.cols], row.cells[self.col .. s.cols - n]);
                    @memset(row.cells[self.col .. self.col + n], self.blankCell());
                    row.repairWide(self.blankCell());
                }
            },
            'P' => {
                const row = s.viewRow(self.row);
                const n = @min(p0, s.cols -| self.col);
                if (n > 0) {
                    std.mem.copyForwards(grid.Cell, row.cells[self.col .. s.cols - n], row.cells[self.col + n .. s.cols]);
                    @memset(row.cells[s.cols - n .. s.cols], self.blankCell());
                    row.repairWide(self.blankCell());
                }
            },
            'X' => {
                const row = s.viewRow(self.row);
                const end = @min(s.cols, self.col +| p0);
                row.erase(self.col, end, self.blankCell());
            },
            'S' => try s.scrollUp(a, p0, self.blankCell()),
            'T' => s.scrollDown(p0, self.blankCell()),
            'r' => {
                const top = if (argc >= 1 and args[0] > 0) @min(s.rows - 1, args[0] - 1) else 0;
                const bottom = if (argc >= 2 and args[1] > 0) @min(s.rows - 1, args[1] - 1) else s.rows - 1;
                if (top < bottom) {
                    s.scroll_top = top;
                    s.scroll_bottom = bottom;
                } else {
                    s.scroll_top = 0;
                    s.scroll_bottom = s.rows - 1;
                }
                self.row = if (self.origin_mode) s.scroll_top else 0;
                self.col = 0;
                self.pending_wrap = false;
            },
            's' => self.saveCursor(),
            'u' => self.restoreCursor(),
            'm' => self.handleSgr(args[0..@max(1, argc)]),
            'n' => {
                if (args[0] == 6) {
                    var buf: [32]u8 = undefined;
                    const reply = std.fmt.bufPrint(&buf, "\x1b[{d};{d}R", .{ self.row + 1, self.col + 1 }) catch return;
                    try self.responses.appendSlice(a, reply);
                } else if (args[0] == 5) {
                    try self.responses.appendSlice(a, "\x1b[0n");
                }
            },
            'c' => {
                if (seq.len == 0 or seq[0] == '0') try self.responses.appendSlice(a, "\x1b[?62;c");
            },
            else => {},
        }
    }

    fn handleSgr(self: *Terminal, args: []const usize) void {
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            switch (args[i]) {
                0 => {
                    self.fg = .default;
                    self.bg = .default;
                    self.style = .{};
                },
                1 => self.style.bold = true,
                2 => self.style.dim = true,
                3 => self.style.italic = true,
                4 => self.style.underline = true,
                7 => self.style.inverse = true,
                9 => self.style.strikethrough = true,
                22 => {
                    self.style.bold = false;
                    self.style.dim = false;
                },
                23 => self.style.italic = false,
                24 => self.style.underline = false,
                27 => self.style.inverse = false,
                29 => self.style.strikethrough = false,
                30...37 => |v| self.fg = .{ .indexed = @intCast(v - 30) },
                38 => {
                    if (i + 2 < args.len and args[i + 1] == 5) {
                        self.fg = .{ .indexed = @intCast(@min(255, args[i + 2])) };
                        i += 2;
                    } else if (i + 4 < args.len and args[i + 1] == 2) {
                        self.fg = .{ .rgb = packRgb(args[i + 2], args[i + 3], args[i + 4]) };
                        i += 4;
                    }
                },
                39 => self.fg = .default,
                40...47 => |v| self.bg = .{ .indexed = @intCast(v - 40) },
                48 => {
                    if (i + 2 < args.len and args[i + 1] == 5) {
                        self.bg = .{ .indexed = @intCast(@min(255, args[i + 2])) };
                        i += 2;
                    } else if (i + 4 < args.len and args[i + 1] == 2) {
                        self.bg = .{ .rgb = packRgb(args[i + 2], args[i + 3], args[i + 4]) };
                        i += 4;
                    }
                },
                49 => self.bg = .default,
                90...97 => |v| self.fg = .{ .indexed = @intCast(v - 90 + 8) },
                100...107 => |v| self.bg = .{ .indexed = @intCast(v - 100 + 8) },
                else => {},
            }
        }
    }

    fn handleOsc(self: *Terminal, a: std.mem.Allocator) !void {
        const raw = self.osc_buf.items;
        const sep = std.mem.indexOfScalar(u8, raw, ';') orelse return;
        const code = std.fmt.parseInt(usize, raw[0..sep], 10) catch return;
        const payload = raw[sep + 1 ..];
        switch (code) {
            0, 2 => {
                if (std.unicode.utf8ValidateSlice(payload)) {
                    var end = @min(payload.len, 256);
                    while (end < payload.len and payload[end] & 0xc0 == 0x80) end -= 1;
                    const owned = try a.dupe(u8, payload[0..end]);
                    for (owned) |*byte| if (byte.* < 0x20 or byte.* == 0x7f) {
                        byte.* = ' ';
                    };
                    a.free(self.title);
                    self.title = owned;
                }
            },
            7 => {
                // OSC 7: file://hostname/percent-encoded/path
                if (std.mem.startsWith(u8, payload, "file://")) {
                    const rest = payload[7..];
                    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return;
                    const decoded = try percentDecode(a, rest[slash..]);
                    errdefer a.free(decoded);
                    if (std.unicode.utf8ValidateSlice(decoded) and std.mem.indexOfScalar(u8, decoded, 0) == null) {
                        a.free(self.cwd);
                        self.cwd = decoded;
                    } else a.free(decoded);
                }
            },
            52 => {
                // OSC 52;c;<base64>
                const semi = std.mem.indexOfScalar(u8, payload, ';') orelse return;
                const b64 = payload[semi + 1 ..];
                if (b64.len == 0 or std.mem.eql(u8, b64, "?")) return;
                const decoder = std.base64.standard.Decoder;
                const size = decoder.calcSizeForSlice(b64) catch return;
                if (size > 1024 * 1024) return;
                const decoded = try a.alloc(u8, size);
                errdefer a.free(decoded);
                decoder.decode(decoded, b64) catch {
                    a.free(decoded);
                    return;
                };
                if (!std.unicode.utf8ValidateSlice(decoded)) {
                    a.free(decoded);
                    return;
                }
                if (self.pending_clipboard) |old| a.free(old);
                self.pending_clipboard = decoded;
            },
            else => {},
        }
    }
};

fn parseSgrSubparams(part: []const u8, out: []usize) usize {
    var split = std.mem.splitScalar(u8, part, ':');
    const command = std.fmt.parseInt(usize, split.next() orelse return 0, 10) catch return 0;
    const mode = std.fmt.parseInt(usize, split.next() orelse return 0, 10) catch return 0;
    if (command == 4 and out.len >= 1) {
        out[0] = if (mode == 0) 24 else 4;
        return 1;
    }
    if (command != 38 and command != 48) return 0;
    var colors: [4]usize = @splat(0);
    var count: usize = 0;
    while (split.next()) |component| {
        if (count == colors.len) return 0;
        colors[count] = if (component.len == 0) 0 else std.fmt.parseInt(usize, component, 10) catch return 0;
        count += 1;
    }
    if (mode == 2 and (count == 3 or count == 4) and out.len >= 5) {
        out[0] = command;
        out[1] = mode;
        @memcpy(out[2..5], colors[count - 3 .. count]);
        return 5;
    }
    if (mode == 5 and count == 1 and out.len >= 3) {
        out[0..3].* = .{ command, mode, colors[0] };
        return 3;
    }
    return 0;
}

fn decGraphic(byte: u8) u21 {
    const glyphs = [_]u21{
        '◆',
        '▒',
        '␉',
        '␌',
        '␍',
        '␊',
        '°',
        '±',
        '␤',
        '␋',
        '┘',
        '┐',
        '┌',
        '└',
        '┼',
        '⎺',
        '⎻',
        '─',
        '⎼',
        '⎽',
        '├',
        '┤',
        '┴',
        '┬',
        '│',
        '≤',
        '≥',
        'π',
        '≠',
        '£',
        '·',
    };
    return if (byte >= '`' and byte <= '~') glyphs[byte - '`'] else byte;
}

fn packRgb(r: usize, g: usize, b: usize) u24 {
    return (@as(u24, @intCast(@min(255, r))) << 16) |
        (@as(u24, @intCast(@min(255, g))) << 8) |
        @as(u24, @intCast(@min(255, b)));
}

fn percentDecode(a: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '%' and i + 2 < input.len) {
            if (std.fmt.parseInt(u8, input[i + 1 .. i + 3], 16)) |val| {
                try out.append(a, val);
                i += 3;
                continue;
            } else |_| {}
        }
        try out.append(a, input[i]);
        i += 1;
    }
    return out.toOwnedSlice(a);
}

pub fn charWidth(cp: u21) usize {
    if (cp == 0) return 0;
    // Combining diacritical marks & zero-width joiners.
    if ((cp >= 0x0300 and cp <= 0x036F) or
        (cp >= 0x1AB0 and cp <= 0x1AFF) or
        (cp >= 0x1DC0 and cp <= 0x1DFF) or
        (cp >= 0x20D0 and cp <= 0x20FF) or
        (cp >= 0xFE20 and cp <= 0xFE2F) or
        cp == 0x200B or cp == 0x200C or cp == 0x200D or cp == 0xFEFF)
        return 0;
    // East Asian Wide & common emoji blocks.
    if (cp >= 0x1100 and (cp <= 0x115F or
        cp == 0x2329 or cp == 0x232A or
        (cp >= 0x2E80 and cp <= 0xA4CF and cp != 0x303F) or
        (cp >= 0xAC00 and cp <= 0xD7A3) or
        (cp >= 0xF900 and cp <= 0xFAFF) or
        (cp >= 0xFE10 and cp <= 0xFE19) or
        (cp >= 0xFE30 and cp <= 0xFE6F) or
        (cp >= 0xFF00 and cp <= 0xFF60) or
        (cp >= 0xFFE0 and cp <= 0xFFE6) or
        (cp >= 0x1F300 and cp <= 0x1FAFF) or
        (cp >= 0x20000 and cp <= 0x3FFFD)))
        return 2;
    return 1;
}
