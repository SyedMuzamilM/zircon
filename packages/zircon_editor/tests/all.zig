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
    for ((try app.window(h)).frames.committed.scene.items) |item| if (item.kind == .rect and item.rect.x == 0 and item.rect.width == 6) {
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

test "macOS command and option delete respect line and word boundaries" {
    var document = try text.Document.init(t.allocator, "first\nalpha beta gamma\nlast");
    defer document.deinit();
    var state = try editor.Editor.init(t.allocator);
    defer state.deinit();
    state.selections.single(.{ .anchor = 16, .head = 16 });
    var event: ui.Event(ui.Input) = .{ .data = .{ .key_down = .{ .key = .backspace, .modifiers = .{ .command = true } } } };
    var outcome = try state.handle(&document, &event);
    release(&outcome);
    try expectText(&document, "first\n gamma\nlast");
    outcome = try state.execute(&document, .undo);
    release(&outcome);
    state.selections.single(.{ .anchor = 16, .head = 16 });
    event = .{ .data = .{ .key_down = .{ .key = .backspace, .modifiers = .{ .alt = true } } } };
    outcome = try state.handle(&document, &event);
    release(&outcome);
    try expectText(&document, "first\nalpha  gamma\nlast");
}

fn vimKeys(state: *editor.Editor, document: *text.Document, bytes: []const u8) !void {
    for (bytes) |byte| {
        var event: ui.Event(ui.Input) = .{ .data = .{ .text = &.{byte} } };
        var result = try state.handle(document, &event);
        defer release(&result);
        try t.expect(event.prevented);
    }
}
fn vimEscape(state: *editor.Editor, document: *text.Document) !void {
    var event: ui.Event(ui.Input) = .{ .data = .{ .key_down = .{ .key = .escape } } };
    var result = try state.handle(document, &event);
    defer release(&result);
}
test "Vim counts operators register paste and history use document transactions" {
    var document = try text.Document.init(t.allocator, "one two three\nfour five\nsix seven\n");
    defer document.deinit();
    var state = try editor.Editor.init(t.allocator);
    defer state.deinit();
    state.setVim(true);
    try vimKeys(&state, &document, "2w");
    try t.expectEqual(@as(usize, 8), state.primary().head);
    try vimKeys(&state, &document, "0dw");
    try expectText(&document, "two three\nfour five\nsix seven\n");
    try vimKeys(&state, &document, "u");
    try expectText(&document, "one two three\nfour five\nsix seven\n");
    try vimKeys(&state, &document, "gg2dd");
    try expectText(&document, "six seven\n");
    try vimKeys(&state, &document, "P");
    try expectText(&document, "one two three\nfour five\nsix seven\n");
    try vimKeys(&state, &document, "ggciw");
    try t.expectEqual(.insert, state.vim.mode);
    try vimKeys(&state, &document, "new");
    try vimEscape(&state, &document);
    try expectText(&document, "new two three\nfour five\nsix seven\n");
    try t.expectEqual(.normal, state.vim.mode);
    try vimKeys(&state, &document, "Q");
    try expectText(&document, "new two three\nfour five\nsix seven\n");
}
test "Vim visual reversal linewise and block operations select inclusive characters" {
    var document = try text.Document.init(t.allocator, "abcd\nefgh\nijkl\n");
    defer document.deinit();
    var state = try editor.Editor.init(t.allocator);
    defer state.deinit();
    state.setVim(true);
    try vimKeys(&state, &document, "lvllhhh");
    try t.expectEqual(.visual, state.vim.mode);
    try t.expectEqual(@as(usize, 0), state.primary().range().start);
    try t.expectEqual(@as(usize, 2), state.primary().range().end);
    try vimEscape(&state, &document);
    try vimKeys(&state, &document, "ggVjy");
    try t.expectEqualStrings("abcd\nefgh\n", state.vim.register);
    var event: ui.Event(ui.Input) = .{ .data = .{ .key_down = .{ .key = .v, .modifiers = .{ .control = true } } } };
    var result = try state.handle(&document, &event);
    release(&result);
    try vimKeys(&state, &document, "jl");
    try t.expectEqual(@as(usize, 2), state.selections.items.items.len);
    try vimKeys(&state, &document, "d");
    try expectText(&document, "cd\ngh\nijkl\n");
}
test "Vim native stale edits cannot insert in Normal and Insert preserves composition" {
    var document = try text.Document.init(t.allocator, "abc");
    defer document.deinit();
    var state = try editor.Editor.init(t.allocator);
    defer state.deinit();
    state.setVim(true);
    var event: ui.Event(ui.Input) = .{ .data = .{ .edit = .{ .revision = 999, .range = .{ .start = 90, .end = 90 }, .text = "l", .selection = .{ .start = 1, .end = 1 } } } };
    var result = try state.handle(&document, &event);
    release(&result);
    try expectText(&document, "abc");
    try t.expectEqual(@as(usize, 1), state.primary().head);
    try vimKeys(&state, &document, "i");
    event = .{ .data = .{ .edit = .{ .revision = document.revision(), .range = .{ .start = 1, .end = 1 }, .text = "日", .selection = .{ .start = 3, .end = 3 }, .composing = true } } };
    result = try state.handle(&document, &event);
    release(&result);
    try expectText(&document, "a日bc");
    try vimEscape(&state, &document);
    try t.expectEqual(.normal, state.vim.mode);
}

test "multiline selections fill continuous rows and Normal mode suppresses native insertion" {
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    var document = try text.Document.init(t.allocator, "abc\n\nxyz");
    var state = try editor.Editor.init(t.allocator);
    state.selections.single(.{ .anchor = 1, .head = 6 });
    const color = state.theme.selection;
    const h = app.openWindow(View, .{ .visible = false, .width = 600, .height = 300 }, .{ .document = document, .state = state }) catch |err| {
        state.deinit();
        document.deinit();
        return err;
    };
    _ = try app.step(0);
    var bands: [3]ui.Rect = undefined;
    var count: usize = 0;
    for ((try app.window(h)).frames.committed.scene.items) |item| if (std.meta.eql(item.color, color)) {
        if (count < bands.len) bands[count] = item.rect;
        count += 1;
    };
    try t.expectEqual(@as(usize, 3), count);
    try t.expectApproxEqAbs(bands[0].y + bands[0].height, bands[1].y, 0.01);
    try t.expectApproxEqAbs(bands[1].y + bands[1].height, bands[2].y, 0.01);
    try t.expect(bands[1].width > 0 and bands[1].width < 20);
    try t.expect(bands[0].width < 100);
    const Mode = struct {
        fn set(self: *View, cx: *ui.Context(View), enabled: bool) void {
            self.state.setVim(enabled);
            cx.notify();
        }
    };
    const owner = try app.windowEntity(View, h);
    try app.update(owner, Mode.set, .{true});
    _ = try app.step(0);
    try t.expect((try app.window(h)).frames.committed.text_input == null);
    try app.dispatch(h, .{ .text = "i" });
    _ = try app.step(0);
    try t.expect((try app.window(h)).frames.committed.text_input != null);
}
test "Vim change and open line undo together with typed text and final-line deletion stays linewise" {
    var document = try text.Document.init(t.allocator, "one two\nlast");
    defer document.deinit();
    var state = try editor.Editor.init(t.allocator);
    defer state.deinit();
    state.setVim(true);
    try vimKeys(&state, &document, "cwnew");
    try vimEscape(&state, &document);
    try expectText(&document, "new two\nlast");
    try vimKeys(&state, &document, "u");
    try expectText(&document, "one two\nlast");
    try vimKeys(&state, &document, "Gdd");
    try expectText(&document, "one two");
    try t.expectEqualStrings("last\n", state.vim.register);
    try vimKeys(&state, &document, "u");
    try vimKeys(&state, &document, "ggccchanged");
    try vimEscape(&state, &document);
    try expectText(&document, "changed\nlast");
    try vimKeys(&state, &document, "uohello");
    try vimEscape(&state, &document);
    try expectText(&document, "one two\nhello\nlast");
    try vimKeys(&state, &document, "u");
    try expectText(&document, "one two\nlast");
}

test "Vim dot repeats word operations and inserted text in one undo transaction" {
    var document = try text.Document.init(t.allocator, "one two three\n");
    defer document.deinit();
    var state = try editor.Editor.init(t.allocator);
    defer state.deinit();
    state.setVim(true);
    try vimKeys(&state, &document, "cwnew");
    try vimEscape(&state, &document);
    try vimKeys(&state, &document, "w.");
    try expectText(&document, "new new three\n");
    try vimKeys(&state, &document, "u");
    try expectText(&document, "new two three\n");
    try vimKeys(&state, &document, "ggdw.");
    try expectText(&document, "three\n");
    try vimKeys(&state, &document, "i");
    var event: ui.Event(ui.Input) = .{ .data = .{ .text = "日" } };
    var result = try state.handle(&document, &event);
    release(&result);
    try vimEscape(&state, &document);
    try vimKeys(&state, &document, "l.");
    try expectText(&document, "日日three\n");
    try vimKeys(&state, &document, "u");
    try expectText(&document, "日three\n");
}

test "Vim block registers paste by row and block insertion edits every selected line" {
    var document = try text.Document.init(t.allocator, "abcd\nefgh\nijkl\n");
    defer document.deinit();
    var state = try editor.Editor.init(t.allocator);
    defer state.deinit();
    state.setVim(true);
    var event: ui.Event(ui.Input) = .{ .data = .{ .key_down = .{ .key = .v, .modifiers = .{ .control = true } } } };
    var result = try state.handle(&document, &event);
    release(&result);
    try vimKeys(&state, &document, "jly");
    try t.expectEqualStrings("ab\nef", state.vim.register);
    try vimKeys(&state, &document, "$p");
    try expectText(&document, "abcdab\nefghef\nijkl\n");
    try vimKeys(&state, &document, "ugg");
    event = .{ .data = .{ .key_down = .{ .key = .v, .modifiers = .{ .control = true } } } };
    result = try state.handle(&document, &event);
    release(&result);
    try vimKeys(&state, &document, "jI>");
    try vimEscape(&state, &document);
    try expectText(&document, ">abcd\n>efgh\nijkl\n");
    try vimKeys(&state, &document, "u");
    try expectText(&document, "abcd\nefgh\nijkl\n");
}
test "Vim search repeats literals and word motion follows shaped tab columns" {
    var document = try text.Document.init(t.allocator, "one two one\n\tabc\n1234567\n");
    defer document.deinit();
    var state = try editor.Editor.init(t.allocator);
    defer state.deinit();
    state.setVim(true);
    try vimKeys(&state, &document, "*");
    try t.expectEqual(@as(usize, 8), state.primary().head);
    try vimKeys(&state, &document, "n");
    try t.expectEqual(@as(usize, 0), state.primary().head);
    try vimKeys(&state, &document, "jlj");
    var s = document.snapshot();
    defer s.deinit();
    try t.expectEqual(@as(usize, 4), (try s.pointAt(state.primary().head)).byte_column);
}

test "modal input remains valid across empty Unicode CRLF and mixed command sequences" {
    for ([_][]const u8{ "", "a", "\n\n", "a\r\nb\r\n", "日🙂\n\ttext\nlast" }) |source| {
        var document = try text.Document.init(t.allocator, source);
        defer document.deinit();
        var state = try editor.Editor.init(t.allocator);
        defer state.deinit();
        state.setVim(true);
        var random = std.Random.DefaultPrng.init(0x76123);
        const keys = "hjklweb0^$%{}HMLggGvVdcyxXpPuJraioOAIfFtT><123*#nN. ";
        for (0..350) |i| {
            if (i % 13 == 0) try vimEscape(&state, &document) else {
                const key = keys[random.random().uintLessThan(usize, keys.len)];
                try vimKeys(&state, &document, &.{key});
            }
            var s = document.snapshot();
            defer s.deinit();
            try t.expect(state.selections.items.items.len > 0);
            for (state.selections.items.items) |item| try s.validateRange(item.range());
            try t.expect(s.isBoundary(@min(state.vim.cursor, s.byteLen())));
        }
    }
}

test "macOS line deletion consumes CRLF at boundaries and merges multicursor ranges" {
    var document = try text.Document.init(t.allocator, "one\r\ntwo\r\nlast");
    defer document.deinit();
    var state = try editor.Editor.init(t.allocator);
    defer state.deinit();
    state.selections.single(.{ .anchor = 5, .head = 5 });
    var result = try state.execute(&document, .{ .delete_to = .{ .direction = .home } });
    release(&result);
    try expectText(&document, "onetwo\r\nlast");
    result = try state.execute(&document, .undo);
    release(&result);
    state.selections.single(.{ .anchor = 6, .head = 6 });
    try state.selections.items.append(t.allocator, .{ .anchor = 8, .head = 8 });
    result = try state.execute(&document, .{ .delete_to = .{ .direction = .home } });
    release(&result);
    try expectText(&document, "one\r\n\r\nlast");
}

test "default selection is distinct from active line and gutter labels retain contrast" {
    for ([_]editor.Theme{ .{}, editor.Theme.light }) |theme| {
        try t.expect(!std.meta.eql(theme.selection, theme.active_line));
        const high = @max(luminance(theme.line_number), luminance(theme.background));
        const low = @min(luminance(theme.line_number), luminance(theme.background));
        try t.expect((high + 0.05) / (low + 0.05) >= 3);
    }
}
fn luminance(color: ui.Color) f32 {
    var channels = [_]f32{ color.r, color.g, color.b };
    for (&channels) |*channel| channel.* = if (channel.* <= 0.04045) channel.* / 12.92 else std.math.pow(f32, (channel.* + 0.055) / 1.055, 2.4);
    return channels[0] * 0.2126 + channels[1] * 0.7152 + channels[2] * 0.0722;
}

test "narrow editor advertises horizontal overflow and scrolls to reveal source" {
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    var document = try text.Document.init(t.allocator, "const message = \"A source line that deliberately exceeds the narrow editor width\";\n");
    var state = try editor.Editor.init(t.allocator);
    const scrollbar = state.theme.scrollbar;
    const h = app.openWindow(View, .{ .visible = false, .width = 250, .height = 180 }, .{ .document = document, .state = state }) catch |err| {
        document.deinit();
        state.deinit();
        return err;
    };
    _ = try app.step(0);
    var horizontal = false;
    for ((try app.window(h)).frames.committed.scene.items) |item| if (item.kind == .rect and std.meta.eql(item.color, scrollbar) and item.rect.height == 4 and item.rect.width > 24) {
        horizontal = true;
    };
    try t.expect(horizontal);
    try app.dispatch(h, .{ .scroll = .{ .position = .{ .x = 150, .y = 80 }, .x = -100, .y = 0 } });
    _ = try app.step(0);
    const Read = struct {
        fn offset(self: *const View) f32 {
            return self.state.horizontal;
        }
    };
    const owner = try app.windowEntity(View, h);
    try t.expectEqual(@as(f32, 100), try app.read(owner, Read.offset, .{}));
}

test "word wrapping preserves UTF8 source boundaries and reuses its visual map" {
    var doc = try text.Document.init(t.allocator, "alpha beta gamma delta\n日🙂abcdefghi\n\tindented words follow here\n");
    defer doc.deinit();
    var source = doc.snapshot();
    defer source.deinit();
    const cache = try editor.wrap.Cache.init(t.allocator);
    defer cache.release();
    var fixed: ui.layout.FixedMetrics = .{ .advance = 8, .line_height = 22 };
    try cache.ensure(source, 80, 14, 4, fixed.measurer());
    try t.expect(cache.rows.items.len > source.lineCount());
    const first = cache.rows.items[0];
    const bytes = try source.copy(t.allocator, .{ .start = first.start, .end = first.end });
    defer t.allocator.free(bytes);
    try t.expectEqualStrings("alpha ", bytes);
    for (cache.rows.items) |row| {
        try t.expect(source.isBoundary(row.start) and source.isBoundary(row.end));
        try t.expectEqual(row.line, (try source.pointAt(row.start)).line);
    }
    const builds = cache.builds;
    try cache.ensure(source, 80, 14, 4, fixed.measurer());
    try t.expectEqual(builds, cache.builds);
    try cache.ensure(source, 160, 14, 4, fixed.measurer());
    try t.expectEqual(builds + 1, cache.builds);
    try expectText(&doc, "alpha beta gamma delta\n日🙂abcdefghi\n\tindented words follow here\n");
}

test "wrapped canvas paints continuation rows and pointer and arrow navigation use them" {
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    var doc = try text.Document.init(t.allocator, "alpha beta gamma delta epsilon zeta eta theta iota kappa\nsecond line\n");
    var state = try editor.Editor.init(t.allocator);
    state.soft_wrap = .editor_width;
    const h = app.openWindow(View, .{ .visible = false, .width = 200, .height = 300 }, .{ .document = doc, .state = state }) catch |err| {
        doc.deinit();
        state.deinit();
        return err;
    };
    _ = try app.step(0);
    const owner = try app.windowEntity(View, h);
    const Read = struct {
        fn current(self: *const View) usize {
            return self.state.primary().head;
        }
        fn part(self: *const View) editor.wrap.Row {
            return self.state.wrap_cache.rows.items[1];
        }
    };
    const part = try app.read(owner, Read.part, .{});
    try t.expect(part.start > 0 and part.line == 0);
    try app.dispatch(h, .{ .pointer_down = .{ .position = .{ .x = 54, .y = 25 } } });
    try app.dispatch(h, .{ .pointer_up = .{ .position = .{ .x = 54, .y = 25 } } });
    try t.expectEqual(part.start, try app.read(owner, Read.current, .{}));
    try app.dispatch(h, .{ .key_down = .{ .key = .up } });
    try t.expectEqual(@as(usize, 0), try app.read(owner, Read.current, .{}));
    try app.dispatch(h, .{ .key_down = .{ .key = .down } });
    try t.expectEqual(part.start, try app.read(owner, Read.current, .{}));
    if (comptime ui.testing.native != void) try (try app.window(h)).snapshot("/tmp/zircon-word-wrap.png");
}

test "active source line has the same background across every wrapped row" {
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    var doc = try text.Document.init(t.allocator, "alpha beta gamma delta epsilon zeta eta theta iota kappa\nsecond line\n");
    var state = try editor.Editor.init(t.allocator);
    state.soft_wrap = .editor_width;
    const color = state.theme.active_line;
    const line_height = state.line_height;
    const h = app.openWindow(View, .{ .visible = false, .width = 200, .height = 300 }, .{ .document = doc, .state = state }) catch |err| {
        doc.deinit();
        state.deinit();
        return err;
    };
    _ = try app.step(0);
    const Read = struct {
        fn rows(self: *const View) usize {
            return self.state.wrap_cache.starts.items[1];
        }
    };
    const owner = try app.windowEntity(View, h);
    const rows = try app.read(owner, Read.rows, .{});
    try t.expect(rows > 1);
    var painted: usize = 0;
    for ((try app.window(h)).frames.committed.scene.items) |item| {
        if (item.kind == .rect and std.meta.eql(item.color, color) and item.rect.width == 200) {
            try t.expectApproxEqAbs(@as(f32, @floatFromInt(painted)) * line_height, item.rect.y, 0.01);
            painted += 1;
        }
    }
    try t.expectEqual(rows, painted);
}

test "wrapped continuation text retains leading space and tab indentation" {
    for ([_][]const u8{ "    alpha beta gamma delta epsilon zeta", "\talpha beta gamma delta epsilon zeta", "  \talpha beta gamma delta epsilon zeta" }) |source| {
        var doc = try text.Document.init(t.allocator, source);
        defer doc.deinit();
        var snapshot = doc.snapshot();
        defer snapshot.deinit();
        const cache = try editor.wrap.Cache.init(t.allocator);
        defer cache.release();
        var fixed: ui.layout.FixedMetrics = .{ .advance = 8, .line_height = 22 };
        const metrics = fixed.measurer();
        var arena = std.heap.ArenaAllocator.init(t.allocator);
        defer arena.deinit();
        const line = try editor.display.Line.build(arena.allocator(), source, 4);
        try cache.ensure(snapshot, 120, 14, 4, metrics);
        try t.expect(cache.rows.items.len > 1);
        var next: usize = 0;
        for (cache.rows.items) |row| {
            try t.expectEqual(next, row.start);
            try t.expect(row.end > row.start);
            const left = line.caret(metrics, .{ .size = 14, .mono = true }, row.start) - row.x;
            const right = line.caret(metrics, .{ .size = 14, .mono = true }, row.end) - row.x;
            try t.expectApproxEqAbs(if (row.first) @as(f32, 0) else 32, left, 0.01);
            try t.expect(right <= 120.01);
            next = row.end;
        }
        try t.expectEqual(source.len, next);
        try expectText(&doc, source);
    }
}

test "indented wrapped rows keep clicks carets and vertical navigation aligned" {
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    var doc = try text.Document.init(t.allocator, "\talpha beta gamma delta epsilon zeta eta theta iota kappa\n");
    var state = try editor.Editor.init(t.allocator);
    state.soft_wrap = .editor_width;
    const h = app.openWindow(View, .{ .visible = false, .width = 260, .height = 400 }, .{ .document = doc, .state = state }) catch |err| {
        doc.deinit();
        state.deinit();
        return err;
    };
    _ = try app.step(0);
    const Read = struct {
        fn part(self: *const View) editor.wrap.Row {
            return self.state.wrap_cache.rows.items[1];
        }
        fn head(self: *const View) usize {
            return self.state.primary().head;
        }
    };
    const owner = try app.windowEntity(View, h);
    const part = try app.read(owner, Read.part, .{});
    const metrics = (try app.window(h)).surface.?.measurer();
    const indent = metrics.caret("    ", .{ .size = 14, .mono = true }, 4);
    const x = editor.gutterWidth(2, 14) + indent;
    for ([_]f32{ x - 10, x }) |click_x| {
        try app.dispatch(h, .{ .pointer_down = .{ .position = .{ .x = click_x, .y = 27 } } });
        try app.dispatch(h, .{ .pointer_up = .{ .position = .{ .x = click_x, .y = 27 } } });
        _ = try app.step(0);
        try t.expectEqual(part.start, try app.read(owner, Read.head, .{}));
        try t.expectApproxEqAbs(x, (try app.window(h)).frames.committed.text_input.?.caret.x, 0.1);
    }
    try app.dispatch(h, .{ .key_down = .{ .key = .up } });
    try t.expectEqual(@as(usize, 1), try app.read(owner, Read.head, .{}));
    try app.dispatch(h, .{ .key_down = .{ .key = .down } });
    try t.expectEqual(part.start, try app.read(owner, Read.head, .{}));
    if (comptime ui.testing.native != void) {
        _ = try app.step(0);
        try (try app.window(h)).snapshot("/tmp/zircon-indented-wrap.png");
    }
}

test "deep indentation and unbroken Unicode tokens wrap with bounded progress" {
    var doc = try text.Document.init(t.allocator, "                            日🙂abcdefghijklmnop\n    abcdefghijklmnopqrstuvwxyz\n        \n");
    defer doc.deinit();
    var snapshot = doc.snapshot();
    defer snapshot.deinit();
    const cache = try editor.wrap.Cache.init(t.allocator);
    defer cache.release();
    var fixed: ui.layout.FixedMetrics = .{ .advance = 8, .line_height = 22 };
    try cache.ensure(snapshot, 48, 14, 4, fixed.measurer());
    try t.expect(cache.rows.items.len < snapshot.byteLen());
    for (cache.rows.items) |row| {
        const range = try snapshot.lineRange(row.line);
        try t.expect(row.end > row.start or range.start == range.end);
        try t.expect(snapshot.isBoundary(row.start) and snapshot.isBoundary(row.end));
    }
}

test "inline Git change backgrounds cover the gutter and source on wrapped rows" {
    for ([_]bool{ false, true }) |wrap| {
        var app = try ui.App.init(.{ .allocator = t.allocator });
        defer app.deinit();
        var doc = try text.Document.init(t.allocator, "    new alpha beta gamma delta epsilon zeta\nnext\n");
        var state = try editor.Editor.init(t.allocator);
        state.soft_wrap = if (wrap) .editor_width else .none;
        state.git_revision = doc.revision();
        state.git_changes = try t.allocator.dupe(editor.GitChange, &.{.{ .kind = .modified, .start = 0, .end = 1, .old_start = 0, .old_count = 1, .expanded = true, .removed = "old\n" }});
        const h = app.openWindow(View, .{ .visible = false, .width = 240, .height = 300 }, .{ .document = doc, .state = state }) catch |err| {
            doc.deinit();
            state.deinit();
            return err;
        };
        _ = try app.step(0);
        const frame = &(try app.window(h)).frames.committed;
        // Sample the painted backgrounds away from the Git strip, text and caret.
        for ([_]f32{ 5, 27, 49 }) |y| {
            const gutter = backgroundAt(frame.scene.items, .{ .x = 12, .y = y });
            const source = backgroundAt(frame.scene.items, .{ .x = editor.gutterWidth(3, 14) - 2, .y = y });
            try t.expectApproxEqAbs(source.r, gutter.r, 0.001);
            try t.expectApproxEqAbs(source.g, gutter.g, 0.001);
            try t.expectApproxEqAbs(source.b, gutter.b, 0.001);
        }
        if (comptime ui.testing.native != void) if (wrap) try (try app.window(h)).snapshot("/tmp/zircon-inline-git-gutter.png");
    }
}

fn backgroundAt(items: @FieldType(ui.graphics.Scene, "items"), point: ui.Point) ui.Color {
    var result: ui.Color = .{ .r = 0, .g = 0, .b = 0 };
    for (items) |item| {
        if (item.kind != .rect) continue;
        const rect = item.rect;
        const clip = item.clip;
        if (point.x < rect.x or point.x >= rect.x + rect.width or point.y < rect.y or point.y >= rect.y + rect.height or point.x < clip.x or point.x >= clip.x + clip.width or point.y < clip.y or point.y >= clip.y + clip.height) continue;
        result.r = item.color.r * item.color.a + result.r * (1 - item.color.a);
        result.g = item.color.g * item.color.a + result.g * (1 - item.color.a);
        result.b = item.color.b * item.color.a + result.b * (1 - item.color.a);
    }
    return result;
}

test "wrapped edits reshape changed lines and retain UTF8 mappings in the suffix" {
    var doc = try text.Document.init(t.allocator, "one two three four five\nunchanged 日🙂 line\nlast\n");
    defer doc.deinit();
    var state = try editor.Editor.init(t.allocator);
    defer state.deinit();
    state.soft_wrap = .editor_width;
    var before = doc.snapshot();
    defer before.deinit();
    var fixed: ui.layout.FixedMetrics = .{ .advance = 8, .line_height = 22 };
    try state.wrap_cache.ensure(before, 80, 14, 4, fixed.measurer());
    const shaped = state.wrap_cache.shaped_lines;
    var outcome = try state.applyEdits(&doc, &.{.{ .range = .{ .start = 3, .end = 3 }, .text = " new\ninserted" }}, 0);
    defer release(&outcome);
    var after = doc.snapshot();
    defer after.deinit();
    try state.wrap_cache.ensure(after, 80, 14, 4, fixed.measurer());
    try t.expectEqual(shaped + 2, state.wrap_cache.shaped_lines);
    const fresh = try editor.wrap.Cache.init(t.allocator);
    defer fresh.release();
    try fresh.ensure(after, 80, 14, 4, fixed.measurer());
    try t.expectEqualSlices(editor.wrap.Row, fresh.rows.items, state.wrap_cache.rows.items);
    var deletion = try state.applyEdits(&doc, &.{.{ .range = .{ .start = 0, .end = 13 }, .text = "" }}, 0);
    defer release(&deletion);
    var deleted = doc.snapshot();
    defer deleted.deinit();
    try state.wrap_cache.ensure(deleted, 80, 14, 4, fixed.measurer());
    try fresh.ensure(deleted, 80, 14, 4, fixed.measurer());
    try t.expectEqualSlices(editor.wrap.Row, fresh.rows.items, state.wrap_cache.rows.items);
}

test "wrapped Git deletion blocks map to the changed source and unwrap clamps scroll" {
    var doc = try text.Document.init(t.allocator, "alpha beta gamma delta epsilon\nnext source line\n");
    defer doc.deinit();
    var snapshot = doc.snapshot();
    defer snapshot.deinit();
    var state = try editor.Editor.init(t.allocator);
    defer state.deinit();
    state.soft_wrap = .editor_width;
    var metrics: ui.layout.FixedMetrics = .{ .advance = 8, .line_height = 22 };
    try state.prepareView(snapshot, .{ .width = 160, .height = 44 }, metrics.measurer());
    const changes = [_]editor.annotations.GitChange{.{ .kind = .modified, .start = 1, .end = 2, .old_count = 2, .expanded = true }};
    const bottom = state.wrap_cache.y(1, 22, &changes);
    try t.expectEqual(state.wrap_cache.starts.items[1], state.wrap_cache.visualAt(bottom - 30, 22, &changes));
    try state.setSelection(snapshot, .{ .start = snapshot.byteLen(), .end = snapshot.byteLen() });
    state.reveal(snapshot);
    try t.expect(state.scroll.offset > 0);
    state.soft_wrap = .none;
    try state.prepareView(snapshot, .{ .width = 160, .height = 200 }, metrics.measurer());
    try t.expectEqual(@as(f32, 0), state.scroll.offset);
}

test "Cmd slash toggles selected lines with indentation and undo while gcc comments the current line" {
    var document = try text.Document.init(t.allocator, "    const x = 1;\n    const y = 2;\nnext\n");
    defer document.deinit();
    var state = try editor.Editor.init(t.allocator);
    defer state.deinit();
    state.language = .zig;
    state.selections.single(.{ .anchor = 4, .head = 34 });
    var event: ui.Event(ui.Input) = .{ .data = .{ .key_down = .{ .key = .slash, .modifiers = .{ .command = true } } } };
    var outcome = try state.handle(&document, &event);
    release(&outcome);
    try expectText(&document, "    // const x = 1;\n    // const y = 2;\nnext\n");
    outcome = try state.handle(&document, &event);
    release(&outcome);
    try expectText(&document, "    const x = 1;\n    const y = 2;\nnext\n");
    state.selections.single(.{ .anchor = 4, .head = 4 });
    state.setVim(true);
    try vimKeys(&state, &document, "gcc");
    try expectText(&document, "    // const x = 1;\n    const y = 2;\nnext\n");
    try vimKeys(&state, &document, "u");
    try expectText(&document, "    const x = 1;\n    const y = 2;\nnext\n");
}

test "comments use extension delimiters and block-only profiles with CRLF and multiple cursors" {
    var document = try text.Document.init(t.allocator, "  日 = 1\r\n  x = 2\r\n");
    defer document.deinit();
    var state = try editor.Editor.init(t.allocator);
    defer state.deinit();
    state.language = .custom;
    state.language_profile = .{ .keywords = &.{}, .line_comment = "# " };
    state.selections.single(.{ .anchor = 2, .head = 2 });
    try state.selections.items.append(t.allocator, .{ .anchor = 14, .head = 14 });
    var result = try state.execute(&document, .toggle_comment);
    release(&result);
    try expectText(&document, "  # 日 = 1\r\n  # x = 2\r\n");
    try t.expectEqual(@as(usize, 2), state.selections.items.items.len);
    result = try state.execute(&document, .toggle_comment);
    release(&result);
    try expectText(&document, "  日 = 1\r\n  x = 2\r\n");
    state.language_profile = .{ .keywords = &.{}, .block_comment = .{ .start = "<!--", .end = "-->" } };
    state.selections.single(.{ .anchor = 2, .head = 2 });
    result = try state.execute(&document, .toggle_comment);
    release(&result);
    try expectText(&document, "  <!-- 日 = 1 -->\r\n  x = 2\r\n");
    result = try state.execute(&document, .toggle_comment);
    release(&result);
    try expectText(&document, "  日 = 1\r\n  x = 2\r\n");
}

test "folding hides body rows without wrapping and revealing a hidden cursor unfolds it" {
    var doc = try text.Document.init(t.allocator, "fn main() {\n    one();\n    two();\n}\nnext();\n");
    defer doc.deinit();
    var state = try editor.Editor.init(t.allocator);
    defer state.deinit();
    var source = doc.snapshot();
    defer source.deinit();
    var fixed: ui.layout.FixedMetrics = .{ .advance = 8, .line_height = 22 };
    try t.expect(try state.toggleFold(source, 0));
    try state.prepareView(source, .{ .width = 400, .height = 200 }, fixed.measurer());
    try t.expectEqual(@as(usize, 3), state.wrap_cache.rows.items.len);
    try t.expectEqual(@as(usize, 4), state.rowAt(22, source.revision()));
    try t.expectApproxEqAbs(@as(f32, 22), state.rowY(4, source.revision()), 0.01);
    var result = try state.execute(&doc, .{ .move = .{ .direction = .right } });
    release(&result);
    try t.expectEqual(@as(usize, 1), state.wrap_cache.folding.collapsed.items.len);
    const hidden = try source.lineStart(2);
    try state.setSelection(source, .{ .start = hidden, .end = hidden });
    state.reveal(source);
    try t.expectEqual(@as(usize, 0), state.wrap_cache.folding.collapsed.items.len);
    try t.expectEqual(@as(usize, 2), state.rowAt(44, source.revision()));
}

test "folded wrapped buffers keep row mappings and Vim vertical motion skips folded text" {
    var doc = try text.Document.init(t.allocator, "fn main() {\n    one();\n    two();\n}\nnext();\n");
    defer doc.deinit();
    var state = try editor.Editor.init(t.allocator);
    defer state.deinit();
    state.soft_wrap = .editor_width;
    state.setVim(true);
    var source = doc.snapshot();
    defer source.deinit();
    var fixed: ui.layout.FixedMetrics = .{ .advance = 8, .line_height = 22 };
    try t.expect(try state.toggleFold(source, 0));
    try state.prepareView(source, .{ .width = 400, .height = 200 }, fixed.measurer());
    try vimKeys(&state, &doc, "j");
    try t.expectEqual(@as(usize, 4), (try source.pointAt(state.primary().head)).line);
    try t.expectEqual(@as(usize, 1), state.wrap_cache.folding.collapsed.items.len);
}
test "folds survive edits before a header and unfolding restores all wrapped source rows" {
    var doc = try text.Document.init(t.allocator, "before\nfn main() {\n    one();\n    two();\n}\nafter\n");
    defer doc.deinit();
    var state = try editor.Editor.init(t.allocator);
    defer state.deinit();
    state.soft_wrap = .editor_width;
    var fixed: ui.layout.FixedMetrics = .{ .advance = 8, .line_height = 22 };
    {
        var source = doc.snapshot();
        defer source.deinit();
        try t.expect(try state.toggleFold(source, 1));
        try state.prepareView(source, .{ .width = 400, .height = 200 }, fixed.measurer());
    }
    var outcome = try state.applyEdits(&doc, &.{.{ .range = .{ .start = 0, .end = 0 }, .text = "added\n" }}, 0);
    release(&outcome);
    var source = doc.snapshot();
    defer source.deinit();
    const header = try source.lineStart(2);
    try state.setSelection(source, .{ .start = header, .end = header });
    try state.prepareView(source, .{ .width = 400, .height = 200 }, fixed.measurer());
    try t.expectEqual(@as(usize, 1), state.wrap_cache.folding.collapsed.items.len);
    try t.expectEqual(@as(usize, 5), state.wrap_cache.rows.items.len);
    try t.expect(try state.toggleFold(source, 2));
    try state.prepareView(source, .{ .width = 400, .height = 200 }, fixed.measurer());
    try t.expectEqual(source.lineCount(), state.wrap_cache.rows.items.len);
    for (state.wrap_cache.rows.items, 0..) |row, i| try t.expectEqual(i, row.line);
}
