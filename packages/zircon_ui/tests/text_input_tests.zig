const std = @import("std");
const ui = @import("zircon_ui");
const t = std.testing;

test "focused prepaint copies a validated text snapshot into frame storage" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var target: ?ui.TextSnapshot = null;
    var cx: ui.PrepaintCx = .{ .allocator = arena.allocator(), .focused = true, .text_input = &target };
    var bytes = [_]u8{ 'a', 'b', 'c' };
    try cx.setTextInput(.{ .text = &bytes, .revision = 0, .selection = .{ .start = 1, .end = 2 }, .caret = .{ .x = 12, .y = 20, .width = 1, .height = 18 } });
    @memset(&bytes, 'x');
    try t.expectEqualStrings("abc", target.?.text);
    try t.expectEqual(@as(u64, 0), target.?.revision);
    try t.expectError(error.DuplicateTextInputTarget, cx.setTextInput(target.?));
    var ignored: ui.PrepaintCx = .{ .allocator = arena.allocator() };
    try ignored.setTextInput(.{ .text = "unfocused", .revision = 3, .selection = .{ .start = 0, .end = 0 }, .caret = .{} });
}

test "text snapshots reject malformed UTF8 codepoint splits and invalid caret geometry" {
    const base: ui.TextSnapshot = .{ .text = "a🌍日", .revision = 5, .selection = .{ .start = 1, .end = 5 }, .caret = .{} };
    try base.validate();
    var bad = base;
    bad.selection.end = 3;
    try t.expectError(error.InvalidTextRange, bad.validate());
    bad = base;
    bad.marked = .{ .start = 5, .end = 100 };
    try t.expectError(error.InvalidTextRange, bad.validate());
    bad = base;
    bad.text = "\xff";
    try t.expectError(error.InvalidUtf8, bad.validate());
    bad = base;
    bad.caret.x = std.math.nan(f32);
    try t.expectError(error.InvalidTextCaret, bad.validate());
    bad = base;
    bad.caret.height = -1;
    try t.expectError(error.InvalidTextCaret, bad.validate());
}

test "text edits bind replacement and inserted selection to the exact revision" {
    const snapshot: ui.TextSnapshot = .{ .text = "a🌍日", .revision = 8, .selection = .{ .start = 1, .end = 5 }, .caret = .{} };
    var edit: ui.TextEdit = .{ .revision = 8, .range = .{ .start = 1, .end = 5 }, .text = "é", .selection = .{ .start = 2, .end = 2 } };
    try edit.validate(snapshot);
    edit.revision = 7;
    try t.expectError(error.StaleTextSnapshot, edit.validate(snapshot));
    edit.revision = 8;
    edit.selection.start = 1;
    try t.expectError(error.InvalidTextRange, edit.validate(snapshot));
}

const Provider = struct {
    revision: u64,
    pub const LayoutState = void;
    pub const PrepaintState = void;
    pub fn requestLayout(_: *Provider, _: *ui.LayoutCx) !ui.LayoutResult(void) {
        return .{ .size = .{ .width = 200, .height = 100 }, .state = {} };
    }
    pub fn prepaint(self: *Provider, cx: *ui.PrepaintCx, bounds: ui.Rect, _: *void) !void {
        try cx.setTextInput(.{ .text = "a🌍日", .revision = self.revision, .selection = .{ .start = 1, .end = 5 }, .caret = .{ .x = bounds.x + 10, .y = bounds.y + 10, .width = 1, .height = 20 } });
    }
    pub fn paint(_: *Provider, _: *ui.PaintCx, _: ui.Rect, _: *void, _: *void) !void {}
};
const InputView = struct {
    revision: u64 = 1,
    applied: usize = 0,
    fail: bool = false,
    pub fn render(self: *const InputView, b: *ui.Ui) !ui.Element {
        if (self.fail) return error.RefusedSnapshot;
        const focused = try b.listen(try b.key(.{ .string = "editor" }, try b.custom(Provider, .{ .revision = self.revision }, .{})), .{ .focusable = true, .on_input = b.onInput(input) });
        const ignored = try b.custom(Provider, .{ .revision = 90 }, .{});
        return b.column(.{}, &.{ focused, ignored });
    }
    fn input(self: *InputView, e: *ui.Event(ui.Input), cx: *ui.Context(InputView)) !void {
        if (e.data == .edit) {
            if (e.data.edit.revision != self.revision) return error.StaleTextSnapshot;
            self.applied += 1;
            self.revision += 1;
            cx.notify();
        }
    }
    fn failRender(self: *InputView, cx: *ui.Context(InputView)) void {
        self.fail = true;
        cx.notify();
    }
    fn count(self: *const InputView) usize {
        return self.applied;
    }
};

test "window publishes only focused committed snapshots and retains them on failed staging" {
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const h = try app.openWindow(InputView, .{ .visible = false }, .{});
    const root = try app.windowEntity(InputView, h);
    _ = try app.step(0);
    const w = try app.window(h);
    try t.expectEqual(@as(u64, 1), w.frames.committed.text_input.?.revision);
    const edit: ui.TextEdit = .{ .revision = 1, .range = .{ .start = 1, .end = 5 }, .text = "é", .selection = .{ .start = 2, .end = 2 } };
    try app.dispatch(h, .{ .edit = edit });
    try t.expectEqual(@as(usize, 1), try app.read(root, InputView.count, .{}));
    // A second mutation before the next frame still sees the old snapshot,
    // but the model rejects it using its current document revision.
    try t.expectError(error.StaleTextSnapshot, app.dispatch(h, .{ .edit = edit }));
    _ = try app.step(1);
    try t.expectEqual(@as(u64, 2), w.frames.committed.text_input.?.revision);
    try t.expectError(error.StaleTextSnapshot, app.dispatch(h, .{ .edit = edit }));
    const old = w.frames.committed.text_input.?;
    try app.update(root, InputView.failRender, .{});
    try t.expectError(error.RefusedSnapshot, app.step(2));
    try t.expectEqual(old.revision, w.frames.committed.text_input.?.revision);
    try t.expectEqual(old.text.ptr, w.frames.committed.text_input.?.text.ptr);
}

test "bounded surrounding text validates absolute edits and rejects base overflow" {
    const snapshot: ui.TextSnapshot = .{ .text = "é🌍b", .base_byte = 1000, .base_utf16 = 100, .revision = 7, .selection = .{ .start = 2, .end = 6 }, .caret = .{} };
    try snapshot.validate();
    var edit: ui.TextEdit = .{ .revision = 7, .range = .{ .start = 1002, .end = 1006 }, .text = "日", .selection = .{ .start = 3, .end = 3 } };
    try edit.validate(snapshot);
    edit.range.start = 999;
    try t.expectError(error.InvalidTextRange, edit.validate(snapshot));
    edit.range = .{ .start = 1002, .end = 1008 };
    try t.expectError(error.InvalidTextRange, edit.validate(snapshot));
    var bad = snapshot;
    bad.base_byte = std.math.maxInt(usize) - 1;
    try t.expectError(error.InvalidTextRange, bad.validate());
    bad = snapshot;
    bad.base_utf16 = std.math.maxInt(usize) - 1;
    try t.expectError(error.InvalidTextRange, bad.validate());
}

const CloseGuard = struct {
    dirty: bool = true,
    root_requests: usize = 0,
    child_requests: usize = 0,
    pub fn render(_: *const CloseGuard, b: *ui.Ui) !ui.Element {
        const child = try b.listen(try b.div(.{ .height = .{ .px = 100 } }, &.{}), .{ .focusable = true, .on_input = b.onInput(childInput) });
        return b.listen(try b.column(.{}, &.{child}), .{ .on_input = b.onInput(rootInput) });
    }
    fn childInput(self: *CloseGuard, event: *ui.Event(ui.Input), _: *ui.Context(CloseGuard)) void {
        if (event.data == .close) self.child_requests += 1;
    }
    fn rootInput(self: *CloseGuard, event: *ui.Event(ui.Input), cx: *ui.Context(CloseGuard)) void {
        if (event.data == .close) {
            self.root_requests += 1;
            if (self.dirty) event.preventDefault();
            cx.notify();
        }
    }
    fn allow(self: *CloseGuard, cx: *ui.Context(CloseGuard)) void {
        self.dirty = false;
        cx.notify();
    }
    fn counts(self: *const CloseGuard) [2]usize {
        return .{ self.root_requests, self.child_requests };
    }
};

test "dirty close requests target the root and can be canceled before teardown" {
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const h = try app.openWindow(CloseGuard, .{ .visible = false }, .{});
    const root = try app.windowEntity(CloseGuard, h);
    _ = try app.step(0);
    try t.expect((try app.window(h)).focus != null);
    try app.dispatch(h, .close);
    try t.expect(!(try app.window(h)).closed);
    try t.expectEqual([2]usize{ 1, 0 }, try app.read(root, CloseGuard.counts, .{}));
    _ = try app.step(1);
    try app.update(root, CloseGuard.allow, .{});
    try app.dispatch(h, .close);
    try t.expectError(error.WindowNotFound, app.window(h));
    try t.expectEqual([2]usize{ 2, 0 }, try app.read(root, CloseGuard.counts, .{}));
    _ = try app.step(2);
    try t.expectError(error.EntityNotFound, app.read(root, CloseGuard.counts, .{}));
}
