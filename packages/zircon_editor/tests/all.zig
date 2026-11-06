const std = @import("std");
const text = @import("zircon_text");
const ui = @import("zircon_ui");
const editor = @import("zircon_editor");
const t = std.testing;
test "blame details never displace source rows or caret geometry" {
    var document = try text.Document.init(t.allocator, "one\ntwo\nthree\nfour\nfive\n");
    defer document.deinit();
    var state = try editor.Editor.init(t.allocator);
    defer state.deinit();
    var snapshot = document.snapshot();
    defer snapshot.deinit();
    try state.setBlame(.{ .line = 1, .revision = snapshot.revision(), .author = "Author", .summary = "Summary", .oid = "01234567", .timestamp = 0 });
    const y = state.rowY(2, snapshot.revision());
    try t.expectApproxEqAbs(@as(f32, 2 * 22), y, 0.01);
    try t.expectEqual(@as(usize, 2), state.rowAt(y + 1, snapshot.revision()));
    try t.expectEqual(@as(usize, 2), state.rowAt(2 * 22 + 20, snapshot.revision()));
    state.last_viewport.height = 22;
    try state.setSelection(snapshot, .{ .start = 8, .end = 8 });
    state.reveal(snapshot);
    try t.expectApproxEqAbs(y, state.scroll.offset, 0.01);
    var change = try document.apply(document.revision(), &.{.{ .range = .{ .start = 0, .end = 0 }, .text = "new\n" }}, 0);
    defer change.deinit();
    try t.expectApproxEqAbs(@as(f32, 44), state.rowY(2, document.revision()), 0.01);
}
test "extension lexical profiles classify keywords strings and line comments" {
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    var owned_document = try text.Document.init(t.allocator, "def hello():\n    return 'value' # note\n");
    var owned_state = try editor.Editor.init(t.allocator);
    owned_state.language = .custom;
    owned_state.language_profile = .{ .keywords = &.{ "def", "return" }, .line_comment = "#" };
    var source = owned_document.snapshot();
    owned_state.synchronize(source);
    source.deinit();
    const h = app.openWindow(View, .{ .visible = false, .width = 600, .height = 300 }, .{ .document = owned_document, .state = owned_state }) catch |err| {
        owned_document.deinit();
        owned_state.deinit();
        return err;
    };
    _ = try app.step(0);
    var keyword = false;
    var comment = false;
    var string = false;
    for ((try app.window(h)).frames.committed.scene.items) |item| if (item.kind == .text) {
        if (std.mem.eql(u8, item.text, "def")) keyword = true;
        if (std.mem.eql(u8, item.text, "# note")) comment = true;
        if (std.mem.eql(u8, item.text, "'value'")) string = true;
    };
    try t.expect(keyword and comment and string);
}
fn expectText(document: *const text.Document, expected: []const u8) !void {
    var snapshot = document.snapshot();
    defer snapshot.deinit();
    const bytes = try snapshot.copy(t.allocator, .{ .start = 0, .end = snapshot.byteLen() });
    defer t.allocator.free(bytes);
    try t.expectEqualStrings(expected, bytes);
}
fn release(outcome: *editor.Outcome) void {
    if (outcome.change) |*change| change.deinit();
}
test "Unicode typing movement grouped undo and redo preserve selections" {
    var document = try text.Document.init(t.allocator, "a日b");
    defer document.deinit();
    var state = try editor.Editor.init(t.allocator);
    defer state.deinit();
    var snapshot = document.snapshot();
    defer snapshot.deinit();
    try state.setSelection(snapshot, .{ .start = 4, .end = 4 });
    var outcome = try state.execute(&document, .delete_backward);
    release(&outcome);
    try expectText(&document, "ab");
    outcome = try state.insert(&document, "🙂");
    release(&outcome);
    outcome = try state.insert(&document, "x");
    release(&outcome);
    try expectText(&document, "a🙂xb");
    outcome = try state.execute(&document, .undo);
    release(&outcome);
    try expectText(&document, "ab");
    try t.expectEqual(@as(usize, 1), state.primary().head);
    outcome = try state.execute(&document, .redo);
    release(&outcome);
    try expectText(&document, "a🙂xb");
}
test "multi-cursor insert normalizes overlap and maps peer view positions" {
    var document = try text.Document.init(t.allocator, "alpha beta gamma");
    defer document.deinit();
    var state = try editor.Editor.init(t.allocator);
    defer state.deinit();
    state.selections.single(.{ .anchor = 0, .head = 5 });
    try state.selections.items.append(t.allocator, .{ .anchor = 3, .head = 7 });
    try state.selections.items.append(t.allocator, .{ .anchor = 11, .head = 16 });
    var peer = try editor.Editor.init(t.allocator);
    defer peer.deinit();
    peer.selections.single(.{ .anchor = 16, .head = 16 });
    var outcome = try state.insert(&document, "X");
    defer release(&outcome);
    peer.mapChange(&outcome.change.?);
    try expectText(&document, "Xeta X");
    try t.expectEqual(@as(usize, 6), peer.primary().head);
    try t.expectEqual(@as(usize, 2), state.selections.items.items.len);
}
test "line indentation newline CRLF and selection movement use original byte endings" {
    var document = try text.Document.init(t.allocator, "    fn main() {\r\n}\r\n");
    defer document.deinit();
    var state = try editor.Editor.init(t.allocator);
    defer state.deinit();
    state.selections.single(.{ .anchor = 15, .head = 15 });
    var outcome = try state.execute(&document, .newline);
    release(&outcome);
    try expectText(&document, "    fn main() {\r\n        \r\n}\r\n");
    outcome = try state.execute(&document, .{ .move = .{ .direction = .document_start } });
    release(&outcome);
    outcome = try state.execute(&document, .{ .move = .{ .direction = .down, .extend = true } });
    release(&outcome);
    outcome = try state.execute(&document, .outdent);
    release(&outcome);
    var current = document.snapshot();
    defer current.deinit();
    try t.expect(current.lineCount() >= 4);
}
test "literal find wraps and replace all is one undoable transaction" {
    var document = try text.Document.init(t.allocator, "cat dog cat\ncat");
    defer document.deinit();
    var state = try editor.Editor.init(t.allocator);
    defer state.deinit();
    try t.expect(try state.findNext(&document, "cat", false));
    try t.expectEqual(@as(usize, 0), state.primary().range().start);
    try t.expect(try state.findNext(&document, "cat", false));
    try t.expectEqual(@as(usize, 8), state.primary().range().start);
    var outcome = try state.replaceAll(&document, "cat", "日本");
    release(&outcome);
    try expectText(&document, "日本 dog 日本\n日本");
    outcome = try state.execute(&document, .undo);
    release(&outcome);
    try expectText(&document, "cat dog cat\ncat");
}
test "revisioned composition replaces marked text and commits one history group" {
    var document = try text.Document.init(t.allocator, "ab");
    defer document.deinit();
    var state = try editor.Editor.init(t.allocator);
    defer state.deinit();
    var event: ui.Event(ui.Input) = .{ .data = .{ .edit = .{ .revision = 0, .range = .{ .start = 1, .end = 1 }, .text = "に", .selection = .{ .start = 3, .end = 3 }, .composing = true } } };
    var outcome = try state.handle(&document, &event);
    release(&outcome);
    event.data = .{ .edit = .{ .revision = document.revision(), .range = .{ .start = 1, .end = 4 }, .text = "日本", .selection = .{ .start = 6, .end = 6 } } };
    outcome = try state.handle(&document, &event);
    release(&outcome);
    try expectText(&document, "a日本b");
    outcome = try state.execute(&document, .undo);
    release(&outcome);
    try expectText(&document, "ab");
    try t.expectError(error.StaleTextSnapshot, state.handle(&document, &event));
}
test "tab display mapping and lexical states remain source-byte accurate" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const line = try editor.display.Line.build(arena.allocator(), "\t日x", 4);
    try t.expectEqualStrings("    日x", line.bytes);
    try t.expectEqual(@as(usize, 4), line.displayOffset(1));
    try t.expectEqual(@as(usize, 4), line.sourceOffset(7));
    const first = try editor.syntax.lex(arena.allocator(), "let value = 42; /* comment", .rust, .{});
    try t.expectEqual(@as(usize, 1), first.state.comment_depth);
    const second = try editor.syntax.lex(arena.allocator(), "still */ const value = \"x\";", .rust, first.state);
    try t.expectEqual(@as(usize, 0), second.state.comment_depth);
    try t.expect(second.spans.len >= 3);
    const json = try editor.syntax.lex(arena.allocator(), "{\"enabled\":true}", .json, .{});
    try t.expect(json.spans.len >= 4);
    const markdown = try editor.syntax.lex(arena.allocator(), "# Heading", .markdown, .{});
    try t.expectEqual(editor.syntax.Kind.keyword, markdown.spans[0].kind);
}
const View = struct {
    document: text.Document,
    state: editor.Editor,
    pub fn render(self: *const View, b: *ui.Ui) !ui.Element {
        return b.listen(try self.state.render(&self.document, b), .{ .focusable = true, .on_input = b.onInput(input) });
    }
    fn input(self: *View, e: *ui.Event(ui.Input), cx: *ui.Context(View)) !void {
        var outcome = try self.state.handle(&self.document, e);
        defer release(&outcome);
        if (outcome.handled) cx.notify();
    }
    pub fn deinit(self: *View, _: std.mem.Allocator) void {
        self.state.deinit();
        self.document.deinit();
    }
};
test "custom canvas paints visible lines and owns a bounded committed IME excerpt" {
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(t.allocator);
    for (0..5000) |_| try bytes.appendSlice(t.allocator, "const count: u32 = 42;\n");
    var document = try text.Document.init(t.allocator, bytes.items);

    var state = try editor.Editor.init(t.allocator);

    var snapshot = document.snapshot();
    defer snapshot.deinit();
    state.synchronize(snapshot);
    state.scroll.offset = 2200;
    state.selections.single(.{ .anchor = try snapshot.lineStart(105), .head = try snapshot.lineStart(105) });
    const h = app.openWindow(View, .{ .visible = false, .width = 600, .height = 300 }, .{ .document = document, .state = state }) catch |err| {
        state.deinit();
        document.deinit();
        return err;
    };
    _ = try app.step(0);
    const frame = &(try app.window(h)).frames.committed;
    try t.expect(frame.scene.items.len < 300);
    try t.expect(frame.text_input.?.text.len < bytes.items.len / 10);
    try t.expect(frame.text_input.?.base_byte > 0);
    try app.dispatch(h, .{ .text = "🙂" });
    _ = try app.step(1);
    try t.expect(frame.text_input != null);
}
test "editing allocations fail without corrupting document state" {
    try t.checkAllAllocationFailures(t.allocator, allocationCase, .{});
}
fn allocationCase(a: std.mem.Allocator) !void {
    var document = try text.Document.init(a, "alpha\nbeta\n");
    defer document.deinit();
    var state = try editor.Editor.init(a);
    defer state.deinit();
    state.selections.single(.{ .anchor = 1, .head = 3 });
    var outcome = state.insert(&document, "日本") catch |err| {
        if (err == error.OutOfMemory) try expectText(&document, "alpha\nbeta\n");
        return err;
    };
    defer release(&outcome);
    try expectText(&document, "a日本ha\nbeta\n");
}

test "ordinary native replacements retain typing undo group and duplicate cursors" {
    var document = try text.Document.init(t.allocator, "x x");
    defer document.deinit();
    var state = try editor.Editor.init(t.allocator);
    defer state.deinit();
    state.selections.single(.{ .anchor = 1, .head = 1 });
    try state.selections.items.append(t.allocator, .{ .anchor = 3, .head = 3 });
    var event: ui.Event(ui.Input) = .{ .data = .{ .edit = .{ .revision = 0, .range = .{ .start = 1, .end = 1 }, .text = "a", .selection = .{ .start = 1, .end = 1 } } } };
    var outcome = try state.handle(&document, &event);
    release(&outcome);
    try expectText(&document, "xa xa");
    const primary = state.primary();
    event.data = .{ .edit = .{ .revision = document.revision(), .range = .{ .start = primary.head, .end = primary.head }, .text = "b", .selection = .{ .start = 1, .end = 1 } } };
    outcome = try state.handle(&document, &event);
    release(&outcome);
    try expectText(&document, "xab xab");
    outcome = try state.execute(&document, .undo);
    release(&outcome);
    try expectText(&document, "x x");
}
test "lexical cache invalidates undo and converges after changed comment state" {
    var document = try text.Document.init(t.allocator, "let a=1;\nlet b=2;\nlet c=3;");
    defer document.deinit();
    var state = try editor.Editor.init(t.allocator);
    defer state.deinit();
    state.language = .rust;
    var snapshot = document.snapshot();
    state.synchronize(snapshot);
    snapshot.deinit();
    var outcome = try state.insert(&document, "/*");
    release(&outcome);
    snapshot = document.snapshot();
    try t.expectEqual(@as(usize, 1), state.syntax_cache.state(snapshot, 2).?.comment_depth);
    snapshot.deinit();
    outcome = try state.execute(&document, .undo);
    release(&outcome);
    snapshot = document.snapshot();
    defer snapshot.deinit();
    try t.expectEqual(@as(usize, 0), state.syntax_cache.state(snapshot, 2).?.comment_depth);
}
test "long lines are preserved and canvas reports its explicit rendering limit" {
    const bytes = try t.allocator.alloc(u8, 70 * 1024);
    defer t.allocator.free(bytes);
    @memset(bytes, 'x');
    var document = try text.Document.init(t.allocator, bytes);
    var state = try editor.Editor.init(t.allocator);
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const h = app.openWindow(View, .{ .visible = false, .width = 600, .height = 300 }, .{ .document = document, .state = state }) catch |err| {
        state.deinit();
        document.deinit();
        return err;
    };
    _ = try app.step(0);
    var found = false;
    for ((try app.window(h)).frames.committed.scene.items) |item| if (item.kind == .text and std.mem.indexOf(u8, item.text, "64 KiB") != null) {
        found = true;
    };
    try t.expect(found);
    const root = try app.windowEntity(View, h);
    const Read = struct {
        fn size(value: *const View) usize {
            var snapshot = value.document.snapshot();
            defer snapshot.deinit();
            return snapshot.byteLen();
        }
    };
    try t.expectEqual(bytes.len, try app.read(root, Read.size, .{}));
}
test "editor pointer drag and clipboard go through the committed custom element" {
    var document = try text.Document.init(t.allocator, "alpha beta\nsecond\n");
    var state = try editor.Editor.init(t.allocator);
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    const h = app.openWindow(View, .{ .visible = false, .width = 600, .height = 300 }, .{ .document = document, .state = state }) catch |err| {
        state.deinit();
        document.deinit();
        return err;
    };
    _ = try app.step(0);
    const gutter = editor.gutterWidth(3, 14);
    try app.dispatch(h, .{ .pointer_down = .{ .position = .{ .x = gutter, .y = 5 } } });
    try app.dispatch(h, .{ .pointer_move = .{ .position = .{ .x = gutter + 40, .y = 5 } } });
    try app.dispatch(h, .{ .pointer_up = .{ .position = .{ .x = gutter + 40, .y = 5 } } });
    try app.dispatch(h, .{ .key_down = .{ .key = .c, .modifiers = .{ .command = true } } });
    try app.dispatch(h, .{ .key_down = .{ .key = .end } });
    try app.dispatch(h, .{ .key_down = .{ .key = .v, .modifiers = .{ .command = true } } });
    const root = try app.windowEntity(View, h);
    const Read = struct {
        fn bytes(value: *const View, a: std.mem.Allocator, out: *[]u8) !void {
            var snapshot = value.document.snapshot();
            defer snapshot.deinit();
            out.* = try snapshot.copy(a, .{ .start = 0, .end = snapshot.byteLen() });
        }
    };
    var result: []u8 = undefined;
    try app.read(root, Read.bytes, .{ t.allocator, &result });
    defer t.allocator.free(result);
    try t.expectEqualStrings("alpha betaalpha\nsecond\n", result);
}

test "failed native replacement must preserve selection" {
    var failure = std.testing.FailingAllocator.init(t.allocator, .{});
    var doc = try text.Document.init(failure.allocator(), "abcdef");
    defer doc.deinit();
    var state = try editor.Editor.init(failure.allocator());
    defer state.deinit();
    var snapshot = doc.snapshot();
    defer snapshot.deinit();
    try state.setSelection(snapshot, .{ .start = 1, .end = 2 });
    failure.fail_index = failure.alloc_index;
    var event: ui.Event(ui.Input) = .{ .data = .{ .edit = .{ .revision = doc.revision(), .range = .{ .start = 4, .end = 5 }, .text = "X", .selection = .{ .start = 1, .end = 1 } } } };
    try t.expectError(error.OutOfMemory, state.handle(&doc, &event));
    try t.expectEqual(@as(usize, 1), state.primary().anchor);
    try t.expectEqual(@as(usize, 2), state.primary().head);
}

test "canceling unchanged composition must not undo previous committed typing" {
    var doc = try text.Document.init(t.allocator, "abc");
    defer doc.deinit();
    var state = try editor.Editor.init(t.allocator);
    defer state.deinit();
    var outcome = try state.insert(&doc, "X");
    if (outcome.change) |*change| change.deinit();
    var compose: ui.Event(ui.Input) = .{ .data = .{ .edit = .{ .revision = doc.revision(), .range = .{ .start = 0, .end = 1 }, .text = "X", .selection = .{ .start = 1, .end = 1 }, .composing = true } } };
    outcome = try state.handle(&doc, &compose);
    if (outcome.change) |*change| change.deinit();
    var escape: ui.Event(ui.Input) = .{ .data = .{ .key_down = .{ .key = .escape } } };
    outcome = try state.handle(&doc, &escape);
    if (outcome.change) |*change| change.deinit();
    var snapshot = doc.snapshot();
    defer snapshot.deinit();
    const actual = try snapshot.copy(t.allocator, .{ .start = 0, .end = snapshot.byteLen() });
    defer t.allocator.free(actual);
    try t.expectEqualStrings("Xabc", actual);
}

test "adjacent modified rows paint one continuous Git gutter marker" {
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    var document = try text.Document.init(t.allocator, "first\nsecond\nlast\n");
    var state = try editor.Editor.init(t.allocator);
    state.git_revision = document.revision();
    state.git_changes = try t.allocator.dupe(editor.GitChange, &.{.{ .kind = .modified, .start = 0, .end = 2 }});
    const h = app.openWindow(View, .{ .visible = false, .width = 600, .height = 300 }, .{ .document = document, .state = state }) catch |err| {
        document.deinit();
        state.deinit();
        return err;
    };
    _ = try app.step(0);
    var markers: usize = 0;
    var height: f32 = 0;
    for ((try app.window(h)).frames.committed.scene.items) |item| if (item.kind == .rect and item.rect.x == 4 and item.rect.width == 3) {
        markers += 1;
        height += item.rect.height;
    };
    try t.expectEqual(@as(usize, 1), markers);
    try t.expectApproxEqAbs(@as(f32, 44), height, 0.01);
}

test "expanded removed rows map to current source across start middle and EOF hunks" {
    const changes = [_]editor.GitChange{
        .{ .kind = .deleted, .start = 0, .end = 0, .old_start = 0, .old_count = 2, .removed = "one\ntwo\n", .expanded = true },
        .{ .kind = .modified, .start = 2, .end = 3, .old_start = 4, .old_count = 1, .removed = "middle\n", .expanded = true },
        .{ .kind = .deleted, .start = 4, .end = 4, .old_start = 6, .old_count = 2, .removed = "last\nend", .expanded = true },
    };
    for (0..5) |row| {
        const y = editor.annotations.rowY(row, 22, &changes);
        try t.expectEqual(row, editor.annotations.sourceRow(y + 1, 22, &changes));
    }
    try t.expectEqual(@as(usize, 0), editor.annotations.sourceRow(10, 22, &changes));
    try t.expectEqual(@as(usize, 2), editor.annotations.sourceRow(4 * 22 + 10, 22, &changes));
    try t.expectEqual(@as(usize, 4), editor.annotations.sourceRow(7 * 22 + 10, 22, &changes));
    const columns = editor.annotations.changedColumns("café🙂", "cafè🙂");
    try t.expectEqual(@as(usize, 3), columns.start);
    try t.expectEqual(@as(usize, 5), columns.end);
}
