const std = @import("std");
const ui = @import("zircon_ui");
const t = std.testing;
test "themed search fields center text and use the same inset for hit testing" {
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    var input = try ui.controls.TextInput.init(t.allocator, "sample");
    input.leading_icon = .search;
    const handle = try app.openWindow(ui.controls.TextInput, .{ .visible = false, .width = 300, .height = 80 }, input);
    const owner = try app.windowEntity(ui.controls.TextInput, handle);
    const appearance: ui.controls.TextInput.Appearance = .{ .background = .white, .foreground = .black };
    try app.update(owner, ui.controls.TextInput.setAppearance, .{appearance});
    _ = try app.step(0);
    const window = try app.window(handle);
    const caret = window.frames.committed.text_input.?.caret;
    try t.expectApproxEqAbs(@as(f32, 6), caret.y, 0.01);
    var found = false;
    for (window.frames.committed.scene.items) |item| if (item.kind == .text and std.mem.eql(u8, item.text, "sample")) {
        try t.expectEqual(ui.Color.black, item.color);
        try t.expectApproxEqAbs(@as(f32, 28), item.rect.x, 0.01);
        found = true;
    };
    try t.expect(found);
    try app.dispatch(handle, .{ .pointer_down = .{ .position = .{ .x = 44, .y = 15 } } });
    try app.dispatch(handle, .{ .pointer_up = .{ .position = .{ .x = 44, .y = 15 } } });
    _ = try app.step(0.1);
    try t.expectEqual(@as(usize, 2), window.frames.committed.text_input.?.selection.start);
    try app.update(owner, ui.controls.TextInput.setAppearance, .{appearance});
    try t.expectEqual(@as(usize, 0), try app.step(0.2));
}
test "text field edits Unicode selection clipboard and revisioned composition through window dispatch" {
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const field = try ui.controls.TextInput.init(t.allocator, "a日b");
    const h = try app.openWindow(ui.controls.TextInput, .{ .visible = false, .width = 300, .height = 80 }, field);
    const root = try app.windowEntity(ui.controls.TextInput, h);
    _ = try app.step(0);
    try t.expect((try app.window(h)).frames.committed.text_input != null);
    try app.dispatch(h, .{ .key_down = .{ .key = .left } });
    try app.dispatch(h, .{ .key_down = .{ .key = .backspace } });
    var text: []u8 = undefined;
    try app.read(root, ui.controls.TextInput.copy, .{ t.allocator, &text });
    try t.expectEqualStrings("ab", text);
    t.allocator.free(text);
    try app.dispatch(h, .{ .key_down = .{ .key = .a, .modifiers = .{ .command = true } } });
    try app.dispatch(h, .{ .key_down = .{ .key = .c, .modifiers = .{ .command = true } } });
    try app.dispatch(h, .{ .text = "🙂" });
    try app.dispatch(h, .{ .key_down = .{ .key = .v, .modifiers = .{ .command = true } } });
    try app.read(root, ui.controls.TextInput.copy, .{ t.allocator, &text });
    try t.expectEqualStrings("🙂ab", text);
    t.allocator.free(text);
    _ = try app.step(1);
    const snap = (try app.window(h)).frames.committed.text_input.?;
    try app.dispatch(h, .{ .edit = .{ .revision = snap.revision, .range = .{ .start = 4, .end = 6 }, .text = "日本", .selection = .{ .start = 6, .end = 6 }, .composing = true } });
    _ = try app.step(2);
    const composed = (try app.window(h)).frames.committed.text_input.?;
    try t.expectEqualStrings("🙂日本", composed.text);
    try t.expectEqual(@as(usize, 4), composed.marked.?.start);
    try t.expectError(error.StaleTextSnapshot, app.dispatch(h, .{ .edit = .{ .revision = snap.revision, .range = .{ .start = 0, .end = 0 }, .text = "x", .selection = .{ .start = 1, .end = 1 } } }));
}
test "virtual list range and scrolling keep render work proportional to viewport" {
    const visible = try ui.controls.visibleRows(1_000_000, 20, 400, 100, 2);
    try t.expectEqual(@as(usize, 18), visible.start);
    try t.expectEqual(@as(usize, 28), visible.end);
    try t.expectEqual(@as(f32, -40), visible.top);
    const shortened = try ui.controls.visibleRows(3, 24, 1000, 48, 0);
    try t.expectEqual(@as(usize, 1), shortened.start);
    try t.expectEqual(@as(usize, 3), shortened.end);
    try t.expectEqual(@as(f32, 0), shortened.top);
    var scroll: ui.controls.Scroll = .{};
    scroll.wheel(-500, 1000, 100);
    try t.expectEqual(@as(f32, 500), scroll.offset);
    scroll.reveal(30, 50, 1000, 100);
    try t.expectEqual(@as(f32, 30), scroll.offset);
    scroll.wheel(-5000, 1000, 100);
    try t.expectEqual(@as(f32, 900), scroll.offset);
    try t.expectError(error.InvalidViewport, ui.controls.visibleRows(1, 0, 0, 100, 1));
}
test "typed keymap shares semantic commands and rejects ambiguous bindings" {
    const Action = enum { save, find };
    const Map = ui.Keymap(Action);
    const map = try Map.init(&.{ .{ .chord = .{ .key = .s, .modifiers = .{ .command = true } }, .action = .save }, .{ .chord = .{ .key = .f, .modifiers = .{ .command = true } }, .action = .find } });
    try t.expectEqual(Action.save, map.resolve(.{ .key_down = .{ .key = .s, .modifiers = .{ .command = true } } }).?);
    try t.expect(map.resolve(.{ .key_down = .{ .key = .s } }) == null);
    try t.expectError(error.DuplicateKeyBinding, Map.init(&.{ .{ .chord = .{ .key = .s }, .action = .save }, .{ .chord = .{ .key = .s }, .action = .find } }));
}

test "shared SVG icons retain filled shapes and source opacity under theme tinting" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var painter = try ui.graphics.Painter.init(arena.allocator(), .{ .width = 100, .height = 40 });
    try ui.controls.icons.draw(.settings, &painter, .{ .width = 16, .height = 16 }, .white);
    var fill = false;
    for (painter.items.items) |item| if (item.kind == .rect) {
        fill = true;
        try t.expect(item.color.a > 0.9);
    };
    try t.expect(fill);
    painter.items.clearRetainingCapacity();
    try ui.controls.icons.draw(.search, &painter, .{ .x = 20, .width = 16, .height = 16 }, .black);
    var translucent = false;
    for (painter.items.items) |item| if (item.kind == .rect and item.color.a < 0.2) {
        translucent = true;
    };
    try t.expect(translucent);
}

test "search fields honor macOS command and option deletion on UTF8 boundaries" {
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const field = try ui.controls.TextInput.init(t.allocator, "one 日🙂");
    const h = try app.openWindow(ui.controls.TextInput, .{ .visible = false, .width = 300, .height = 80 }, field);
    const root = try app.windowEntity(ui.controls.TextInput, h);
    _ = try app.step(0);
    try app.dispatch(h, .{ .key_down = .{ .key = .backspace, .modifiers = .{ .alt = true } } });
    var actual: []u8 = undefined;
    try app.read(root, ui.controls.TextInput.copy, .{ t.allocator, &actual });
    defer t.allocator.free(actual);
    try t.expectEqualStrings("one ", actual);
    try app.dispatch(h, .{ .key_down = .{ .key = .backspace, .modifiers = .{ .command = true } } });
    _ = try app.step(0);
    try t.expectEqualStrings("", (try app.window(h)).frames.committed.text_input.?.text);
}
