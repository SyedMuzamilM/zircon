//! Event-driven PTY sessions, smooth fractional scrolling, monotonic selection/copy,
//! bracketed paste, and run-batched terminal rendering.
const std = @import("std");
const term = @import("zircon_terminal");
const ui = @import("zircon_ui");
const store = @import("settings/store.zig");
const shell_module = @import("shell.zig");
const components = @import("views/components.zig");
const Shell = shell_module.Shell;
const native = ui.testing.native != void;

pub const ShellOptions = term.ShellOptions;

const pad_x: f32 = 8;
const pad_y: f32 = 6;
const ansi_palette = [16]u24{
    0x282c34, 0xe06c75, 0x98c379, 0xe5c07b,
    0x61afef, 0xc678dd, 0x56b6c2, 0xabb2bf,
    0x5c6370, 0xf27780, 0xa8d489, 0xf0cc8a,
    0x73bef8, 0xd487e8, 0x67c7d2, 0xffffff,
};

fn wakeUi() void {
    ui.App.wake();
}

pub const Session = struct {
    id: u32,
    terminal: term.Terminal,
    pty: ?*term.Pty = null,
    exited: bool = false,
    /// Pixels scrolled UP from the live bottom (0 = pinned to bottom).
    scroll_px: f32 = 0,
    selection: term.Selection = .{},
    dragging: bool = false,
    mouse_button: ?u8 = null,
    /// Cached cell geometry for accurate pointer hit-testing and resize.
    cell_w: f32 = 8.4,
    cell_h: f32 = 19.0,
    /// Cached fractional wheel accumulator for alternate-screen arrow translation.
    alt_wheel_acc: f32 = 0,

    pub fn init(a: std.mem.Allocator, id: u32, root: []const u8, options: ShellOptions) !Session {
        var terminal = try term.Terminal.init(a, 80, 24, term.Terminal.default_history);
        errdefer terminal.deinit(a);
        const proc = if (comptime native)
            try term.Pty.spawn(a, root, 80, 24, options, wakeUi)
        else
            null;
        return .{ .id = id, .terminal = terminal, .pty = proc };
    }

    pub fn deinit(self: *Session, a: std.mem.Allocator) void {
        if (self.pty) |proc| proc.destroy();
        self.terminal.deinit(a);
    }

    pub fn feed(self: *Session, a: std.mem.Allocator, bytes: []const u8) !void {
        const was_alt = self.terminal.in_alt_screen;
        const before_len = self.terminal.primary.len;
        const before_evicted = self.terminal.primary.evicted;
        try self.terminal.feed(a, bytes);
        if (was_alt != self.terminal.in_alt_screen) {
            self.selection.clear();
            self.dragging = false;
            self.mouse_button = null;
            self.alt_wheel_acc = 0;
        }
        if (!self.terminal.in_alt_screen and self.scroll_px > 0) {
            const added_lines = (self.terminal.primary.evicted - before_evicted) +
                (self.terminal.primary.len -| before_len);
            if (added_lines > 0) {
                self.scroll_px = @min(self.maxScrollPx(), self.scroll_px + @as(f32, @floatFromInt(added_lines)) * self.cell_h);
            }
        }
        if (self.terminal.responses.items.len > 0) {
            if (self.pty) |proc| proc.send(self.terminal.responses.items) catch {};
            self.terminal.responses.clearRetainingCapacity();
        }
    }

    pub fn send(self: *Session, bytes: []const u8) !void {
        if (self.pty) |proc| try proc.send(bytes);
    }

    pub fn maxScrollPx(self: *const Session) f32 {
        if (self.terminal.in_alt_screen) return 0;
        const s = self.terminal.activeScreenConst();
        return @as(f32, @floatFromInt(s.len -| s.rows)) * self.cell_h;
    }

    pub fn clampScroll(self: *Session) void {
        self.scroll_px = std.math.clamp(self.scroll_px, 0, self.maxScrollPx());
    }

    pub fn resize(self: *Session, a: std.mem.Allocator, cols: usize, rows: usize) !void {
        const c = @max(2, @min(500, cols));
        const r = @max(2, @min(200, rows));
        const s = self.terminal.activeScreenConst();
        if (c == s.cols and r == s.rows and c == self.terminal.primary.cols and r == self.terminal.primary.rows and
            c == self.terminal.alt.cols and r == self.terminal.alt.rows) return;
        try self.terminal.resize(a, c, r);
        self.selection.clear();
        self.dragging = false;
        if (self.pty) |proc| proc.resize(c, r);
        self.clampScroll();
    }

    pub fn titleSlice(self: *const Session) []const u8 {
        return self.terminal.title;
    }

    fn hitTest(self: *const Session, bounds: ui.Rect, point: ui.Point) struct { abs_line: u64, col: usize, view_row: usize } {
        const s = self.terminal.activeScreenConst();
        const scroll = if (self.terminal.in_alt_screen) @as(f32, 0) else std.math.clamp(self.scroll_px, 0, self.maxScrollPx());
        const whole_up: usize = @intFromFloat(@floor(scroll / self.cell_h));
        const frac_px = scroll - @as(f32, @floatFromInt(whole_up)) * self.cell_h;
        const bottom_idx = s.len -| whole_up;
        const top_idx = bottom_idx -| s.rows;
        const extra_top = frac_px > 0.001 and top_idx > 0;
        const render_start = if (extra_top) top_idx - 1 else top_idx;
        const y_shift = if (extra_top) self.cell_h - frac_px else 0;

        const rel_y = @max(0, point.y - (bounds.y + pad_y) + y_shift);
        const rel_x = @max(0, point.x - (bounds.x + pad_x));
        const row_off: usize = @intFromFloat(@floor(rel_y / self.cell_h));
        const logical = @min(s.len -| 1, render_start + row_off);
        const col = @min(s.cols, @as(usize, @intFromFloat(@floor(rel_x / self.cell_w))));
        const view_row = @min(s.rows -| 1, @as(usize, @intFromFloat(@floor(@max(0, point.y - (bounds.y + pad_y)) / self.cell_h))));
        return .{ .abs_line = s.absLineForLogical(logical), .col = col, .view_row = view_row };
    }
};

pub const Model = struct {
    options: ShellOptions = .{},
    sessions: std.ArrayList(Session) = .empty,
    active: usize = 0,
    next_id: u32 = 1,
    visible: bool = false,
    dock: store.TerminalDock = .bottom,
    ratio: f32 = 0.35,
    focus: u64 = 0,
    focused: bool = false,
    drag: ?struct { point: ui.Point, ratio: f32 } = null,

    pub fn deinit(self: *Model, a: std.mem.Allocator) void {
        for (self.sessions.items) |*session| session.deinit(a);
        self.sessions.deinit(a);
    }
};

const CellMetrics = struct { w: f32, h: f32, font: f32 };

fn gridSize(width: f32, height: f32, cell_w: f32, cell_h: f32) struct { cols: usize, rows: usize } {
    return .{
        .cols = @intFromFloat(std.math.clamp(@floor((width - pad_x * 2) / cell_w), 2, 500)),
        .rows = @intFromFloat(std.math.clamp(@floor((height - pad_y * 2) / cell_h), 2, 200)),
    };
}

fn cellMetrics(self: *const Shell, app: ?*ui.App) CellMetrics {
    const font = self.editor_options.font_size;
    const fallback_w = @max(6.0, font * 0.6);
    const fallback_h = @max(14.0, @ceil(font * 1.35));
    const runtime_app = app orelse return .{ .w = fallback_w, .h = fallback_h, .font = font };
    const handle = self.window orelse return .{ .w = fallback_w, .h = fallback_h, .font = font };
    const window = runtime_app.window(handle) catch return .{ .w = fallback_w, .h = fallback_h, .font = font };
    const surface = window.surface orelse return .{ .w = fallback_w, .h = fallback_h, .font = font };
    const measurer = surface.measurer();
    const style: ui.TextStyle = .{ .mono = true, .size = font };
    const measured = measurer.text(measurer.context, "M", style) catch return .{ .w = fallback_w, .h = fallback_h, .font = font };
    const advance = measurer.caret(" ", style, 1);
    const w = @max(4.0, if (advance > 0) advance else measured.width);
    const h = @max(font + 2.0, @ceil(@max(measured.height + 2.0, font * 1.35)));
    return .{ .w = w, .h = h, .font = font };
}

pub fn create(self: *Shell) !void {
    return createAt(self, self.workspace.root_path);
}

pub fn createAt(self: *Shell, directory: []const u8) !void {
    var session = try Session.init(self.allocator, self.terminal.next_id, directory, self.terminal.options);
    errdefer session.deinit(self.allocator);
    try self.terminal.sessions.append(self.allocator, session);
    self.terminal.next_id +%= 1;
    self.terminal.active = self.terminal.sessions.items.len - 1;
    self.terminal.visible = true;
    self.terminal.focus +%= 1;
    self.terminal.focused = true;
}

pub fn poll(self: *Shell, cx: *ui.Context(Shell)) !void {
    if (self.terminal.sessions.items.len == 0) return;
    if (self.terminal.visible) if (self.window) |handle| {
        const frame = &(try cx.app.window(handle)).frames.committed;
        for (frame.nodes.items, frame.bounds) |node, bounds| if (node.key) |key| if (key == .string and std.mem.eql(u8, key.string, "terminal-canvas")) {
            const session = &self.terminal.sessions.items[self.terminal.active];
            const metrics = cellMetrics(self, &cx.app);
            if (try resizeToBounds(session, self.allocator, bounds, metrics)) cx.notify();
            break;
        };
    };

    var any_changed = false;
    var chunk_buf: [16384]u8 = undefined;
    for (self.terminal.sessions.items, 0..) |*session, index| {
        if (session.pty) |proc| {
            var budget: usize = 0;
            while (budget < 16 and proc.hasData()) : (budget += 1) {
                const drained = proc.drain(&chunk_buf);
                if (drained.len == 0) break;
                try session.feed(self.allocator, drained);
                any_changed = true;
            }
            proc.acknowledge();
            if (!session.exited and proc.isExited()) {
                session.exited = true;
                any_changed = true;
            }
        }
        if (session.terminal.takeClipboard()) |clip| {
            defer self.allocator.free(clip);
            if (!self.terminal.visible or index != self.terminal.active) continue;
            if (self.window) |handle| if ((try cx.app.window(handle)).surface) |surface| {
                surface.ops.clipboard_write(surface.context, clip) catch {};
            };
        }
    }
    if (any_changed) cx.notify();
}

fn resizeToBounds(session: *Session, a: std.mem.Allocator, bounds: ui.Rect, metrics: CellMetrics) !bool {
    const size = gridSize(bounds.width, bounds.height, metrics.w, metrics.h);
    const geometry_changed = session.cell_w != metrics.w or session.cell_h != metrics.h;
    if (geometry_changed) session.scroll_px *= metrics.h / session.cell_h;
    session.cell_w = metrics.w;
    session.cell_h = metrics.h;
    const screen = session.terminal.activeScreenConst();
    const grid_changed = size.cols != screen.cols or size.rows != screen.rows;
    try session.resize(a, size.cols, size.rows);
    return geometry_changed or grid_changed;
}

fn select(self: *Shell, _: *ui.Event(ui.Click), cx: *ui.Context(Shell), id: u32) void {
    for (self.terminal.sessions.items, 0..) |session, i| if (session.id == id) {
        self.terminal.active = i;
        self.terminal.focus +%= 1;
        self.terminal.focused = true;
        break;
    };
    cx.notify();
}

fn closeTab(self: *Shell, _: *ui.Event(ui.Click), cx: *ui.Context(Shell), id: u32) void {
    for (self.terminal.sessions.items, 0..) |session, i| if (session.id == id) {
        var removed = self.terminal.sessions.orderedRemove(i);
        removed.deinit(self.allocator);
        self.terminal.active = if (i < self.terminal.active) self.terminal.active - 1 else @min(self.terminal.active, self.terminal.sessions.items.len -| 1);
        break;
    };
    if (self.terminal.sessions.items.len == 0) {
        self.terminal.visible = false;
        self.terminal.focused = false;
        self.editor_focus_request +%= 1;
    }
    cx.notify();
}

fn sendMouse(session: *Session, button_code: u8, modifiers: ui.Modifiers, col: usize, row: usize, pressed: bool) !void {
    const flags: u8 = (if (modifiers.shift) @as(u8, 4) else 0) |
        (if (modifiers.alt) @as(u8, 8) else 0) | (if (modifiers.control) @as(u8, 16) else 0);
    if (session.terminal.mouse_sgr) {
        var buf: [32]u8 = undefined;
        const seq = try std.fmt.bufPrint(&buf, "\x1b[<{d};{d};{d}{c}", .{ button_code | flags, col + 1, row + 1, @as(u8, if (pressed) 'M' else 'm') });
        try session.send(seq);
    } else if (col < 223 and row < 223) {
        const code = if (pressed) button_code else 3;
        try session.send(&.{ 0x1b, '[', 'M', (code | flags) + 32, @intCast(col + 33), @intCast(row + 33) });
    }
}

pub fn input(self: *Shell, e: *ui.Event(ui.Input), cx: *ui.Context(Shell)) !void {
    if (self.terminal.sessions.items.len == 0) return;
    const session = &self.terminal.sessions.items[self.terminal.active];
    switch (e.data) {
        .focus => |focused| {
            self.terminal.focused = focused;
            if (!focused) {
                session.dragging = false;
                session.mouse_button = null;
            }
        },
        .pointer_down => |p| {
            self.terminal.focused = true;
            e.focus();
            const hit = session.hitTest(e.bounds, p.position);
            // Forward mouse events to TUI apps unless Shift is held (Shift forces local selection).
            if (session.terminal.mouse_mode != .none and !p.modifiers.shift and session.scroll_px == 0) {
                const code: u8 = switch (p.button) {
                    .primary => 0,
                    .middle => 1,
                    .secondary => 2,
                };
                try sendMouse(session, code, p.modifiers, hit.col, hit.view_row, true);
                session.mouse_button = code;
                e.capturePointer();
                e.preventDefault();
                cx.notify();
                return;
            }
            if (p.button == .primary) {
                const screen = session.terminal.activeScreenConst();
                if (p.modifiers.shift and session.selection.active) {
                    session.selection.extendTo(screen, hit.abs_line, hit.col);
                } else {
                    const mode: term.selection.Mode = if (p.clicks >= 3) .line else if (p.clicks == 2) .word else .char;
                    session.selection.startAt(screen, hit.abs_line, hit.col, mode);
                }
                session.dragging = true;
                e.capturePointer();
                e.preventDefault();
            }
        },
        .pointer_move => |p| {
            const hit = session.hitTest(e.bounds, p.position);
            if (!session.dragging) {
                const reports_motion = session.terminal.mouse_mode == .any or
                    (session.terminal.mouse_mode == .drag and session.mouse_button != null);
                if (reports_motion and session.scroll_px == 0 and !p.modifiers.shift) {
                    try sendMouse(session, (session.mouse_button orelse 3) | 32, p.modifiers, hit.col, hit.view_row, true);
                    e.preventDefault();
                }
                return;
            }
            session.selection.extendTo(session.terminal.activeScreenConst(), hit.abs_line, hit.col);
            e.preventDefault();
        },
        .pointer_up => |p| {
            const hit = session.hitTest(e.bounds, p.position);
            if (session.dragging) {
                session.dragging = false;
                e.releasePointer();
                e.preventDefault();
            } else if (session.mouse_button) |code| {
                session.mouse_button = null;
                e.releasePointer();
                e.preventDefault();
                if (session.terminal.mouse_mode != .none) try sendMouse(session, code, p.modifiers, hit.col, hit.view_row, false);
            }
        },
        .scroll => |scroll| {
            if (!std.math.isFinite(scroll.y) or scroll.y == 0) return;
            if (session.terminal.mouse_mode != .none and !scroll.modifiers.shift and (session.terminal.in_alt_screen or session.scroll_px == 0)) {
                const hit = session.hitTest(e.bounds, scroll.position);
                const step = session.cell_h;
                session.alt_wheel_acc += std.math.clamp(scroll.y, -step * 20, step * 20);
                while (@abs(session.alt_wheel_acc) >= step) {
                    const up = session.alt_wheel_acc > 0;
                    try sendMouse(session, if (up) 64 else 65, scroll.modifiers, hit.col, hit.view_row, true);
                    session.alt_wheel_acc += if (up) -step else step;
                }
            } else if (session.terminal.in_alt_screen) {
                const step = session.cell_h;
                session.alt_wheel_acc += std.math.clamp(scroll.y, -step * 20, step * 20);
                const up_seq = if (session.terminal.app_cursor_keys) "\x1bOA" else "\x1b[A";
                const down_seq = if (session.terminal.app_cursor_keys) "\x1bOB" else "\x1b[B";
                while (@abs(session.alt_wheel_acc) >= step) {
                    const up = session.alt_wheel_acc > 0;
                    try session.send(if (up) up_seq else down_seq);
                    session.alt_wheel_acc += if (up) -step else step;
                }
            } else {
                session.scroll_px = std.math.clamp(session.scroll_px + scroll.y, 0, session.maxScrollPx());
            }
            e.preventDefault();
        },
        .text => |bytes| {
            session.selection.clear();
            try session.send(bytes);
            session.scroll_px = 0;
            e.preventDefault();
        },
        .key_down => |key| {
            if (key.modifiers.command) {
                if (key.key == .c) {
                    if (!session.selection.isEmpty()) {
                        const copied = try term.selection.extractText(self.allocator, session.terminal.activeScreenConst(), session.selection);
                        defer self.allocator.free(copied);
                        if (copied.len != 0) try e.writeClipboard(copied);
                    }
                    e.preventDefault();
                    e.stopPropagation();
                    cx.notify();
                    return;
                }
                if (key.key == .a) {
                    session.selection.selectAll(session.terminal.activeScreenConst());
                    e.preventDefault();
                    e.stopPropagation();
                    cx.notify();
                    return;
                }
                if (key.key == .k) {
                    session.terminal.clear();
                    session.scroll_px = 0;
                    session.selection.clear();
                    e.preventDefault();
                    e.stopPropagation();
                    cx.notify();
                    return;
                }
                if (key.key == .v) {
                    const bytes = try e.readClipboard(self.allocator);
                    defer self.allocator.free(bytes);
                    session.selection.clear();
                    try paste(session, self.allocator, bytes);
                    session.scroll_px = 0;
                    e.preventDefault();
                    e.stopPropagation();
                    cx.notify();
                    return;
                }
                return;
            }
            if (key.modifiers.shift and (key.key == .page_up or key.key == .page_down)) {
                const page = @max(session.cell_h, e.bounds.height - pad_y * 2);
                session.scroll_px = std.math.clamp(
                    session.scroll_px + (if (key.key == .page_up) page else -page),
                    0,
                    session.maxScrollPx(),
                );
                e.preventDefault();
                e.stopPropagation();
                cx.notify();
                return;
            }

            const app_keys = session.terminal.app_cursor_keys;
            const bytes: []const u8 = switch (key.key) {
                .enter => "\r",
                .backspace => "\x7f",
                .tab => if (key.modifiers.shift) "\x1b[Z" else "\t",
                .escape => "\x1b",
                .up => if (app_keys) "\x1bOA" else "\x1b[A",
                .down => if (app_keys) "\x1bOB" else "\x1b[B",
                .right => if (app_keys) "\x1bOC" else "\x1b[C",
                .left => if (app_keys) "\x1bOD" else "\x1b[D",
                .home => if (app_keys) "\x1bOH" else "\x1b[H",
                .end => if (app_keys) "\x1bOF" else "\x1b[F",
                .delete => "\x1b[3~",
                .page_up => "\x1b[5~",
                .page_down => "\x1b[6~",
                .f1 => "\x1bOP",
                .f2 => "\x1bOQ",
                .f3 => "\x1bOR",
                .f4 => "\x1bOS",
                .f5 => "\x1b[15~",
                .f6 => "\x1b[17~",
                .f7 => "\x1b[18~",
                .f8 => "\x1b[19~",
                .f9 => "\x1b[20~",
                .f10 => "\x1b[21~",
                .f11 => "\x1b[23~",
                .f12 => "\x1b[24~",
                else => "",
            };
            if (key.modifiers.control and @backingInt(key.key) >= @backingInt(ui.Key.a) and @backingInt(key.key) <= @backingInt(ui.Key.z)) {
                const control = [_]u8{@intCast(@backingInt(key.key) - @backingInt(ui.Key.a) + 1)};
                session.selection.clear();
                try session.send(&control);
            } else if (bytes.len > 0) {
                session.selection.clear();
                try session.send(bytes);
            } else return;
            session.scroll_px = 0;
            e.preventDefault();
            e.stopPropagation();
        },
        else => return,
    }
    cx.notify();
}

fn paste(session: *Session, a: std.mem.Allocator, bytes: []const u8) !void {
    if (!session.terminal.bracketed_paste) return session.send(bytes);
    const start = "\x1b[200~";
    const end = "\x1b[201~";
    if (bytes.len > term.pty.ByteRing.capacity - start.len - end.len) return error.TerminalInputFull;
    const packet = try a.alloc(u8, start.len + bytes.len + end.len);
    defer a.free(packet);
    @memcpy(packet[0..start.len], start);
    var len: usize = start.len;
    for (bytes) |byte| {
        // An embedded escape could prematurely close the paste delimiters.
        if (byte == 0x1b) continue;
        packet[len] = byte;
        len += 1;
    }
    @memcpy(packet[len..][0..end.len], end);
    try session.send(packet[0 .. len + end.len]);
}

pub fn onDivider(self: *Shell, event: *ui.Event(ui.Input), cx: *ui.Context(Shell)) !void {
    switch (event.data) {
        .pointer_down => |pointer| {
            self.terminal.drag = .{ .point = pointer.position, .ratio = self.terminal.ratio };
            event.capturePointer();
        },
        .pointer_move => |pointer| if (self.terminal.drag) |drag| {
            const size = try event.windowSize();
            const distance = if (self.terminal.dock == .bottom) drag.point.y - pointer.position.y else drag.point.x - pointer.position.x;
            const available = if (self.terminal.dock == .bottom) size.height - 58 else size.width - (if (self.sidebar_visible) self.panelWidth() else 0);
            self.terminal.ratio = std.math.clamp(drag.ratio + distance / @max(1, available), 0.15, 0.75);
        },
        .pointer_up => {
            self.terminal.drag = null;
            event.releasePointer();
        },
        .focus => |focused| {
            if (!focused) self.terminal.drag = null;
        },
        else => return,
    }
    event.preventDefault();
    cx.notify();
}

const Canvas = struct {
    cells: []term.Cell,
    cols: usize,
    rows: usize,
    grid_cols: usize,
    grid_rows: usize,
    first_abs_line: u64,
    y_shift: f32,
    cell_w: f32,
    cell_h: f32,
    font_size: f32,
    cursor_row: ?usize,
    cursor_col: usize,
    selection: term.Selection,
    background: ui.Color,
    foreground: ui.Color,
    selection_bg: ui.Color,
    bg_rgb: u24,
    fg_rgb: u24,

    pub const LayoutState = void;
    pub const PrepaintState = void;

    pub fn requestLayout(_: *Canvas, cx: *ui.LayoutCx) !ui.LayoutResult(void) {
        return .{ .size = cx.available, .state = {} };
    }

    pub fn prepaint(self: *Canvas, cx: *ui.PrepaintCx, bounds: ui.Rect, _: *void) !void {
        const size = gridSize(bounds.width, bounds.height, self.cell_w, self.cell_h);
        // The external poll sees actual bounds only after this frame commits.
        if (size.cols != self.grid_cols or size.rows != self.grid_rows) try cx.requestFrameAfter(0.001);
    }

    pub fn paint(self: *Canvas, cx: *ui.PaintCx, bounds: ui.Rect, _: *void, _: *void) !void {
        try cx.painter.fillRect(.{ .bounds = bounds, .color = self.background });
        try cx.painter.pushClip(bounds);
        defer cx.painter.popClip();

        var run_buf: std.ArrayList(u8) = .empty;
        const base_style: ui.TextStyle = .{ .mono = true, .size = self.font_size };
        const glyph_h = (cx.measurer.text(cx.measurer.context, "M", base_style) catch ui.Size{ .width = self.cell_w, .height = self.font_size }).height;
        const text_y_off = @max(0, (self.cell_h - glyph_h) * 0.5);

        for (0..self.rows) |row_i| {
            const row_y = bounds.y + pad_y + @as(f32, @floatFromInt(row_i)) * self.cell_h - self.y_shift;
            if (row_y + self.cell_h < bounds.y or row_y >= bounds.y + bounds.height) continue;
            const row_cells = self.cells[row_i * self.cols ..][0..self.cols];
            const abs_line = self.first_abs_line + @as(u64, @intCast(row_i));
            const sel = self.selection.lineRange(abs_line, self.cols);

            // Pass 1: merged background quads (cell bg, inverse, and selection).
            var col: usize = 0;
            while (col < self.cols) {
                const bg = self.effectiveBg(row_cells[col], sel != null and col >= sel.?.start and col < sel.?.end);
                if (bg == null) {
                    col += 1;
                    continue;
                }
                const start_col = col;
                col += 1;
                while (col < self.cols) : (col += 1) {
                    const next_bg = self.effectiveBg(row_cells[col], sel != null and col >= sel.?.start and col < sel.?.end);
                    if (next_bg == null or !std.meta.eql(next_bg.?, bg.?)) break;
                }
                try cx.painter.fillRect(.{
                    .bounds = .{
                        .x = bounds.x + pad_x + @as(f32, @floatFromInt(start_col)) * self.cell_w,
                        .y = row_y,
                        .width = @as(f32, @floatFromInt(col - start_col)) * self.cell_w,
                        .height = self.cell_h,
                    },
                    .color = bg.?,
                });
            }

            // A text command covers each run of matching cells. Wide glyphs
            // start a separate command so fallback fonts cannot shift the next run.
            col = 0;
            while (col < self.cols) {
                const cell = row_cells[col];
                const decorated = cell.style.underline or cell.style.strikethrough;
                if ((cell.code == ' ' and !decorated) or cell.style.wide_trail) {
                    col += 1;
                    continue;
                }
                const start = col;
                const fg = self.effectiveFg(cell);
                run_buf.clearRetainingCapacity();
                while (col < self.cols) {
                    const current = row_cells[col];
                    if (col != start and (current.style.wide_lead or current.style.wide_trail or
                        !std.meta.eql(self.effectiveFg(current), fg) or !current.style.visualEql(cell.style))) break;
                    var encoded: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(current.code, &encoded) catch 0;
                    try run_buf.appendSlice(cx.painter.allocator, encoded[0..len]);
                    col += 1;
                    if (current.style.wide_lead) {
                        if (col < self.cols and row_cells[col].style.wide_trail) col += 1;
                        break;
                    }
                }

                const x = bounds.x + pad_x + @as(f32, @floatFromInt(start)) * self.cell_w;
                const width = @as(f32, @floatFromInt(col - start)) * self.cell_w;
                const text = std.mem.trimEnd(u8, run_buf.items, " ");
                if (text.len != 0) try cx.painter.drawText(.{
                    .bounds = .{ .x = x, .y = row_y + text_y_off, .width = width + 4, .height = glyph_h },
                    .text = text,
                    .style = .{ .mono = true, .size = self.font_size, .color = fg },
                });
                if (cell.style.underline) try cx.painter.fillRect(.{
                    .bounds = .{ .x = x, .y = row_y + self.cell_h - 2, .width = width, .height = 1 },
                    .color = fg,
                });
                if (cell.style.strikethrough) try cx.painter.fillRect(.{
                    .bounds = .{ .x = x, .y = row_y + self.cell_h * 0.5, .width = width, .height = 1 },
                    .color = fg,
                });
            }
        }

        if (self.cursor_row) |row| {
            const cy = bounds.y + pad_y + @as(f32, @floatFromInt(row)) * self.cell_h - self.y_shift;
            const cx_pos = bounds.x + pad_x + @as(f32, @floatFromInt(self.cursor_col)) * self.cell_w;
            if (cx.focused) {
                try cx.painter.fillRect(.{
                    .bounds = .{ .x = cx_pos, .y = cy + 1, .width = 2, .height = @max(1, self.cell_h - 2) },
                    .radius = 1,
                    .color = self.foreground,
                });
            } else {
                try cx.painter.strokeRect(.{ .x = cx_pos, .y = cy + 1, .width = self.cell_w, .height = @max(1, self.cell_h - 2) }, self.foreground, 1);
            }
        }
    }

    fn effectiveBg(self: *const Canvas, cell: term.Cell, selected: bool) ?ui.Color {
        if (selected) return self.selection_bg;
        if (cell.style.inverse) {
            return ui.Color.rgb(cell.fg.resolve(ansi_palette, self.fg_rgb));
        }
        return switch (cell.bg) {
            .default => null,
            else => ui.Color.rgb(cell.bg.resolve(ansi_palette, self.bg_rgb)),
        };
    }

    fn effectiveFg(self: *const Canvas, cell: term.Cell) ui.Color {
        const fg: term.Color = if (cell.style.bold and cell.fg == .indexed and cell.fg.indexed < 8)
            .{ .indexed = cell.fg.indexed + 8 }
        else
            cell.fg;
        var col = if (cell.style.inverse)
            ui.Color.rgb(cell.bg.resolve(ansi_palette, self.bg_rgb))
        else if (fg == .default)
            self.foreground
        else
            ui.Color.rgb(fg.resolve(ansi_palette, self.fg_rgb));
        if (cell.style.dim) col.a *= 0.65;
        return col;
    }
};

fn colorToRgb24(c: ui.Color) u24 {
    const r: u24 = @intFromFloat(std.math.clamp(c.r, 0, 1) * 255.0);
    const g: u24 = @intFromFloat(std.math.clamp(c.g, 0, 1) * 255.0);
    const b: u24 = @intFromFloat(std.math.clamp(c.b, 0, 1) * 255.0);
    return (r << 16) | (g << 8) | b;
}

pub fn render(self: *const Shell, b: *ui.Ui, width: f32, height: f32) !ui.Element {
    const v = components;
    const c = self.colors;
    var tabs: std.ArrayList(ui.Element) = .empty;
    for (self.terminal.sessions.items, 0..) |session, i| {
        const dynamic = session.titleSlice();
        const name = if (dynamic.len > 0)
            try std.fmt.allocPrint(b.allocator(), "{s}{s}", .{ dynamic, if (session.exited) " · exited" else "" })
        else
            try std.fmt.allocPrint(b.allocator(), "Terminal {d}{s}", .{ session.id, if (session.exited) " · exited" else "" });
        try tabs.append(b.allocator(), try b.fluent().div()
            .h(.{ .px = 32 })
            .background(if (i == self.terminal.active) c.document else c.tab_bar)
            .items_center()
            .flex()
            .children(.{
                b.fluent().button(.{ .label = name })
                    .flex()
                    .h(.{ .px = 32 })
                    .gap_px(5)
                    .padding(.{ .left = 10, .right = 6 })
                    .items_center()
                    .on_click(b.onClickWith(select, session.id))
                    .children(&.{
                    try v.icon(b, .terminal, c.muted, 13),
                    try v.text(b, name, c.text, 12),
                }),
                b.fluent().button(.{ .label = "Close terminal" })
                    .w(.{ .px = 22 })
                    .h(.{ .px = 22 })
                    .items_center()
                    .justify_center()
                    .hover_background(c.hover)
                    .on_click(b.onClickWith(closeTab, session.id))
                    .children(&.{try v.icon(b, .close, c.muted, 12)}),
            }).build());
    }
    try tabs.append(b.allocator(), try b.fluent().div().grow().children(.{}).build());
    try tabs.append(b.allocator(), try v.iconButton(b, c, .new_terminal, "New terminal", .plus, false));
    try tabs.append(b.allocator(), try v.iconButton(b, c, if (self.terminal.dock == .bottom) .terminal_right else .terminal_bottom, if (self.terminal.dock == .bottom) "Dock terminal right" else "Dock terminal bottom", .split, false));
    try tabs.append(b.allocator(), try v.iconButton(b, c, .toggle_terminal, "Hide terminal", .close, false));

    const metrics = cellMetrics(self, b.frame.app);
    const session = &self.terminal.sessions.items[self.terminal.active];
    const screen = session.terminal.activeScreenConst();
    const visible_grid = gridSize(width, height - 32, metrics.w, metrics.h);
    const view_cols = @min(screen.cols, visible_grid.cols);
    const view_rows = visible_grid.rows;

    const scroll = if (session.terminal.in_alt_screen) @as(f32, 0) else std.math.clamp(session.scroll_px, 0, session.maxScrollPx());
    const whole_up: usize = @intFromFloat(@floor(scroll / metrics.h));
    const frac_px = scroll - @as(f32, @floatFromInt(whole_up)) * metrics.h;
    const end = screen.len -| whole_up;
    const base_start = end -| view_rows;
    const extra_top = frac_px > 0.001 and base_start > 0;
    const start = if (extra_top) base_start - 1 else base_start;
    const render_rows = end - start;
    const y_shift = if (extra_top) metrics.h - frac_px else 0;

    const cells = try b.allocator().alloc(term.Cell, view_cols * @max(1, render_rows));
    @memset(cells, term.Cell.blank);
    for (0..render_rows) |r| {
        const src = screen.rowConst(start + r).cells;
        const n = @min(view_cols, src.len);
        @memcpy(cells[r * view_cols ..][0..n], src[0..n]);
    }

    const cursor_logical = screen.viewBase() + session.terminal.row;
    const cursor_row: ?usize = if (session.terminal.cursor_visible and cursor_logical >= start and cursor_logical < end)
        cursor_logical - start
    else
        null;

    var sel_bg = c.accent;
    sel_bg.a = 0.28;

    const canvas = try b.custom(Canvas, .{
        .cells = cells,
        .cols = view_cols,
        .rows = render_rows,
        .grid_cols = screen.cols,
        .grid_rows = screen.rows,
        .first_abs_line = screen.absLineForLogical(start),
        .y_shift = y_shift,
        .cell_w = metrics.w,
        .cell_h = metrics.h,
        .font_size = metrics.font,
        .cursor_row = cursor_row,
        .cursor_col = @min(session.terminal.col, view_cols - 1),
        .selection = session.selection,
        .background = c.document,
        .foreground = c.text,
        .selection_bg = sel_bg,
        .bg_rgb = colorToRgb24(c.document),
        .fg_rgb = colorToRgb24(c.text),
    }, .{ .flex_grow = 1, .min_height = .{ .px = 0 }, .overflow = .hidden });

    const surface = try b.fluent().adopt(canvas)
        .id(.{ .string = "terminal-canvas" })
        .listeners(.{ .focusable = true, .on_input = b.onInput(input) })
        .request_focus(self.terminal.focus)
        .build();

    return b.fluent().div()
        .w(.{ .px = width })
        .h(.{ .px = height })
        .shrink_0()
        .min_w(.{ .px = 0 })
        .min_h(.{ .px = 0 })
        .overflow_hidden()
        .flex_col()
        .children(.{
            b.fluent().div()
                .h(.{ .px = 32 })
                .shrink_0()
                .background(c.tab_bar)
                .overflow_hidden()
                .flex()
                .children(tabs.items),
            surface,
        }).id(.{ .string = "terminal-panel" }).build();
}

pub fn closeActive(self: *Shell, cx: *ui.Context(Shell)) !void {
    if (self.terminal.sessions.items.len == 0) return;
    var event: ui.Event(ui.Click) = .{ .data = .{} };
    closeTab(self, &event, cx, self.terminal.sessions.items[self.terminal.active].id);
}
