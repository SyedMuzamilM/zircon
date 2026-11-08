//! PTY session ownership, ANSI grid updates and the terminal dock UI.
//! Native process transport is currently macOS-specific; portable builds keep the model.
const std = @import("std");
const ui = @import("zircon_ui");
const store = @import("settings/store.zig");
const shell_module = @import("shell.zig");
const components = @import("views/components.zig");
const Shell = shell_module.Shell;
const native = ui.testing.native != void;
const Cell = struct { code: u21 = ' ', fg: ?u8 = null, bg: ?u8 = null };
const Line = struct { cells: []Cell };
const Winsize = extern struct { row: u16, col: u16, xpixel: u16 = 0, ypixel: u16 = 0 };
extern "c" fn openpty(*c_int, *c_int, ?*anyopaque, ?*anyopaque, *const Winsize) c_int;
extern "c" fn fork() c_int;
extern "c" fn setsid() c_int;
extern "c" fn ioctl(c_int, c_ulong, ...) c_int;
extern "c" fn dup2(c_int, c_int) c_int;
extern "c" fn close(c_int) c_int;
extern "c" fn chdir([*:0]const u8) c_int;
extern "c" fn execve([*:0]const u8, [*:null]const ?[*:0]const u8, [*:null]const ?[*:0]const u8) c_int;
extern "c" fn _exit(c_int) noreturn;
extern "c" fn _NSGetEnviron() *[*:null]?[*:0]u8;
extern "c" fn getenv([*:0]const u8) ?[*:0]const u8;
extern "c" fn fcntl(c_int, c_int, ...) c_int;
extern "c" fn read(c_int, [*]u8, usize) isize;
extern "c" fn write(c_int, [*]const u8, usize) isize;
extern "c" fn kill(c_int, c_int) c_int;
extern "c" fn waitpid(c_int, *c_int, c_int) c_int;
pub const ShellOptions = struct { command: ?[]const u8 = null, args: []const []const u8 = &.{"-l"} };
pub const Session = struct {
    id: u32,
    fd: c_int = -1,
    pid: c_int = -1,
    exited: bool = false,
    cols: usize = 80,
    rows: usize = 24,
    lines: std.ArrayList(Line) = .empty,
    row: usize = 0,
    col: usize = 0,
    saved_row: usize = 0,
    saved_col: usize = 0,
    fg: ?u8 = null,
    bg: ?u8 = null,
    cursor_visible: bool = true,
    scroll: usize = 0,
    parser: enum { text, escape, csi, osc, osc_escape } = .text,
    sequence: [128]u8 = undefined,
    sequence_len: usize = 0,
    utf8: [4]u8 = undefined,
    utf8_len: usize = 0,
    pub fn init(a: std.mem.Allocator, id: u32, root: []const u8, options: ShellOptions) !Session {
        var self: Session = .{ .id = id };
        errdefer self.deinit(a);
        try self.ensureLine(a, 0);
        if (comptime native) {
            const cwd = try a.dupeSentinel(u8, root, 0);
            defer a.free(cwd);
            const shell = try a.dupeSentinel(u8, options.command orelse if (getenv("SHELL")) |value| std.mem.span(value) else "/bin/zsh", 0);
            defer a.free(shell);
            var argv: std.ArrayList(?[*:0]const u8) = .empty;
            defer {
                for (argv.items[@min(1, argv.items.len)..]) |arg| if (arg) |value| a.free(std.mem.span(value));
                argv.deinit(a);
            }
            try argv.append(a, shell);
            for (options.args) |arg| {
                const value = try a.dupeSentinel(u8, arg, 0);
                errdefer a.free(value);
                try argv.append(a, value);
            }
            try argv.append(a, null);
            var env: std.ArrayList(?[*:0]const u8) = .empty;
            defer env.deinit(a);
            const inherited = _NSGetEnviron().*;
            var i: usize = 0;
            while (inherited[i]) |entry| : (i += 1) {
                const bytes = std.mem.span(entry);
                if (!std.mem.startsWith(u8, bytes, "TERM=") and !std.mem.startsWith(u8, bytes, "COLORTERM=")) try env.append(a, entry);
            }
            try env.appendSlice(a, &.{ "TERM=xterm-256color", "COLORTERM=truecolor", null });
            var master: c_int = -1;
            var slave: c_int = -1;
            if (openpty(&master, &slave, null, null, &.{ .row = 24, .col = 80 }) != 0) return error.TerminalOpenFailed;
            errdefer _ = close(master);
            defer _ = close(slave);
            _ = fcntl(master, 2, @as(c_int, 1));
            const pid = fork();
            if (pid < 0) return error.TerminalSpawnFailed;
            if (pid == 0) {
                _ = close(master);
                _ = setsid();
                _ = ioctl(slave, @as(c_ulong, 0x20007461), @as(c_int, 0));
                _ = dup2(slave, 0);
                _ = dup2(slave, 1);
                _ = dup2(slave, 2);
                if (slave > 2) _ = close(slave);
                if (chdir(cwd) != 0) _exit(126);
                _ = execve(shell, @ptrCast(argv.items.ptr), @ptrCast(env.items.ptr));
                _exit(127);
            }
            self.fd = master;
            self.pid = pid;
            _ = fcntl(master, 4, @as(c_int, 4));
        }
        return self;
    }
    pub fn deinit(self: *Session, a: std.mem.Allocator) void {
        if (comptime native) {
            if (self.fd >= 0) _ = close(self.fd);
            if (self.pid > 0) {
                _ = kill(-self.pid, 1);
                _ = kill(self.pid, 9);
                var status: c_int = 0;
                _ = waitpid(self.pid, &status, 0);
            }
        }
        for (self.lines.items) |line| a.free(line.cells);
        self.lines.deinit(a);
    }
    fn ensureLine(self: *Session, a: std.mem.Allocator, row: usize) !void {
        while (self.lines.items.len <= row) {
            const cells = try a.alloc(Cell, self.cols);
            errdefer a.free(cells);
            @memset(cells, .{});
            try self.lines.append(a, .{ .cells = cells });
        }
    }
    fn base(self: *const Session) usize {
        return self.lines.items.len -| self.rows;
    }
    fn newline(self: *Session, a: std.mem.Allocator) !void {
        self.row += 1;
        try self.ensureLine(a, self.row);
        if (self.lines.items.len > 2000) {
            const removed = self.lines.orderedRemove(0);
            a.free(removed.cells);
            self.row -|= 1;
        }
    }
    fn put(self: *Session, a: std.mem.Allocator, code: u21) !void {
        if (self.col >= self.cols) {
            self.col = 0;
            try self.newline(a);
        }
        try self.ensureLine(a, self.row);
        self.lines.items[self.row].cells[self.col] = .{ .code = code, .fg = self.fg, .bg = self.bg };
        self.col += 1;
    }
    pub fn feed(self: *Session, a: std.mem.Allocator, bytes: []const u8) !void {
        for (bytes) |byte| switch (self.parser) {
            .text => {
                if (byte == 27) {
                    self.parser = .escape;
                    self.utf8_len = 0;
                } else if (byte == '\r') self.col = 0 else if (byte == '\n') try self.newline(a) else if (byte == 8) self.col -|= 1 else if (byte == 9) self.col = @min(self.cols, (self.col / 8 + 1) * 8) else if (byte >= 32 and byte < 127) try self.put(a, byte) else if (byte >= 128) {
                    if (self.utf8_len < 4) {
                        self.utf8[self.utf8_len] = byte;
                        self.utf8_len += 1;
                    }
                    const len = std.unicode.utf8ByteSequenceLength(self.utf8[0]) catch {
                        self.utf8_len = 0;
                        continue;
                    };
                    if (self.utf8_len == len) {
                        const code = std.unicode.utf8Decode(self.utf8[0..len]) catch 0xfffd;
                        try self.put(a, code);
                        self.utf8_len = 0;
                    }
                }
            },
            .escape => {
                self.parser = switch (byte) {
                    '[' => .csi,
                    ']' => .osc,
                    else => .text,
                };
                self.sequence_len = 0;
                if (byte == '7') {
                    self.saved_row = self.row;
                    self.saved_col = self.col;
                }
                if (byte == '8') {
                    self.row = @min(self.saved_row, self.lines.items.len - 1);
                    self.col = @min(self.saved_col, self.cols - 1);
                }
            },
            .csi => {
                if (byte >= 0x40 and byte <= 0x7e) {
                    try self.csi(a, byte);
                    self.parser = .text;
                } else if (self.sequence_len < self.sequence.len) {
                    self.sequence[self.sequence_len] = byte;
                    self.sequence_len += 1;
                }
            },
            .osc => {
                if (byte == 7) self.parser = .text else if (byte == 27) self.parser = .osc_escape;
            },
            .osc_escape => {
                self.parser = if (byte == '\\') .text else .osc;
            },
        };
    }
    fn csi(self: *Session, a: std.mem.Allocator, final: u8) !void {
        const sequence = self.sequence[0..self.sequence_len];
        var args: [16]usize = @splat(0);
        var parts = std.mem.splitScalar(u8, std.mem.trimStart(u8, sequence, "?<>"), ';');
        var n: usize = 0;
        while (parts.next()) |part| {
            if (n == args.len) break;
            args[n] = std.fmt.parseInt(usize, part, 10) catch 0;
            n += 1;
        }
        const amount = @max(1, args[0]);
        switch (final) {
            'A' => self.row = @max(self.base(), self.row -| amount),
            'B' => {
                self.row = @min(self.base() + self.rows - 1, self.row + amount);
                try self.ensureLine(a, self.row);
            },
            'C' => self.col = @min(self.cols - 1, self.col + amount),
            'D' => self.col -|= amount,
            'G' => self.col = @min(self.cols - 1, amount - 1),
            'H', 'f' => {
                self.row = self.base() + @min(self.rows - 1, amount - 1);
                self.col = @min(self.cols - 1, @max(1, args[1]) - 1);
                try self.ensureLine(a, self.row);
            },
            'J' => {
                if (args[0] == 2 or args[0] == 3) {
                    for (self.lines.items[self.base()..]) |line| @memset(line.cells, .{});
                } else if (args[0] == 0) {
                    @memset(self.lines.items[self.row].cells[@min(self.col, self.cols)..], .{});
                    for (self.lines.items[self.row + 1 ..]) |line| @memset(line.cells, .{});
                }
            },
            'K' => {
                const cells = self.lines.items[self.row].cells;
                const col = @min(self.col, self.cols);
                if (args[0] == 2) @memset(cells, .{}) else if (args[0] == 1) @memset(cells[0..@min(self.cols, col + 1)], .{}) else @memset(cells[col..], .{});
            },
            'm' => {
                for (args[0..@max(1, n)]) |arg| {
                    if (arg == 0) {
                        self.fg = null;
                        self.bg = null;
                    } else if (arg >= 30 and arg <= 37) self.fg = @intCast(arg - 30) else if (arg >= 90 and arg <= 97) self.fg = @intCast(arg - 90 + 8) else if (arg == 39) self.fg = null else if (arg >= 40 and arg <= 47) self.bg = @intCast(arg - 40) else if (arg == 49) self.bg = null;
                }
            },
            'h', 'l' => {
                if (sequence.len > 0 and sequence[0] == '?' and args[0] == 25) self.cursor_visible = final == 'h';
            },
            's' => {
                self.saved_row = self.row;
                self.saved_col = self.col;
            },
            'u' => {
                self.row = @min(self.saved_row, self.lines.items.len - 1);
                self.col = @min(self.saved_col, self.cols - 1);
            },
            else => {},
        }
    }
    pub fn send(self: *Session, bytes: []const u8) !void {
        if (comptime native) {
            if (self.fd < 0 or self.exited) return;
            var offset: usize = 0;
            while (offset < bytes.len) {
                const written = write(self.fd, bytes[offset..].ptr, bytes.len - offset);
                if (written <= 0) return error.TerminalWriteFailed;
                offset += @intCast(written);
            }
        }
    }
    pub fn resize(self: *Session, a: std.mem.Allocator, cols: usize, rows: usize) !void {
        if (cols == self.cols and rows == self.rows) return;
        for (self.lines.items) |*line| {
            const cells = try a.alloc(Cell, cols);
            @memset(cells, .{});
            @memcpy(cells[0..@min(cols, line.cells.len)], line.cells[0..@min(cols, line.cells.len)]);
            a.free(line.cells);
            line.cells = cells;
        }
        self.cols = cols;
        self.rows = rows;
        self.col = @min(self.col, cols - 1);
        if (comptime native) if (self.fd >= 0) {
            var size: Winsize = .{ .row = @intCast(rows), .col = @intCast(cols) };
            _ = ioctl(self.fd, @as(c_ulong, 0x80087467), &size);
        };
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
pub fn create(self: *Shell) !void {
    var session = try Session.init(self.allocator, self.terminal.next_id, self.workspace.root_path, self.terminal.options);
    errdefer session.deinit(self.allocator);
    try self.terminal.sessions.append(self.allocator, session);
    self.terminal.next_id +%= 1;
    self.terminal.active = self.terminal.sessions.items.len - 1;
    self.terminal.visible = true;
    self.terminal.focus +%= 1;
    self.terminal.focused = true;
}
pub fn poll(self: *Shell, cx: *ui.Context(Shell)) !void {
    if (self.terminal.visible and self.terminal.sessions.items.len > 0) if (self.window) |handle| {
        const frame = &(try cx.app.window(handle)).frames.committed;
        for (frame.nodes.items, 0..) |node, i| if (node.key) |key| if (key == .string and std.mem.eql(u8, key.string, "terminal-canvas")) {
            const bounds = frame.bounds[i];
            const cols = @max(2, @min(500, @as(usize, @intFromFloat(@max(16, bounds.width - 16) / 8))));
            const rows = @max(2, @min(200, @as(usize, @intFromFloat(@max(36, bounds.height - 12) / 18))));
            const session = &self.terminal.sessions.items[self.terminal.active];
            if (session.cols != cols or session.rows != rows) {
                try session.resize(self.allocator, cols, rows);
                cx.notify();
            }
            break;
        };
    };
    if (comptime native) for (self.terminal.sessions.items) |*session| {
        var changed = false;
        var bytes: [8192]u8 = undefined;
        for (0..16) |_| {
            if (session.fd < 0) break;
            const count = read(session.fd, &bytes, bytes.len);
            if (count <= 0) break;
            try session.feed(self.allocator, bytes[0..@intCast(count)]);
            changed = true;
        }
        if (session.pid > 0) {
            var status: c_int = 0;
            if (waitpid(session.pid, &status, 1) == session.pid) {
                session.pid = -1;
                session.exited = true;
                changed = true;
            }
        }
        if (changed) cx.notify();
    };
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
pub fn input(self: *Shell, e: *ui.Event(ui.Input), cx: *ui.Context(Shell)) !void {
    if (self.terminal.sessions.items.len == 0) return;
    const session = &self.terminal.sessions.items[self.terminal.active];
    switch (e.data) {
        .focus => |focused| self.terminal.focused = focused,
        .pointer_down => self.terminal.focused = true,
        .resize => {},
        .scroll => |scroll| {
            if (scroll.y > 0) session.scroll = @min(session.lines.items.len -| session.rows, session.scroll + 3) else session.scroll -|= 3;
            e.preventDefault();
        },
        .text => |bytes| {
            try session.send(bytes);
            session.scroll = 0;
            e.preventDefault();
        },
        .key_down => |key| {
            if (key.modifiers.command and key.key == .v) {
                const bytes = try e.readClipboard(self.allocator);
                defer self.allocator.free(bytes);
                try session.send(bytes);
                e.preventDefault();
                e.stopPropagation();
                cx.notify();
                return;
            }
            const cols = @max(2, @as(usize, @intFromFloat(@max(18, e.bounds.width - 16) / 8)));
            const rows = @max(2, @as(usize, @intFromFloat(@max(36, e.bounds.height - 12) / 18)));
            try session.resize(self.allocator, cols, rows);
            const bytes: []const u8 = switch (key.key) {
                .enter => "\r",
                .backspace => "\x7f",
                .tab => "\t",
                .escape => "\x1b",
                .up => "\x1b[A",
                .down => "\x1b[B",
                .right => "\x1b[C",
                .left => "\x1b[D",
                .home => "\x1b[H",
                .end => "\x1b[F",
                .delete => "\x1b[3~",
                .page_up => "\x1b[5~",
                .page_down => "\x1b[6~",
                else => "",
            };
            if (key.modifiers.control and @backingInt(key.key) >= @backingInt(ui.Key.a) and @backingInt(key.key) <= @backingInt(ui.Key.z)) {
                const control = [_]u8{@intCast(@backingInt(key.key) - @backingInt(ui.Key.a) + 1)};
                try session.send(&control);
            } else if (!key.modifiers.command and bytes.len > 0) try session.send(bytes) else return;
            session.scroll = 0;
            e.preventDefault();
            e.stopPropagation();
        },
        else => return,
    }
    cx.notify();
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
const colors = [_]u24{ 0x282c34, 0xe06c75, 0x98c379, 0xe5c07b, 0x61afef, 0xc678dd, 0x56b6c2, 0xabb2bf, 0x5c6370, 0xe06c75, 0x98c379, 0xe5c07b, 0x61afef, 0xc678dd, 0x56b6c2, 0xffffff };
const Canvas = struct {
    cells: []Cell,
    cols: usize,
    rows: usize,
    cursor_row: ?usize,
    cursor_col: usize,
    background: ui.Color,
    foreground: ui.Color,
    pub const LayoutState = void;
    pub const PrepaintState = void;
    pub fn requestLayout(_: *Canvas, cx: *ui.LayoutCx) !ui.LayoutResult(void) {
        return .{ .size = cx.available, .state = {} };
    }
    pub fn prepaint(_: *Canvas, cx: *ui.PrepaintCx, _: ui.Rect, _: *void) !void {
        try cx.requestFrameAfter(0.033);
    }
    pub fn paint(self: *Canvas, cx: *ui.PaintCx, bounds: ui.Rect, _: *void, _: *void) !void {
        try cx.painter.fillRect(.{ .bounds = bounds, .color = self.background });
        try cx.painter.pushClip(bounds);
        defer cx.painter.popClip();
        for (0..self.rows) |row| for (0..self.cols) |col| {
            const cell = self.cells[row * self.cols + col];
            const rect: ui.Rect = .{ .x = bounds.x + 8 + @as(f32, @floatFromInt(col)) * 8, .y = bounds.y + 6 + @as(f32, @floatFromInt(row)) * 18, .width = 8, .height = 18 };
            if (cell.bg) |bg| try cx.painter.fillRect(.{ .bounds = rect, .color = ui.Color.rgb(colors[bg % colors.len]) });
            if (cell.code != ' ') {
                var bytes: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(cell.code, &bytes) catch 0;
                try cx.painter.drawText(.{ .bounds = rect, .text = bytes[0..len], .style = .{ .mono = true, .size = 13, .color = if (cell.fg) |fg| ui.Color.rgb(colors[fg % colors.len]) else self.foreground } });
            }
        };
        if (self.cursor_row) |row| if (cx.focused) try cx.painter.fillRect(.{ .bounds = .{ .x = bounds.x + 8 + @as(f32, @floatFromInt(self.cursor_col)) * 8, .y = bounds.y + 6 + @as(f32, @floatFromInt(row)) * 18, .width = 2, .height = 17 }, .color = self.foreground });
    }
};
pub fn render(self: *const Shell, b: *ui.Ui, width: f32, height: f32) !ui.Element {
    const v = components;
    const c = self.colors;
    var tabs: std.ArrayList(ui.Element) = .empty;
    for (self.terminal.sessions.items, 0..) |session, i| {
        const name = try std.fmt.allocPrint(b.allocator(), "Terminal {d}{s}", .{ session.id, if (session.exited) " · exited" else "" });
        try tabs.append(b.allocator(), try b.fluent().div().h(.{ .px = 32 }).background(if (i == self.terminal.active) c.document else c.tab_bar).items_center().flex().children(.{ b.fluent().button(.{ .label = name, .children = &.{ try v.icon(b, .terminal, c.muted, 13), try v.text(b, name, c.text, 12) }, .on_click = b.onClickWith(select, session.id), .style = .{ .direction = .row, .height = .{ .px = 32 }, .gap = 5, .padding = .{ .left = 10, .right = 6 }, .align_items = .center } }), b.fluent().button(.{ .label = "Close terminal", .children = &.{try v.icon(b, .close, c.muted, 12)}, .on_click = b.onClickWith(closeTab, session.id), .style = .{ .width = .{ .px = 22 }, .height = .{ .px = 22 }, .align_items = .center, .justify_content = .center, .hover_background = c.hover } }) }).build());
    }
    try tabs.append(b.allocator(), try b.fluent().div().grow().children(.{}).build());
    try tabs.append(b.allocator(), try v.iconButton(b, c, .new_terminal, "New terminal", .plus, false));
    try tabs.append(b.allocator(), try v.iconButton(b, c, if (self.terminal.dock == .bottom) .terminal_right else .terminal_bottom, if (self.terminal.dock == .bottom) "Dock terminal right" else "Dock terminal bottom", .split, false));
    try tabs.append(b.allocator(), try v.iconButton(b, c, .toggle_terminal, "Hide terminal", .close, false));
    const session = &self.terminal.sessions.items[self.terminal.active];
    const cols = @max(1, @min(session.cols, @as(usize, @intFromFloat(@max(8, width - 16) / 8))));
    const rows = @max(1, @as(usize, @intFromFloat(@max(18, height - 44) / 18)));
    const end = session.lines.items.len -| session.scroll;
    const start = end -| rows;
    const cells = try b.allocator().alloc(Cell, cols * rows);
    @memset(cells, .{});
    for (session.lines.items[start..end], 0..) |line, row| @memcpy(cells[row * cols ..][0..cols], line.cells[0..cols]);
    const canvas = try b.custom(Canvas, .{ .cells = cells, .cols = cols, .rows = rows, .cursor_row = if (session.cursor_visible and session.row >= start and session.row < end) session.row - start else null, .cursor_col = @min(session.col, cols - 1), .background = c.document, .foreground = c.text }, .{ .flex_grow = 1, .min_height = .{ .px = 0 }, .overflow = .hidden });
    const surface = try b.fluent().adopt(canvas).id(.{ .string = "terminal-canvas" }).listeners(.{ .focusable = true, .on_input = b.onInput(input) }).request_focus(self.terminal.focus).build();
    return b.fluent().div().w(.{ .px = width }).h(.{ .px = height }).shrink_0().min_w(.{ .px = 0 }).min_h(.{ .px = 0 }).overflow_hidden().flex_col().children(.{ b.fluent().div().h(.{ .px = 32 }).shrink_0().background(c.tab_bar).overflow_hidden().flex().children(tabs.items), surface }).id(.{ .string = "terminal-panel" }).build();
}

const Wake = struct {
    pub const LayoutState = void;
    pub const PrepaintState = void;
    pub fn requestLayout(_: *Wake, _: *ui.LayoutCx) !ui.LayoutResult(void) {
        return .{ .size = .{ .width = 0, .height = 0 }, .state = {} };
    }
    pub fn prepaint(_: *Wake, cx: *ui.PrepaintCx, _: ui.Rect, _: *void) !void {
        try cx.requestFrameAfter(0.033);
    }
    pub fn paint(_: *Wake, _: *ui.PaintCx, _: ui.Rect, _: *void, _: *void) !void {}
};
pub fn wakeElement(b: *ui.Ui) !ui.Element {
    return b.custom(Wake, .{}, .{ .width = .{ .px = 0 }, .height = .{ .px = 0 } });
}

pub fn closeActive(self: *Shell, cx: *ui.Context(Shell)) !void {
    if (self.terminal.sessions.items.len == 0) return;
    var event: ui.Event(ui.Click) = .{ .data = .{} };
    closeTab(self, &event, cx, self.terminal.sessions.items[self.terminal.active].id);
}
