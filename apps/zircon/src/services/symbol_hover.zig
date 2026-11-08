//! Debounced, revision-bound language information shared by editor panes.
const std = @import("std");
const editing = @import("zircon_editor");
const lsp = @import("zircon_language");
const text = @import("zircon_text");
const ui = @import("zircon_ui");
const ws = @import("zircon_workspace");
const shell = @import("../shell.zig");
const v = @import("../views/components.zig");
const markdown = @import("../views/markdown.zig");
const language = @import("language.zig");
const Shell = shell.Shell;

const Target = struct { document: ws.DocumentId, revision: u64, offset: usize, range: text.Range, anchor: ui.Rect, editor_bounds: ui.Rect };
const Pending = struct { session: usize, request: u64 };

pub const Model = struct {
    target: ?Target = null,
    due: f64 = 0,
    requested: bool = false,
    pending: ?Pending = null,
    preview: ?markdown.Preview = null,
    height: f32 = 120,

    pub fn deinit(self: *Model) void {
        if (self.preview) |*preview| preview.deinit();
        self.* = .{};
    }
};

pub fn clear(self: *Shell, cx: *ui.Context(Shell)) void {
    if (self.symbol_hover.pending) |pending| if (pending.session < self.language.sessions.items.len) {
        if (self.language.sessions.items[pending.session].client) |client| client.cancel(pending.request) catch {};
    };
    const visible = self.symbol_hover.preview != null;
    self.symbol_hover.deinit();
    if (visible) cx.notify();
}

pub fn pointer(self: *Shell, cx: *ui.Context(Shell), state: *editing.Editor, document: *const text.Document, id: ws.DocumentId, e: *ui.Event(ui.Input)) !void {
    if (e.data != .pointer_move) {
        if (e.data == .text or e.data == .edit or e.data == .key_down or e.data == .pointer_down or e.data == .scroll or e.data == .pointer_leave) clear(self, cx);
        return;
    }
    const point = e.data.pointer_move.position;
    if (overPopup(self, cx, point)) return;
    if (state.dragging or self.overlay != .none or self.menu_open or self.editor_context_menu != null) return clear(self, cx);
    var snapshot = document.snapshot();
    defer snapshot.deinit();
    const range = (try state.symbolAt(snapshot, e, point)) orelse return clear(self, cx);
    if (self.symbol_hover.target) |target| {
        if (std.meta.eql(target.document, id) and target.revision == snapshot.revision() and std.meta.eql(target.range, range)) return;
    }
    clear(self, cx);
    const row = (try snapshot.pointAt(range.start)).line;
    self.symbol_hover.target = .{ .document = id, .revision = snapshot.revision(), .offset = range.start, .range = range, .anchor = .{ .x = point.x, .y = e.bounds.y + state.rowY(row, snapshot.revision()) - state.scroll.offset, .width = 1, .height = state.line_height }, .editor_bounds = e.bounds };
    self.symbol_hover.due = try cx.app.currentTime() + 0.35;
    cx.notify();
}

pub fn show(self: *Shell, cx: *ui.Context(Shell)) !void {
    try language.poll(self, cx);
    const pane = if (self.active_pane == .secondary) self.secondary else null;
    if (pane == null and self.tabs.items.len == 0) return;
    const id = if (pane) |value| value.document else self.tabs.items[self.active].document;
    const state = if (pane) |value| value.editor else self.tabs.items[self.active].editor;
    const record = try self.workspace.getConst(id);
    var snapshot = record.doc.snapshot();
    defer snapshot.deinit();
    clear(self, cx);
    const window = try cx.app.window(self.window orelse return);
    const anchor = if (window.frames.committed.text_input) |text_input| text_input.caret else ui.Rect{ .x = 120, .y = 100, .width = 1, .height = state.line_height };
    self.symbol_hover.target = .{ .document = id, .revision = snapshot.revision(), .offset = state.primary().head, .range = .{ .start = state.primary().head, .end = state.primary().head }, .anchor = anchor, .editor_bounds = .{ .width = window.dimensions.width, .height = window.dimensions.height } };
    self.symbol_hover.due = try cx.app.currentTime();
    try poll(self, cx);
}

pub fn poll(self: *Shell, cx: *ui.Context(Shell)) !void {
    const target = self.symbol_hover.target orelse return;
    const record = self.workspace.getConst(target.document) catch return clear(self, cx);
    if (record.doc.revision() != target.revision or self.language_stopped) return clear(self, cx);
    if (self.symbol_hover.requested or try cx.app.currentTime() < self.symbol_hover.due) return;
    for (self.language.documents.items) |doc| if (std.meta.eql(doc.id, target.document)) {
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
    if (self.symbol_hover.preview) |*old| old.deinit();
    self.symbol_hover.preview = preview;
    const lines = std.mem.count(u8, value.contents, "\n") + 1;
    self.symbol_hover.height = std.math.clamp(@as(f32, @floatFromInt(lines)) * 22 + 48, 100, 320);
    cx.notify();
}

fn bounds(self: *const Shell, viewport: ui.Size) ui.Rect {
    const target = self.symbol_hover.target.?;
    const width = @min(480, @max(80, viewport.width - 16));
    const height = @min(self.symbol_hover.height, @max(40, viewport.height - 16));
    const y = target.anchor.y + target.anchor.height + 6;
    return .{ .x = std.math.clamp(target.anchor.x - 12, 8, @max(8, viewport.width - width - 8)), .y = std.math.clamp(if (y + height <= viewport.height - 8) y else target.anchor.y - height - 6, 8, @max(8, viewport.height - height - 8)), .width = width, .height = height };
}

fn overPopup(self: *const Shell, cx: *ui.Context(Shell), point: ui.Point) bool {
    if (self.symbol_hover.preview == null) return false;
    const window = cx.app.window(self.window orelse return false) catch return false;
    var area = bounds(self, window.dimensions);
    area.y -= 6;
    area.height += 6;
    return editing.annotations.contains(area, point);
}

pub fn dismissOutside(self: *Shell, cx: *ui.Context(Shell), event: ui.Input) void {
    if (event == .key_down or event == .text or event == .edit or event == .resize) return clear(self, cx);
    if (event == .pointer_down and !overPopup(self, cx, event.pointer_down.position)) return clear(self, cx);
    if (event == .scroll and !overPopup(self, cx, event.scroll.position)) return clear(self, cx);
    if (event == .focus and !event.focus) return clear(self, cx);
    if (event == .pointer_move) if (self.symbol_hover.target) |target| {
        if (!editing.annotations.contains(target.editor_bounds, event.pointer_move.position) and !overPopup(self, cx, event.pointer_move.position)) clear(self, cx);
    };
}

pub fn render(self: *const Shell, b: *ui.Ui) !?ui.Element {
    if (self.symbol_hover.target == null) return null;
    if (!self.symbol_hover.requested) try b.requestFrameAfter(@max(0.001, self.symbol_hover.due - b.frame.time));
    const preview = self.symbol_hover.preview orelse return null;
    const area = bounds(self, b.viewport());
    const content = try b.fluent().adopt(try preview.render(b)).listeners(.{ .on_input = b.onInput(input) }).build();
    const card = try v.floatingPanel(b, self.colors, .{ .width = area.width, .height = area.height }, ui.Insets.all(8), 0, &.{content});
    return try b.fluent().div().padding(.{ .top = area.y, .left = area.x }).items(.start).stack().children(.{card}).id(.{ .string = "symbol-hover" }).build();
}

fn input(self: *Shell, e: *ui.Event(ui.Input), cx: *ui.Context(Shell)) !void {
    if (e.data == .scroll) if (self.symbol_hover.preview) |*preview| {
        _ = try preview.handle(e);
        e.preventDefault();
        e.stopPropagation();
        cx.notify();
    };
}
