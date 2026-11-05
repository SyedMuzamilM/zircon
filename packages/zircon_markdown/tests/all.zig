const std = @import("std");
const md = @import("zircon_markdown");
const t = std.testing;
test "blocks preserve UTF8 CRLF ranges and parse headings paragraphs lists quotes and fences" {
    const source = "# Hello 日\r\n\r\nA paragraph\r\ncontinued **bold**.\r\n\r\n- first\r\n2. second\r\n> quoted\r\n\r\n```zig\r\nconst n = 1;\r\n```\r\n";
    var doc = try md.parse(t.allocator, source);
    defer doc.deinit();
    try t.expectEqual(@as(usize, 6), doc.blocks.len);
    try t.expectEqualStrings("Hello 日", doc.blocks[0].content);
    try t.expectEqual(@as(u8, 1), doc.blocks[0].level);
    try t.expect(doc.blocks[1].kind == .paragraph);
    try t.expect(std.mem.indexOf(u8, doc.blocks[1].content, "continued") != null);
    try t.expect(doc.blocks[2].kind == .list_item and !doc.blocks[2].ordered);
    try t.expect(doc.blocks[3].ordered);
    try t.expectEqual(@as(usize, 2), doc.blocks[3].number);
    try t.expect(doc.blocks[4].kind == .quote);
    try t.expect(doc.blocks[5].kind == .code);
    try t.expectEqualStrings("zig", doc.blocks[5].info);
    try t.expectEqualStrings("const n = 1;\r\n", doc.blocks[5].content);
    for (doc.blocks) |block| try t.expect(block.source.end <= source.len and block.source.start <= block.source.end);
}
test "inline styles links images code escapes and unmatched delimiters are explicit" {
    const source = "**Strong** and *emphasis* with `code` [link](guide.md) ![alt](image.png) \\*literal*";
    var doc = try md.parse(t.allocator, source);
    defer doc.deinit();
    var strong = false;
    var emphasis = false;
    var code = false;
    var link = false;
    var image = false;
    for (doc.blocks[0].inlines) |span| {
        strong = strong or span.strong;
        emphasis = emphasis or span.emphasis;
        code = code or span.kind == .code;
        if (span.kind == .link) {
            link = true;
            try t.expectEqualStrings("guide.md", span.target.?);
        }
        if (span.kind == .image) {
            image = true;
            try t.expectEqualStrings("image.png", span.target.?);
        }
        try t.expect(span.source.end <= source.len);
    }
    try t.expect(strong and emphasis and code and link and image);
    var malformed = try md.parse(t.allocator, "[bad](unterminated **literal");
    defer malformed.deinit();
    try t.expectEqualStrings("[bad](unterminated **literal", malformed.blocks[0].inlines[0].text);
}
test "tables parse alignment source cells escaped pipes and inline code pipes" {
    const source = "| Name | Value |\n| :--- | ---: |\n| **one** | `a|b` |\n| two\\|three | [next](next.md) |\n";
    var doc = try md.parse(t.allocator, source);
    defer doc.deinit();
    try t.expectEqual(@as(usize, 1), doc.blocks.len);
    const table = doc.blocks[0].table.?;
    try t.expectEqual(@as(usize, 3), table.rows.len);
    try t.expectEqual(@as(usize, 2), table.rows[1].cells.len);
    try t.expect(table.alignments[1] == .end);
    try t.expect(table.rows[1].cells[0].content[0].strong);
}
test "setext rules and unterminated fences remain valid source blocks" {
    var doc = try md.parse(t.allocator, "Title\n=====\n\n---\n\n~~~rust\nfn main() {}\n");
    defer doc.deinit();
    try t.expectEqual(@as(usize, 3), doc.blocks.len);
    try t.expect(doc.blocks[0].kind == .heading and doc.blocks[1].kind == .rule and doc.blocks[2].kind == .code);
    try t.expectError(error.InvalidUtf8, md.parse(t.allocator, "\xff"));
}
test "document copies caller memory and frees all partial parse allocations" {
    var bytes = [_]u8{ '#', ' ', 'a' };
    var doc = try md.parse(t.allocator, &bytes);
    defer doc.deinit();
    @memset(&bytes, 'x');
    try t.expectEqualStrings("a", doc.blocks[0].content);
    try t.checkAllAllocationFailures(t.allocator, allocationCase, .{});
}
fn allocationCase(a: std.mem.Allocator) !void {
    var doc = try md.parse(a, "# Heading\n\nText **bold** [link](next.md).\n\n| A | B |\n| --- | --- |\n| x | y |\n\n```zig\nconst n=1;\n```\n");
    defer doc.deinit();
}
