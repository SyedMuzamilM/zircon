//! Source views share text/history while retaining independent selections.

const std = @import("std");
const editing = @import("editor.zig");
pub fn Sources(comptime DocumentId: type) type {
    const a = std.heap.page_allocator;

    return struct {
        pub const View = struct { document: DocumentId, editor: editing.Editor };
        const Model = @This();
        horizontal: f32 = 0,
        views: std.ArrayList(View) = .empty,
        active: ?DocumentId = null,
        pub fn find(self: *const Model, id: DocumentId) ?*const View {
            for (self.views.items) |*view| if (std.meta.eql(view.document, id)) return view;
            return null;
        }
        pub fn deinit(self: *Model) void {
            for (self.views.items) |*view| view.editor.deinit();
            self.views.deinit(a);
            self.* = .{};
        }
        pub fn remove(self: *Model, id: DocumentId) void {
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
}
