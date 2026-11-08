//! Source editors retain source selections and share workspace document history.
const std = @import("std");
const editing = @import("zircon_editor");
const ws = @import("zircon_workspace");
const a = std.heap.page_allocator;
pub const View = struct { document: ws.DocumentId, editor: editing.Editor };
pub const Model = struct {
    views: std.ArrayList(View) = .empty,
    active: ?ws.DocumentId = null,
    pub fn deinit(self: *Model) void {
        for (self.views.items) |*view| view.editor.deinit();
        self.views.deinit(a);
        self.* = .{};
    }
    pub fn remove(self: *Model, id: ws.DocumentId) void {
        if (self.active) |active_id| if (std.meta.eql(active_id, id)) {
            self.active = null;
        };
        for (self.views.items, 0..) |view, index| if (std.meta.eql(view.document, id)) {
            var removed = self.views.orderedRemove(index);
            removed.editor.deinit();
            return;
        };
    }
    pub fn current(self: *const Model) ?*const View {
        const id = self.active orelse return null;
        for (self.views.items) |*view| if (std.meta.eql(view.document, id)) return view;
        return null;
    }
};
