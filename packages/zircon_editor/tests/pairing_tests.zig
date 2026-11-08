const std = @import("std");
const editor = @import("zircon_editor");
const text = @import("zircon_text");
const ui = @import("zircon_ui");
const t = std.testing;

fn expectText(document: *const text.Document, expected: []const u8) !void {
    var snapshot = document.snapshot();
    defer snapshot.deinit();
    const bytes = try snapshot.copy(t.allocator, .{ .start = 0, .end = snapshot.byteLen() });
    defer t.allocator.free(bytes);
    try t.expectEqualStrings(expected, bytes);
}
fn typeText(state: *editor.Editor, document: *text.Document, bytes: []const u8, native: bool) !void {
    const range = state.primary().range();
    var event: ui.Event(ui.Input) = .{
        .data = if (native) .{ .edit = .{ .revision = document.revision(), .range = .{ .start = range.start, .end = range.end }, .text = bytes, .selection = .{ .start = bytes.len, .end = bytes.len } } } else .{ .text = bytes },
        .bounds = .{ .width = 600, .height = 400 },
    };
    var result = try state.handle(document, &event);
    defer if (result.change) |*change| change.deinit();
    try t.expect(result.handled);
}

test "typed delimiters pair and generated closers are consumed on both input routes" {
    inline for (.{ false, true }) |native| {
        for ([_][2]u8{ .{ '(', ')' }, .{ '[', ']' }, .{ '{', '}' }, .{ '"', '"' }, .{ '\'', '\'' } }) |pair| {
            var document = try text.Document.init(t.allocator, "");
            defer document.deinit();
            var state = try editor.Editor.init(t.allocator);
            defer state.deinit();
            try typeText(&state, &document, pair[0..1], native);
            try expectText(&document, &pair);
            try t.expectEqual(@as(usize, 1), state.primary().head);
            const revision = document.revision();
            try typeText(&state, &document, pair[1..2], native);
            try expectText(&document, &pair);
            try t.expectEqual(@as(usize, 2), state.primary().head);
            try t.expectEqual(revision, document.revision());
        }
    }
}

test "paired Backspace removes both generated delimiters and undo restores their text" {
    var document = try text.Document.init(t.allocator, "");
    defer document.deinit();
    var state = try editor.Editor.init(t.allocator);
    defer state.deinit();
    try typeText(&state, &document, "{", true);
    var outcome = try state.execute(&document, .delete_backward);
    if (outcome.change) |*change| change.deinit();
    try expectText(&document, "");
    outcome = try state.execute(&document, .undo);
    if (outcome.change) |*change| change.deinit();
    try expectText(&document, "{}");
    try t.expectEqual(@as(usize, 1), state.primary().head);
}

test "pairing surrounds reversed selections and retains multiple carets" {
    var document = try text.Document.init(t.allocator, "one\ntwo");
    defer document.deinit();
    var state = try editor.Editor.init(t.allocator);
    defer state.deinit();
    state.selections.single(.{ .anchor = 3, .head = 0 });
    try state.selections.items.append(t.allocator, .{ .anchor = 7, .head = 4 });
    try typeText(&state, &document, "(", true);
    try expectText(&document, "(one)\n(two)");
    try t.expectEqual(@as(usize, 2), state.selections.items.items.len);
    try t.expectEqual(@as(usize, 4), state.primary().anchor);
    try t.expectEqual(@as(usize, 1), state.primary().head);
    try t.expectEqual(@as(usize, 10), state.selections.items.items[1].anchor);
    try t.expectEqual(@as(usize, 7), state.selections.items.items[1].head);
}

test "pairing respects strings comments apostrophes escaped quotes and pasted text" {
    var document = try text.Document.init(t.allocator, "// comment ");
    defer document.deinit();
    var state = try editor.Editor.init(t.allocator);
    defer state.deinit();
    state.language = .zig;
    state.selections.single(.{ .anchor = 11, .head = 11 });
    try typeText(&state, &document, "(", false);
    try expectText(&document, "// comment (");
    var strings = try text.Document.init(t.allocator, "");
    defer strings.deinit();
    var other = try editor.Editor.init(t.allocator);
    defer other.deinit();
    other.language = .zig;
    try typeText(&other, &strings, "\"", true);
    try typeText(&other, &strings, "\\", true);
    try typeText(&other, &strings, "\"", true);
    try expectText(&strings, "\"\\\"\"");
    try typeText(&other, &strings, "(", true);
    try expectText(&strings, "\"\\\"(\"");
    var prose = try text.Document.init(t.allocator, "can");
    defer prose.deinit();
    var plain = try editor.Editor.init(t.allocator);
    defer plain.deinit();
    plain.selections.single(.{ .anchor = 3, .head = 3 });
    try typeText(&plain, &prose, "'", false);
    try expectText(&prose, "can'");
    try typeText(&plain, &prose, "(){}", true);
    try expectText(&prose, "can'(){}");
}

test "composition inserts literal delimiters until the composition is committed" {
    var document = try text.Document.init(t.allocator, "");
    defer document.deinit();
    var state = try editor.Editor.init(t.allocator);
    defer state.deinit();
    var event: ui.Event(ui.Input) = .{
        .data = .{ .edit = .{ .revision = 0, .range = .{ .start = 0, .end = 0 }, .text = "(", .selection = .{ .start = 1, .end = 1 }, .composing = true } },
        .bounds = .{ .width = 600, .height = 400 },
    };
    var result = try state.handle(&document, &event);
    if (result.change) |*change| change.deinit();
    try expectText(&document, "(");
    try t.expect(state.marked != null);
    try t.expectEqual(@as(usize, 0), state.pairs.items.items.len);
}

test "newline between paired braces keeps the closer on its own indented line" {
    var document = try text.Document.init(t.allocator, "    ");
    defer document.deinit();
    var state = try editor.Editor.init(t.allocator);
    defer state.deinit();
    state.tab_width = 2;
    state.selections.single(.{ .anchor = 4, .head = 4 });
    try typeText(&state, &document, "{", true);
    var outcome = try state.execute(&document, .newline);
    if (outcome.change) |*change| change.deinit();
    try expectText(&document, "    {\n      \n    }");
    try t.expectEqual(@as(usize, 12), state.primary().head);
}

test "active bracket scope ignores strings and comments and retains its enclosing guide" {
    const source = "fn main() {\n    if (true) {\n        call(1); // }\n        const text = \"} )\";\n    }\n}\n";
    var document = try text.Document.init(t.allocator, source);
    defer document.deinit();
    var state = try editor.Editor.init(t.allocator);
    defer state.deinit();
    state.language = .zig;
    var snapshot = document.snapshot();
    defer snapshot.deinit();
    state.synchronize(snapshot);
    const inner = std.mem.indexOf(u8, source, "call(1)").? + 4;
    state.selections.single(.{ .anchor = inner + 1, .head = inner + 1 });
    const pair = (try state.bracket_cache.get(&state, snapshot, t.allocator)).?;
    try t.expectEqual(inner, pair.open);
    try t.expectEqual(inner + 2, pair.close);
    const guide = state.bracket_cache.guide.?;
    try t.expectEqual(@as(usize, 1), guide.first_row);
    try t.expectEqual(@as(usize, 4), guide.last_row);
    try t.expectEqual(@as(usize, 4), guide.indent);
    state.selections.single(.{ .anchor = 12, .head = 12 });
    const outer = (try state.bracket_cache.get(&state, snapshot, t.allocator)).?;
    try t.expectEqual(@as(usize, 10), outer.open);
    try t.expectEqual(source.len - 2, outer.close);
}
