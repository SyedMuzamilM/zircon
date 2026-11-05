//! Isolated macOS text tests. The GPU-free framework tests do not import these.
const std = @import("std");
const text = @import("native").text;
const objc = @import("native").objc;
const t = std.testing;

fn pool() objc.Pool {
    return objc.Pool.init();
}

test "native shaping measures text and reuses one owned layout" {
    var autorelease = pool();
    defer autorelease.deinit();
    var system = text.TextSystem.init(t.allocator);
    defer system.deinit();
    const first = try system.layout("Hello, Zircon", 14, false);
    try t.expect(text.CTLineGetGlyphCount(first.line) > 0);
    const width = system.width("Hello, Zircon", 14, false);
    try t.expect(width > 20 and width < 500);
    try t.expectEqual(@as(u64, 1), system.shape_misses);
    try t.expect(system.shape_hits >= 1);
    const again = try system.layout("Hello, Zircon", 14, false);
    try t.expectEqual(first, again);
    try t.expectEqual(@as(usize, 1), system.layout_count);
    try t.expect(system.layout_bytes > 0);
    try t.expectEqual(@as(f32, 0), system.width("", 14, true));
}

test "monospaced caret geometry and hit testing agree on ASCII code" {
    var autorelease = pool();
    defer autorelease.deinit();
    var system = text.TextSystem.init(t.allocator);
    defer system.deinit();
    const source = "const answer = 42;";
    var previous: f32 = -1;
    for (0..source.len + 1) |at| {
        const x = system.caret(source, 14, true, at);
        try t.expect(x > previous);
        previous = x;
        try t.expectEqual(at, system.index(source, 14, true, x));
    }
    try t.expectApproxEqAbs(system.width(source, 14, true), previous, 0.01);
    try t.expectEqual(@as(usize, 0), system.index(source, 14, true, -20));
    try t.expectEqual(source.len, system.index(source, 14, true, 100000));
}

test "fallback glyph runs preserve Unicode measurement and code point boundaries" {
    var autorelease = pool();
    defer autorelease.deinit();
    var system = text.TextSystem.init(t.allocator);
    defer system.deinit();
    const source = "aé🌍日本";
    const shaped = try system.layout(source, 16, true);
    const runs = text.CTLineGetGlyphRuns(shaped.line);
    const count = text.CFArrayGetCount(runs);
    try t.expect(count > 0);
    var glyphs: usize = 0;
    for (0..@intCast(count)) |i| {
        const run = text.CFArrayGetValueAtIndex(runs, @intCast(i));
        glyphs += @intCast(text.CTRunGetGlyphCount(run));
        const attrs = text.CTRunGetAttributes(run);
        try t.expect(text.CFDictionaryGetValue(attrs, text.kCTFontAttributeName) != null);
    }
    try t.expect(glyphs >= 4);
    const positions = [_]usize{ 0, 1, 3, 7, 10, 13 };
    for (positions) |at| {
        const x = system.caret(source, 16, true, at);
        const selected = system.index(source, 16, true, x);
        // CoreText can snap a glyph boundary to either adjacent code point;
        // it must never return the middle of a UTF-8 sequence.
        try t.expect(selected == source.len or source[selected] & 0xc0 != 0x80);
    }
    try t.expect(system.width(source, 16, true) > 20);
}

test "layout cache evicts by both entry count and bounded estimated cost" {
    var autorelease = pool();
    defer autorelease.deinit();
    var system = text.TextSystem.init(t.allocator);
    defer system.deinit();
    var buffer: [128]u8 = undefined;
    for (0..600) |i| {
        const source = try std.fmt.bufPrint(&buffer, "entry {d}", .{i});
        _ = try system.layout(source, 14, true);
        try t.expect(system.layout_count <= 512);
        try t.expect(system.layout_bytes <= 4 * 1024 * 1024);
    }
    const misses = system.shape_misses;
    _ = try system.layout("entry 0", 14, true);
    try t.expectEqual(misses + 1, system.shape_misses);
    const line = try t.allocator.alloc(u8, 8192);
    defer t.allocator.free(line);
    @memset(line, 'a');
    for (0..20) |i| {
        line[0] = @intCast('A' + i);
        _ = try system.layout(line, 14, true);
        try t.expect(system.layout_bytes <= 4 * 1024 * 1024);
    }
    try t.expect(system.layout_count < 20);
}

test "oversized lines are transient and do not empty the bounded cache" {
    var autorelease = pool();
    defer autorelease.deinit();
    var system = text.TextSystem.init(t.allocator);
    defer system.deinit();
    _ = try system.layout("cached", 14, true);
    const cached_bytes = system.layout_bytes;
    const source = try t.allocator.alloc(u8, 80 * 1024);
    defer t.allocator.free(source);
    @memset(source, 'a');
    const large = try system.layout(source, 14, true);
    try t.expect(large.cost > 4 * 1024 * 1024);
    try t.expect(system.temporary != null);
    try t.expectEqual(cached_bytes, system.layout_bytes);
    _ = try system.layout("cached", 14, true);
    try t.expect(system.temporary == null);
    try t.expectEqual(cached_bytes, system.layout_bytes);
}

test "font cache retains shaped runs when font slots are recycled" {
    var autorelease = pool();
    defer autorelease.deinit();
    var system = text.TextSystem.init(t.allocator);
    defer system.deinit();
    const shaped = try system.layout("retained face", 14, true);
    const original_width = text.CTLineGetTypographicBounds(shaped.line, null, null, null);
    for (0..100) |i| {
        _ = try system.font(@as(f32, @floatFromInt(i)) + 20, true);
    }
    try t.expectEqual(@as(usize, 64), system.font_count);
    try t.expectApproxEqAbs(original_width, text.CTLineGetTypographicBounds(shaped.line, null, null, null), 0.001);
}

test "invalid text is refused and native metrics sanitize nonfinite values" {
    var autorelease = pool();
    defer autorelease.deinit();
    var system = text.TextSystem.init(t.allocator);
    defer system.deinit();
    try t.expectError(error.InvalidUtf8, system.layout("\xff", 14, true));
    try t.expectEqual(@as(usize, 0), system.layout_count);
    const normal = system.width("hello", 14, true);
    try t.expectApproxEqAbs(normal, system.width("hello", std.math.nan(f32), true), 0.001);
    try t.expectEqual(@as(usize, 0), system.index("hello", 14, true, std.math.nan(f32)));
    try t.expectEqual(@as(usize, 5), system.index("hello", 14, true, std.math.inf(f32)));
}

test "Zig allocation failures release native layouts and preserve cached entries" {
    var autorelease = pool();
    defer autorelease.deinit();
    try t.checkAllAllocationFailures(t.allocator, allocationScenario, .{});
}

fn allocationScenario(allocator: std.mem.Allocator) !void {
    var system = text.TextSystem.init(allocator);
    defer system.deinit();
    _ = try system.layout("existing", 14, true);
    const count = system.layout_count;
    const bytes = system.layout_bytes;
    _ = system.layout("new layout", 14, true) catch |err| {
        try t.expectEqual(count, system.layout_count);
        try t.expectEqual(bytes, system.layout_bytes);
        try t.expect(system.width("existing", 14, true) > 0);
        return err;
    };
}

test "UTF-16 native ranges round at supplementary and UTF-8 code point boundaries" {
    const source = "aé🌍日";
    const byte_boundaries = [_]usize{ 0, 1, 3, 7, 10 };
    const utf16_boundaries = [_]usize{ 0, 1, 2, 4, 5 };
    for (byte_boundaries, utf16_boundaries) |byte, utf16| {
        try t.expectEqual(utf16, text.byteToUtf16(source, byte));
        try t.expectEqual(byte, text.utf16ToByte(source, utf16));
    }
    try t.expectEqual(@as(usize, 1), text.byteToUtf16(source, 2));
    try t.expectEqual(@as(usize, 2), text.byteToUtf16(source, 6));
    try t.expectEqual(@as(usize, 3), text.utf16ToByte(source, 3));
    try t.expectEqual(@as(usize, 5), text.byteToUtf16(source, std.math.maxInt(usize)));
    try t.expectEqual(source.len, text.utf16ToByte(source, std.math.maxInt(usize)));
    try t.expectEqual(@as(usize, 0), text.byteToUtf16("", 10));
    try t.expectEqual(@as(usize, 0), text.utf16ToByte("", 10));
}
