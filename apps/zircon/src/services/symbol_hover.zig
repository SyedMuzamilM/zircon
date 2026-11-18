//! Debounced, revision-bound language information shared by editor panes.
const std = @import("std");
const editing = @import("zircon_editor");
const lsp = @import("zircon_language");
const text = @import("zircon_text");
const ui = @import("zircon_ui");
const ws = @import("zircon_workspace");
const actions = @import("../actions.zig");
const shell = @import("../shell.zig");
const hover_popover = @import("../views/hover_popover.zig");
const markdown = @import("../views/markdown.zig");
const language = @import("language.zig");
const Shell = shell.Shell;

const Target = struct { document: ws.DocumentId, revision: u64, offset: usize, range: text.Range, anchor: ui.Rect, editor_bounds: ui.Rect };
const Pending = struct { session: usize, request: u64 };

pub const Model = struct {
    target: ?Target = null,
    due: f64 = 0,
    requested: bool = false,
    pinned: bool = false,
    pending: ?Pending = null,
    preview: ?markdown.Preview = null,
    note: ?Note = null,
    note_generation: u64 = 0,
    height: f32 = 120,
    width: f32 = 480,

    pub fn deinit(self: *Model, a: std.mem.Allocator) void {
        if (self.preview) |*preview| preview.deinit();
        if (self.note) |note| {
            a.free(note.message);
            a.free(note.source);
        }
        self.* = .{};
    }
};

pub const Note = struct {
    severity: editing.element.Severity,
    message: []u8,
    source: []u8,
    offset: usize,
};

fn copyNote(a: std.mem.Allocator, hit: language.DiagnosticHit, offset: usize) !Note {
    const message = try a.dupe(u8, hit.message);
    errdefer a.free(message);
    return .{ .severity = hit.severity, .message = message, .source = try a.dupe(u8, hit.source), .offset = offset };
}

pub fn clear(self: *Shell, cx: *ui.Context(Shell)) void {
    if (self.symbol_hover.pending) |pending| if (pending.session < self.language.sessions.items.len) {
        if (self.language.sessions.items[pending.session].client) |client| client.cancel(pending.request) catch {};
    };
    const visible = self.symbol_hover.preview != null or self.symbol_hover.note != null;
    self.symbol_hover.deinit(self.allocator);
    if (visible) cx.notify();
}

pub fn pointer(self: *Shell, cx: *ui.Context(Shell), state: *editing.Editor, document: *const text.Document, id: ws.DocumentId, e: *ui.Event(ui.Input)) !void {
    if (e.data != .pointer_move) {
        if (e.data == .text or e.data == .edit or e.data == .key_down or e.data == .pointer_down or e.data == .scroll or e.data == .pointer_leave) clear(self, cx);
        return;
    }
    if (self.symbol_hover.pinned) return;
    const point = e.data.pointer_move.position;
    if (overPopup(self, cx, point)) return;
    if (state.dragging or self.overlay != .none or self.menu_open or self.editor_context_menu != null) return clear(self, cx);
    var snapshot = document.snapshot();
    defer snapshot.deinit();
    const gutter = if (state.show_line_numbers) editing.gutterWidth(snapshot.lineCount(), state.font_size) else 20;
    if (!editing.annotations.contains(e.bounds, point) or point.x < e.bounds.x + gutter or point.x >= e.bounds.x + e.bounds.width - 12) return clear(self, cx);
    const at = try state.offsetAtPoint(snapshot, e, point);
    const diagnostic = language.diagnosticAt(self, snapshot, id, at);
    const symbol = try state.symbolAt(snapshot, e, point);
    if (diagnostic == null and symbol == null) return clear(self, cx);
    const range = if (diagnostic) |hit| hit.range else symbol.?;
    if (self.symbol_hover.target) |target| {
        const same = std.meta.eql(target.document, id) and target.revision == snapshot.revision() and std.meta.eql(target.range, range);
        if (same and (self.symbol_hover.note != null) == (diagnostic != null)) {
            if (self.symbol_hover.note) |*note| note.offset = at;
            return;
        }
    }
    const row = (try snapshot.pointAt(range.start)).line;
    const now = try cx.app.currentTime();
    clear(self, cx);
    if (diagnostic) |hit| {
        self.symbol_hover.note = try copyNote(self.allocator, hit, at);
        self.symbol_hover.note_generation = self.language.diagnostics_generation;
        self.symbol_hover.width = 440;
        self.symbol_hover.height = 48;
    }
    self.symbol_hover.target = .{ .document = id, .revision = snapshot.revision(), .offset = range.start, .range = range, .anchor = .{ .x = point.x, .y = e.bounds.y + state.rowY(row, snapshot.revision()) - state.scroll.offset, .width = 1, .height = state.line_height }, .editor_bounds = e.bounds };
    self.symbol_hover.due = now + if (diagnostic != null) @as(f64, 0) else 0.35;
    cx.notify();
}

pub fn show(self: *Shell, cx: *ui.Context(Shell)) !void {
    try language.poll(self, cx);
    const current = actions.active(self) catch return;
    const id = current.id;
    const state = current.editor;
    const record = try self.workspace.getConst(id);
    var snapshot = record.doc.snapshot();
    defer snapshot.deinit();
    clear(self, cx);
    const window = try cx.app.window(self.window orelse return);
    const anchor = if (window.frames.committed.text_input) |text_input| text_input.caret else ui.Rect{ .x = 120, .y = 100, .width = 1, .height = state.line_height };
    self.symbol_hover.target = .{ .document = id, .revision = snapshot.revision(), .offset = state.primary().head, .range = .{ .start = state.primary().head, .end = state.primary().head }, .anchor = anchor, .editor_bounds = .{ .width = window.dimensions.width, .height = window.dimensions.height } };
    self.symbol_hover.pinned = true;
    self.symbol_hover.due = try cx.app.currentTime();
    try poll(self, cx);
}

pub fn poll(self: *Shell, cx: *ui.Context(Shell)) !void {
    const target = self.symbol_hover.target orelse return;
    const record = self.workspace.getConst(target.document) catch return clear(self, cx);
    if (record.doc.revision() != target.revision or self.language_stopped) return clear(self, cx);
    if (self.symbol_hover.note) |old| {
        if (self.symbol_hover.note_generation != self.language.diagnostics_generation) {
            var snapshot = record.doc.snapshot();
            defer snapshot.deinit();
            const hit = language.diagnosticAt(self, snapshot, target.document, old.offset) orelse return clear(self, cx);
            if (!std.meta.eql(hit.range, target.range)) return clear(self, cx);
            self.symbol_hover.note = try copyNote(self.allocator, hit, old.offset);
            self.allocator.free(old.message);
            self.allocator.free(old.source);
            self.symbol_hover.note_generation = self.language.diagnostics_generation;
            cx.notify();
        }
    }
    if (self.symbol_hover.requested or try cx.app.currentTime() < self.symbol_hover.due) return;
    for (self.language.documents.items) |doc| if (std.meta.eql(doc.id, target.document)) {
        if (doc.session >= self.language.sessions.items.len) break;
        const client = self.language.sessions.items[doc.session].client orelse break;
        if (!client.ready()) {
            self.symbol_hover.due = try cx.app.currentTime() + 0.1;
            return;
        }
        self.symbol_hover.requested = true;
        if (!client.supportsHover()) return;
        var snapshot = record.doc.snapshot();
        defer snapshot.deinit();
        const request = try client.hover(doc.uri, snapshot.revision(), try lsp.positionAt(snapshot, target.offset));
        self.symbol_hover.pending = .{ .session = doc.session, .request = request };
        return;
    };
    self.symbol_hover.requested = true;
}

pub fn accept(self: *Shell, cx: *ui.Context(Shell), session: usize, message: @FieldType(lsp.Message, "data")) !void {
    const pending = self.symbol_hover.pending orelse return;
    const target = self.symbol_hover.target orelse return;
    const value = message.hover;
    if (pending.session != session or pending.request != value.id or value.version != target.revision) return;
    const record = self.workspace.getConst(target.document) catch return;
    if (record.doc.revision() != target.revision) return clear(self, cx);
    self.symbol_hover.pending = null;
    if (value.contents.len == 0) return;
    var document = try text.Document.init(self.allocator, value.contents);
    defer document.deinit();
    var snapshot = document.snapshot();
    defer snapshot.deinit();
    var preview = try markdown.Preview.init(self.allocator, self.workspace.io, null, snapshot);
    preview.colors = self.previewColors();
    preview.colors.background = self.colors.panel;
    preview.colors.code = self.colors.panel;
    preview.compact = true;
    if (self.symbol_hover.preview) |*old| old.deinit();
    self.symbol_hover.preview = preview;
    const window = try cx.app.window(self.window orelse return);
    const width = try preview.contentWidth(window.surface.?.measurer(), @min(520, @max(80, window.dimensions.width - 16)));
    const note: f32 = if (self.symbol_hover.note != null) 36 else 0;
    self.symbol_hover.width = @max(width, if (note > 0) @as(f32, 440) else 0);
    self.symbol_hover.height = std.math.clamp(try preview.contentHeight(window.surface.?.measurer(), width - 8) + 8 + note, 40, 360);
    cx.notify();
}

fn overPopup(self: *const Shell, cx: *ui.Context(Shell), point: ui.Point) bool {
    if (self.symbol_hover.preview == null and self.symbol_hover.note == null) return false;
    const window = cx.app.window(self.window orelse return false) catch return false;
    var area = hover_popover.bounds(self, window.dimensions);
    if (area.y > self.symbol_hover.target.?.anchor.y) area.y -= 6;
    area.height += 6;
    return editing.annotations.contains(area, point);
}

pub fn dismissOutside(self: *Shell, cx: *ui.Context(Shell), event: ui.Input) void {
    if (event == .key_down or event == .text or event == .edit or event == .resize) return clear(self, cx);
    if (event == .pointer_down and !overPopup(self, cx, event.pointer_down.position)) return clear(self, cx);
    if (event == .scroll and !overPopup(self, cx, event.scroll.position)) return clear(self, cx);
    if (event == .focus and !event.focus) return clear(self, cx);
    if (event == .pointer_leave) return clear(self, cx);
    if (event == .pointer_move and !self.symbol_hover.pinned) if (self.symbol_hover.target) |target| {
        if (!editing.annotations.contains(target.editor_bounds, event.pointer_move.position) and !overPopup(self, cx, event.pointer_move.position)) clear(self, cx);
    };
}

pub fn render(self: *const Shell, b: *ui.Ui) !?ui.Element {
    return hover_popover.render(self, b);
}
