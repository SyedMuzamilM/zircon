//! Native AppKit window/input fixtures and event-lifecycle assertions.
const std = @import("std");
const scene = @import("../../graphics/scene.zig");
const geometry = @import("../../layout/geometry.zig");
const platform = @import("../interface.zig");
const objc = @import("objc.zig");
const window = @import("window.zig");
const EventLog = struct { down: usize = 0, up: usize = 0, resized: usize = 0, closed: usize = 0, text: usize = 0, keys: usize = 0, position: geometry.Point = .{} };
fn event(raw: *anyopaque, input: platform.Input) !void {
    const log: *EventLog = @ptrCast(@alignCast(raw));
    switch (input) {
        .pointer_down => |p| {
            log.down += 1;
            log.position = p.position;
        },
        .pointer_up => log.up += 1,
        .resize => log.resized += 1,
        .close => log.closed += 1,
        .text => |s| {
            if (std.mem.eql(u8, s, "x")) log.text += 1;
        },
        .key_down => log.keys += 1,
        else => {},
    }
}
test "native window presents and routes queued pointer, text, resize and close events" {
    const allocator = std.testing.allocator;
    const pool = objc.Pool.init();
    defer pool.deinit();
    var log: EventLog = .{};
    const s = try window.open(allocator, .{ .title = "Zircon native test", .width = 480, .height = 320, .visible = true }, .{ .context = &log, .event = event });
    defer s.deinit();
    const frame: scene.Frame = .{ .items = &.{.{ .kind = .rect, .rect = .{ .x = 20, .y = 20, .width = 160, .height = 80 }, .clip = .{ .width = 480, .height = 320 }, .color = .{ .r = 0.2, .g = 0.6, .b = 1 } }}, .background = .{ .r = 0.05, .g = 0.05, .b = 0.07 } };
    const metrics = try s.measurer().text(s.measurer().context, "Hello 日本語", .{});
    if (metrics.width <= 0 or metrics.height <= 0) return error.InvalidMetrics;
    const shaped_caret = s.measurer().caret("a日b", .{}, 4);
    try std.testing.expect(shaped_caret > 0);
    try std.testing.expectEqual(@as(usize, 4), s.measurer().index("a日b", .{}, shaped_caret));
    try s.snapshot(frame, "/tmp/zircon-native-window.png");
    if (!try s.present(frame)) return error.NoDrawable;
    const app = objc.send(objc.Id, objc.class("NSApplication"), "sharedApplication", .{});
    const native_window = findWindow(app, "Zircon native test") orelse return error.TestWindowNotFound;
    const view = objc.send(objc.Id, native_window, "contentView", .{});
    objc.send(void, native_window, "makeKeyWindow", .{});
    _ = objc.send(bool, native_window, "makeFirstResponder:", .{view});
    // Application-queued keys follow the key window at delivery time, not the
    // event's windowNumber. Test this surface through its actual first responder
    // regardless of the user's foreground focus; queued routing is separate.
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = "/tmp/zircon-native-input-mode.txt", .data = "NSWindow.sendEvent through the real first responder; foreground queue tested separately.\n" });
    const number = objc.send(isize, native_window, "windowNumber", .{});
    const point = objc.send(objc.CGPoint, view, "convertPoint:toView:", .{ objc.CGPoint{ .x = 32, .y = 40 }, @as(objc.Id, null) });
    for ([_]usize{ 1, 2 }) |kind| {
        const e = objc.send(objc.Id, objc.class("NSEvent"), "mouseEventWithType:location:modifierFlags:timestamp:windowNumber:context:eventNumber:clickCount:pressure:", .{ kind, point, @as(usize, 0), window.now(), number, @as(objc.Id, null), @as(isize, 0), @as(isize, 1), @as(f32, 1) });
        objc.send(void, app, "postEvent:atStart:", .{ e, false });
    }
    const e = objc.send(objc.Id, objc.class("NSEvent"), "keyEventWithType:location:modifierFlags:timestamp:windowNumber:context:characters:charactersIgnoringModifiers:isARepeat:keyCode:", .{ @as(usize, 10), objc.CGPoint{}, @as(usize, 0), window.now(), number, @as(objc.Id, null), objc.string("x"), objc.string("x"), false, @as(u16, 7) });
    objc.send(void, native_window, "sendEvent:", .{e});
    const input_deadline = window.now() + 1;
    while (window.now() < input_deadline) {
        if (log.down == 1 and log.up == 1 and log.text == 1) break;
        try window.pump(0.01);
    }
    if (log.down != 1 or log.up != 1 or log.position.x != 32 or log.position.y != 40) return error.PointerDispatchFailed;
    try expectTextDispatch(log, app, native_window);
    objc.send(void, native_window, "setContentSize:", .{objc.CGSize{ .width = 600, .height = 400 }});
    for (0..10) |_| try window.pump(0);
    if (s.size().width != 600 or s.size().height != 400 or log.resized == 0) return error.ResizeFailed;
    objc.send(void, native_window, "performClose:", .{@as(objc.Id, null)});
    for (0..10) |_| try window.pump(0);
    // A close notification is a request. The application can keep its window
    // alive while asking whether to save unsaved changes.
    if (log.closed != 1 or !try s.present(frame)) return error.CloseRefusalFailed;
    try std.testing.expect(objc.send(bool, native_window, "isVisible", .{}));
    s.acceptClose();
    s.acceptClose();
    if (try s.present(frame)) return error.CloseFailed;
    try std.testing.expect(!objc.send(bool, native_window, "isVisible", .{}));
    try std.testing.expect(window.now() > 0);
}

test "native window rejects invalid dimensions before creating operating system objects" {
    var log: EventLog = .{};
    const sink: platform.Sink = .{ .context = &log, .event = event };
    try std.testing.expectError(error.InvalidWindowSize, window.open(std.testing.allocator, .{ .width = 0 }, sink));
    try std.testing.expectError(error.InvalidWindowSize, window.open(std.testing.allocator, .{ .height = std.math.nan(f32) }, sink));
    try std.testing.expectError(error.InvalidUtf8, window.open(std.testing.allocator, .{ .title = "\xff" }, sink));
}

test "window-bound key events retain their original window after a focus change" {
    const pool = objc.Pool.init();
    defer pool.deinit();
    var first: EventLog = .{};
    var second: EventLog = .{};
    const first_surface = try window.open(std.testing.allocator, .{ .title = "Zircon first routing target", .visible = true }, .{ .context = &first, .event = event });
    defer first_surface.deinit();
    const app = objc.send(objc.Id, objc.class("NSApplication"), "sharedApplication", .{});
    const first_window = findWindow(app, "Zircon first routing target") orelse return error.TestWindowNotFound;
    const second_surface = try window.open(std.testing.allocator, .{ .title = "Zircon second routing target", .visible = true }, .{ .context = &second, .event = event });
    defer second_surface.deinit();
    const second_window = findWindow(app, "Zircon second routing target") orelse return error.TestWindowNotFound;
    objc.send(void, first_window, "makeKeyWindow", .{});
    const key_event = objc.send(objc.Id, objc.class("NSEvent"), "keyEventWithType:location:modifierFlags:timestamp:windowNumber:context:characters:charactersIgnoringModifiers:isARepeat:keyCode:", .{ @as(usize, 10), objc.CGPoint{}, @as(usize, 0), window.now(), objc.send(isize, first_window, "windowNumber", .{}), @as(objc.Id, null), objc.string("x"), objc.string("x"), false, @as(u16, 7) });
    objc.send(void, second_window, "makeKeyWindow", .{});
    objc.send(void, first_window, "sendEvent:", .{key_event});
    try expectTextDispatch(first, app, first_window);
    try std.testing.expectEqual(@as(usize, 0), second.keys);
    try std.testing.expectEqual(@as(usize, 0), second.text);
}

test "foreground queued key events follow the current key window" {
    const pool = objc.Pool.init();
    defer pool.deinit();
    var first: EventLog = .{};
    var second: EventLog = .{};
    const first_surface = try window.open(std.testing.allocator, .{ .title = "Zircon queued original", .visible = true }, .{ .context = &first, .event = event });
    defer first_surface.deinit();
    const app = objc.send(objc.Id, objc.class("NSApplication"), "sharedApplication", .{});
    const first_window = findWindow(app, "Zircon queued original") orelse return error.TestWindowNotFound;
    const second_surface = try window.open(std.testing.allocator, .{ .title = "Zircon queued current", .visible = true }, .{ .context = &second, .event = event });
    defer second_surface.deinit();
    const second_window = findWindow(app, "Zircon queued current") orelse return error.TestWindowNotFound;
    objc.send(void, first_window, "makeKeyWindow", .{});
    const deadline = window.now() + 1;
    while (!objc.send(bool, app, "isActive", .{}) and window.now() < deadline) try window.pump(0.01);
    if (!objc.send(bool, app, "isActive", .{})) {
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = "/tmp/zircon-native-queued-input-mode.txt", .data = "SKIPPED: foreground queue unavailable, macOS did not activate the test app.\n" });
        return error.SkipZigTest;
    }
    const key_event = objc.send(objc.Id, objc.class("NSEvent"), "keyEventWithType:location:modifierFlags:timestamp:windowNumber:context:characters:charactersIgnoringModifiers:isARepeat:keyCode:", .{ @as(usize, 10), objc.CGPoint{}, @as(usize, 0), window.now(), objc.send(isize, first_window, "windowNumber", .{}), @as(objc.Id, null), objc.string("x"), objc.string("x"), false, @as(u16, 7) });
    objc.send(void, app, "postEvent:atStart:", .{ key_event, false });
    objc.send(void, second_window, "makeKeyWindow", .{});
    try std.testing.expectEqual(second_window, objc.send(objc.Id, app, "keyWindow", .{}));
    const input_deadline = window.now() + 1;
    while ((second.keys == 0 or second.text == 0) and window.now() < input_deadline) try window.pump(0.01);
    try expectTextDispatch(second, app, second_window);
    try std.testing.expectEqual(@as(usize, 0), first.keys);
    try std.testing.expectEqual(@as(usize, 0), first.text);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = "/tmp/zircon-native-queued-input-mode.txt", .data = "PASSED: foreground NSApplication queue delivered to the current key window after focus changed.\n" });
}

fn expectTextDispatch(log: EventLog, app: objc.Id, target: objc.Id) !void {
    if (log.keys == 1 and log.text == 1) return;
    std.debug.print("native dispatch failed: keys={d}, committed x={d}, app active={}, target key={}, target first responder={}\n", .{ log.keys, log.text, objc.send(bool, app, "isActive", .{}), objc.send(bool, target, "isKeyWindow", .{}), objc.send(objc.Id, target, "firstResponder", .{}) == objc.send(objc.Id, target, "contentView", .{}) });
    return error.TextDispatchFailed;
}

const NativeRange = extern struct { location: usize, length: usize };
const EditLog = struct {
    count: usize = 0,
    edit: ?platform.TextEdit = null,
    bytes: [64]u8 = @splat(0),
    unmarked: ?u64 = null,
    refuse_next: bool = false,
    fn receive(raw: *anyopaque, input: platform.Input) !void {
        const log: *@This() = @ptrCast(@alignCast(raw));
        switch (input) {
            .edit => |edit| {
                if (edit.text.len > log.bytes.len) return error.TestTextCapacity;
                @memcpy(log.bytes[0..edit.text.len], edit.text);
                log.edit = edit;
                log.edit.?.text = log.bytes[0..edit.text.len];
                log.count += 1;
                if (log.refuse_next) {
                    log.refuse_next = false;
                    return error.StaleTextSnapshot;
                }
            },
            .unmark => |revision| log.unmarked = revision,
            else => {},
        }
    }
};

test "native text snapshots convert UTF16 replacements and queue composition until revision refresh" {
    const t = std.testing;
    const pool = objc.Pool.init();
    defer pool.deinit();
    var log: EditLog = .{};
    const surface = try window.open(t.allocator, .{ .title = "Zircon input test", .visible = false, .width = 480, .height = 320 }, .{ .context = &log, .event = EditLog.receive });
    defer surface.deinit();
    const app = objc.send(objc.Id, objc.class("NSApplication"), "sharedApplication", .{});
    const native_window = findWindow(app, "Zircon input test") orelse return error.TestWindowNotFound;
    const view = objc.send(objc.Id, native_window, "contentView", .{});
    const caret: geometry.Rect = .{ .x = 32, .y = 44, .width = 2, .height = 20 };
    surface.setTextInput(.{ .text = "a🌍日", .revision = 7, .selection = .{ .start = 1, .end = 5 }, .caret = caret });
    const selected = objc.send(NativeRange, view, "selectedRange", .{});
    try t.expectEqual(@as(usize, 1), selected.location);
    try t.expectEqual(@as(usize, 2), selected.length);
    var actual: NativeRange = undefined;
    const substring = objc.send(objc.Id, view, "attributedSubstringForProposedRange:actualRange:", .{ NativeRange{ .location = 1, .length = 2 }, &actual });
    try t.expectEqualStrings("🌍", objc.fromString(objc.send(objc.Id, substring, "string", .{})));
    try t.expectEqual(selected, actual);
    const rect = objc.send(objc.CGRect, view, "firstRectForCharacterRange:actualRange:", .{ selected, &actual });
    const local: objc.CGRect = .{ .origin = .{ .x = caret.x, .y = caret.y }, .size = .{ .width = caret.width, .height = caret.height } };
    const in_window = objc.send(objc.CGRect, view, "convertRect:toView:", .{ local, @as(objc.Id, null) });
    const expected = objc.send(objc.CGRect, native_window, "convertRectToScreen:", .{in_window});
    try t.expectEqual(expected, rect);
    try t.expectEqual(NativeRange{ .location = 3, .length = 0 }, actual);
    const at_caret = objc.send(usize, view, "characterIndexForPoint:", .{objc.CGPoint{ .x = rect.origin.x + 1, .y = rect.origin.y + 10 }});
    try t.expectEqual(@as(usize, 3), at_caret);
    objc.send(void, view, "insertText:replacementRange:", .{ objc.string("é"), NativeRange{ .location = 1, .length = 2 } });
    try t.expectEqual(@as(usize, 1), log.count);
    try t.expectEqual(@as(u64, 7), log.edit.?.revision);
    try t.expectEqual(platform.TextRange{ .start = 1, .end = 5 }, log.edit.?.range);
    try t.expectEqualStrings("é", log.edit.?.text);
    try t.expect(!log.edit.?.composing);
    const unspecified: NativeRange = .{ .location = @as(usize, std.math.maxInt(isize)), .length = 0 };
    objc.send(void, view, "setMarkedText:selectedRange:replacementRange:", .{ objc.string("に"), NativeRange{ .location = 1, .length = 0 }, unspecified });
    try t.expectEqual(@as(usize, 1), log.count);
    surface.setTextInput(.{ .text = "aé日", .revision = 8, .selection = .{ .start = 3, .end = 3 }, .caret = caret });
    try window.pump(0);
    try t.expectEqual(@as(usize, 2), log.count);
    try t.expectEqual(@as(u64, 8), log.edit.?.revision);
    try t.expectEqual(platform.TextRange{ .start = 3, .end = 3 }, log.edit.?.range);
    try t.expectEqual(platform.TextRange{ .start = 3, .end = 3 }, log.edit.?.selection);
    try t.expect(log.edit.?.composing);
    try t.expectEqualStrings("に", log.edit.?.text);
    surface.setTextInput(.{ .text = "aéに日", .revision = 9, .selection = .{ .start = 6, .end = 6 }, .marked = .{ .start = 3, .end = 6 }, .caret = caret });
    try t.expect(objc.send(bool, view, "hasMarkedText", .{}));
    const marked = objc.send(NativeRange, view, "markedRange", .{});
    try t.expectEqual(NativeRange{ .location = 2, .length = 1 }, marked);
    objc.send(void, view, "insertText:replacementRange:", .{ objc.string("日本"), unspecified });
    try t.expectEqual(@as(u64, 9), log.edit.?.revision);
    try t.expectEqual(platform.TextRange{ .start = 3, .end = 6 }, log.edit.?.range);
    try t.expectEqualStrings("日本", log.edit.?.text);
    try t.expect(!log.edit.?.composing);
    surface.setTextInput(.{ .text = "aé日本日", .revision = 10, .selection = .{ .start = 9, .end = 9 }, .caret = caret });
    try t.expect(!objc.send(bool, view, "hasMarkedText", .{}));
    surface.setTextInput(.{ .text = "aé日本日", .revision = 11, .selection = .{ .start = 9, .end = 9 }, .marked = .{ .start = 3, .end = 9 }, .caret = caret });
    objc.send(void, view, "unmarkText", .{});
    try t.expectEqual(@as(?u64, 11), log.unmarked);
    const before = log.count;
    objc.send(void, view, "insertText:replacementRange:", .{ objc.string("!"), unspecified });
    try t.expectEqual(before, log.count);
    // Unmark changes composition metadata without changing document contents.
    // Any committed publication, even the same revision, releases the queue.
    surface.setTextInput(.{ .text = "aé日本日", .revision = 11, .selection = .{ .start = 9, .end = 9 }, .caret = caret });
    try window.pump(0);
    try t.expectEqual(before + 1, log.count);
    try t.expectEqual(@as(u64, 11), log.edit.?.revision);
    surface.setTextInput(null);
    try t.expectEqual(@as(usize, std.math.maxInt(isize)), objc.send(NativeRange, view, "selectedRange", .{}).location);
}

test "native replacement rejects a UTF16 range splitting an emoji surrogate pair" {
    const pool = objc.Pool.init();
    defer pool.deinit();
    var log: EditLog = .{};
    const surface = try window.open(std.testing.allocator, .{ .title = "Zircon invalid input test", .visible = false }, .{ .context = &log, .event = EditLog.receive });
    defer surface.deinit();
    const app = objc.send(objc.Id, objc.class("NSApplication"), "sharedApplication", .{});
    const native_window = findWindow(app, "Zircon invalid input test") orelse return error.TestWindowNotFound;
    const view = objc.send(objc.Id, native_window, "contentView", .{});
    surface.setTextInput(.{ .text = "🌍", .revision = 1, .selection = .{ .start = 0, .end = 4 }, .caret = .{} });
    objc.send(void, view, "insertText:replacementRange:", .{ objc.string("x"), NativeRange{ .location = 0, .length = 1 } });
    try std.testing.expectError(error.InvalidTextRange, window.pump(0));
    try std.testing.expectEqual(@as(usize, 0), log.count);
}

fn findWindow(app: objc.Id, title: []const u8) objc.Id {
    const list = objc.send(objc.Id, app, "windows", .{});
    const count = objc.send(usize, list, "count", .{});
    for (0..count) |i| {
        const candidate = objc.send(objc.Id, list, "objectAtIndex:", .{i});
        if (std.mem.eql(u8, title, objc.fromString(objc.send(objc.Id, candidate, "title", .{})))) return candidate;
    }
    return null;
}

test "native surrounding text bases preserve global UTF16 and absolute byte coordinates" {
    const t = std.testing;
    const pool = objc.Pool.init();
    defer pool.deinit();
    var log: EditLog = .{};
    const surface = try window.open(t.allocator, .{ .title = "Zircon excerpt input test", .visible = false }, .{ .context = &log, .event = EditLog.receive });
    defer surface.deinit();
    const app = objc.send(objc.Id, objc.class("NSApplication"), "sharedApplication", .{});
    const native_window = findWindow(app, "Zircon excerpt input test") orelse return error.TestWindowNotFound;
    const view = objc.send(objc.Id, native_window, "contentView", .{});
    const snapshot: platform.TextSnapshot = .{ .text = "é🌍b", .base_byte = 1000, .base_utf16 = 100, .revision = 31, .selection = .{ .start = 2, .end = 6 }, .marked = .{ .start = 2, .end = 6 }, .caret = .{ .x = 20, .y = 20, .width = 1, .height = 18 } };
    try snapshot.validate();
    surface.setTextInput(snapshot);
    try t.expectEqual(NativeRange{ .location = 101, .length = 2 }, objc.send(NativeRange, view, "selectedRange", .{}));
    try t.expectEqual(NativeRange{ .location = 101, .length = 2 }, objc.send(NativeRange, view, "markedRange", .{}));
    var actual: NativeRange = undefined;
    const substring = objc.send(objc.Id, view, "attributedSubstringForProposedRange:actualRange:", .{ NativeRange{ .location = 101, .length = 2 }, &actual });
    try t.expectEqualStrings("🌍", objc.fromString(objc.send(objc.Id, substring, "string", .{})));
    try t.expectEqual(NativeRange{ .location = 101, .length = 2 }, actual);
    const unavailable = objc.send(objc.Id, view, "attributedSubstringForProposedRange:actualRange:", .{ NativeRange{ .location = 99, .length = 2 }, &actual });
    try t.expect(unavailable == null);
    try t.expectEqual(@as(usize, std.math.maxInt(isize)), actual.location);
    _ = objc.send(objc.CGRect, view, "firstRectForCharacterRange:actualRange:", .{ NativeRange{ .location = 103, .length = 0 }, &actual });
    try t.expectEqual(NativeRange{ .location = 103, .length = 0 }, actual);
    objc.send(void, view, "insertText:replacementRange:", .{ objc.string("日"), NativeRange{ .location = 101, .length = 2 } });
    try t.expectEqual(@as(usize, 1), log.count);
    try t.expectEqual(platform.TextRange{ .start = 1002, .end = 1006 }, log.edit.?.range);
    try t.expectEqual(platform.TextRange{ .start = 3, .end = 3 }, log.edit.?.selection);
    surface.setTextInput(snapshot);
    objc.send(void, view, "insertText:replacementRange:", .{ objc.string("x"), NativeRange{ .location = 99, .length = 1 } });
    try t.expectError(error.InvalidTextRange, window.pump(0));
    try t.expectEqual(@as(usize, 1), log.count);
    log.refuse_next = true;
    objc.send(void, view, "insertText:replacementRange:", .{ objc.string("a\x00b"), NativeRange{ .location = 101, .length = 2 } });
    try window.pump(0);
    try t.expectEqualStrings("a\x00b", log.edit.?.text);
    try t.expectEqual(@as(usize, 2), log.count);
}
