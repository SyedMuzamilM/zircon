//! Pointer-captured tab/file dragging. Source identities survive tab reordering;
//! a split allocates its new editor before replacing the old pane.
const std = @import("std");
const ui = @import("zircon_ui");
const ws = @import("zircon_workspace");
const Shell = @import("shell.zig").Shell;
pub const Session = struct {
    source: union(enum) { tab: ws.DocumentId, file: []u8 },
    origin: ui.Point,
    moved: bool = false,
    pub fn deinit(self: *Session, a: std.mem.Allocator) void {
        if (self.source == .file) a.free(self.source.file);
    }
};
pub fn key(id: ws.DocumentId) u64 {
    return (@as(u64, id.generation) << 32) | id.slot;
}
pub fn tabInput(self: *Shell, e: *ui.Event(ui.Input), cx: *ui.Context(Shell), document: ws.DocumentId) !void {
    if (e.data == .pointer_down and e.data.pointer_down.button == .primary) {
        cancel(self);
        const point = e.data.pointer_down.position;
        self.tab_drag = .{ .source = .{ .tab = document }, .origin = point };
        e.capturePointer();
        return;
    }
    try advance(self, e, cx);
}
pub fn treeInput(self: *Shell, e: *ui.Event(ui.Input), cx: *ui.Context(Shell), index: u32) !void {
    if (e.data == .pointer_down and e.data.pointer_down.button == .primary) {
        if (index >= self.tree.items.len or self.tree.items[index].directory) return;
        cancel(self);
        const point = e.data.pointer_down.position;
        self.tab_drag = .{ .source = .{ .file = try self.allocator.dupe(u8, self.tree.items[index].path) }, .origin = point };
        e.capturePointer();
        return;
    }
    try advance(self, e, cx);
}
pub fn cancel(self: *Shell) void {
    if (self.tab_drag) |*drag| drag.deinit(self.allocator);
    self.tab_drag = null;
}
fn advance(self: *Shell, e: *ui.Event(ui.Input), cx: *ui.Context(Shell)) !void {
    const session = if (self.tab_drag) |*drag| drag else return;
    switch (e.data) {
        .pointer_move => |pointer| {
            const dx = pointer.position.x - session.origin.x;
            const dy = pointer.position.y - session.origin.y;
            session.moved = session.moved or dx * dx + dy * dy >= 25;
            if (session.moved) {
                e.preventDefault();
                cx.notify();
            }
        },
        .pointer_up => |pointer| {
            defer cancel(self);
            e.releasePointer();
            if (!session.moved) return;
            e.preventDefault();
            const size = try e.windowSize();
            const left = if (self.sidebar_visible and size.width >= 600) @min(self.sidebar_width, @max(140, size.width * 0.4)) + 5 else 0;
            const point = pointer.position;
            if (point.x < left or point.x >= size.width or point.y < @import("views/components.zig").metrics.titlebar or point.y >= size.height - @import("views/components.zig").metrics.status) {
                cx.notify();
                return;
            }
            if (session.source == .file) {
                try self.openPath(session.source.file);
                if (self.panel == .image) {
                    cx.notify();
                    return;
                }
            }
            const id = if (session.source == .tab) session.source.tab else if (self.tabs.items.len > 0) self.tabs.items[self.active].document else return;
            var source: ?usize = null;
            for (self.tabs.items, 0..) |tab, index| if (std.meta.eql(tab.document, id)) {
                source = index;
                break;
            };
            const index = source orelse return;
            if (point.y < @import("views/components.zig").metrics.titlebar + @import("views/components.zig").metrics.tabs) {
                const w = try cx.app.window(self.window.?);
                var destination = self.tabs.items.len - 1;
                for (w.frames.committed.nodes.items, 0..) |node, ni| {
                    const parent = node.parent orelse continue;
                    const parent_key = w.frames.committed.nodes.items[parent].key orelse continue;
                    if (parent_key != .string or !std.mem.eql(u8, parent_key.string, "tabs")) continue;
                    const node_key = node.key orelse continue;
                    if (node_key != .number) continue;
                    const bounds = w.frames.committed.bounds[ni];
                    if (point.x >= bounds.x + bounds.width) continue;
                    for (self.tabs.items, 0..) |tab, ti| if (key(tab.document) == node_key.number) {
                        destination = ti;
                        break;
                    };
                    break;
                }
                const active_id = self.tabs.items[self.active].document;
                const tab = self.tabs.orderedRemove(index);
                self.tabs.insertAssumeCapacity(@min(destination, self.tabs.items.len), tab);
                for (self.tabs.items, 0..) |current, ti| if (std.meta.eql(current.document, active_id)) {
                    self.active = ti;
                    break;
                };
            } else if (point.x > left + (size.width - left) * 0.65) {
                var editor = try @import("zircon_editor").Editor.init(self.allocator);
                errdefer editor.deinit();
                const record = try self.workspace.getConst(id);
                self.configureEditor(&editor, record.path orelse "");
                var snapshot = record.doc.snapshot();
                defer snapshot.deinit();
                editor.synchronize(snapshot);
                if (self.secondary) |*old| old.editor.deinit();
                self.secondary = .{ .document = id, .editor = editor };
                self.active_pane = .secondary;
                self.panel = .editor;
            } else {
                self.active = index;
                self.active_pane = .primary;
                self.panel = .editor;
            }
            self.editor_focus_request +%= 1;
            cx.notify();
        },
        .focus => |focused| if (!focused) {
            cancel(self);
            e.releasePointer();
            cx.notify();
        },
        else => {},
    }
}
