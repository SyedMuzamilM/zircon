//! CoreText shaping and bounded ownership, implemented with direct Zig bindings.
//! Cached lines retain their CoreFoundation strings and font runs. A returned
//! layout is borrowed until the next `layout` call; callers consume its runs
//! before requesting another line. UTF-16 never escapes the platform adapter.
const std = @import("std");

pub const CFRef = *const anyopaque;
pub const CFStringRef = CFRef;
pub const CTLineRef = CFRef;
pub const CTFontRef = CFRef;
pub const CTRunRef = CFRef;
pub const CFIndex = isize;
pub const CGPoint = extern struct { x: f64, y: f64 };
pub const CFRange = extern struct { location: CFIndex, length: CFIndex };

pub extern "c" fn CFRelease(value: CFRef) void;
pub extern "c" fn CFRetain(value: CFRef) CFRef;
pub extern "c" fn CFStringCreateWithBytes(allocator: ?CFRef, bytes: [*]const u8, length: CFIndex, encoding: u32, external_representation: u8) ?CFStringRef;
pub extern "c" fn CFStringGetLength(string: CFStringRef) CFIndex;
pub extern "c" fn CFAttributedStringCreateMutable(allocator: ?CFRef, max_length: CFIndex) ?CFRef;
pub extern "c" fn CFAttributedStringReplaceString(string: CFRef, range: CFRange, replacement: CFStringRef) void;
pub extern "c" fn CFAttributedStringSetAttribute(string: CFRef, range: CFRange, name: CFStringRef, value: CFRef) void;
pub extern "c" fn CFNumberCreate(allocator: ?CFRef, number_type: CFIndex, value: *const anyopaque) ?CFRef;
pub extern "c" fn CFArrayGetCount(array: CFRef) CFIndex;
pub extern "c" fn CFArrayGetValueAtIndex(array: CFRef, index_value: CFIndex) CFRef;
pub extern "c" fn CFDictionaryGetValue(dictionary: CFRef, key: CFRef) ?CFRef;
pub extern "c" fn CTFontCreateWithName(name: CFStringRef, size: f64, matrix: ?*const anyopaque) ?CTFontRef;
pub extern "c" fn CTFontCreateUIFontForLanguage(ui_type: u32, size: f64, language: ?CFStringRef) ?CTFontRef;
pub extern "c" fn CTFontGetSize(font_ref: CTFontRef) f64;
pub extern "c" fn CTLineCreateWithAttributedString(string: CFRef) ?CTLineRef;
pub extern "c" fn CTLineGetTypographicBounds(line: CTLineRef, ascent: ?*f64, descent: ?*f64, leading: ?*f64) f64;
pub extern "c" fn CTLineGetOffsetForStringIndex(line: CTLineRef, index_value: CFIndex, secondary_offset: ?*f64) f64;
pub extern "c" fn CTLineGetStringIndexForPosition(line: CTLineRef, position: CGPoint) CFIndex;
pub extern "c" fn CTLineGetGlyphCount(line: CTLineRef) CFIndex;
pub extern "c" fn CTLineGetGlyphRuns(line: CTLineRef) CFRef;
pub extern "c" fn CTRunGetGlyphCount(run: CTRunRef) CFIndex;
pub extern "c" fn CTRunGetGlyphs(run: CTRunRef, range: CFRange, glyphs: [*]u16) void;
pub extern "c" fn CTRunGetPositions(run: CTRunRef, range: CFRange, positions: [*]CGPoint) void;
pub extern "c" fn CTRunGetAttributes(run: CTRunRef) CFRef;
pub extern "c" const kCTFontAttributeName: CFStringRef;
pub extern "c" const kCTLigatureAttributeName: CFStringRef;

pub const Layout = struct {
    line: CTLineRef,
    string: CFStringRef,
    cost: usize,
    text: []u8,
    hash: u64,
    size: f32,
    mono: bool,
};

const max_layouts = 512;
const layout_budget = 4 * 1024 * 1024;
const Font = struct { value: CTFontRef, size: f32, mono: bool };

pub const TextSystem = struct {
    allocator: std.mem.Allocator,
    layouts: [max_layouts]?*Layout = @splat(null),
    first_layout: usize = 0,
    layout_count: usize = 0,
    fonts: [64]?Font = @splat(null),
    font_count: usize = 0,
    next_font: usize = 0,
    /// An oversized line can be shaped without displacing the entire cache.
    /// It is released on the next layout request and is not cached memory.
    temporary: ?*Layout = null,
    layout_bytes: usize = 0,
    shape_hits: u64 = 0,
    shape_misses: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) TextSystem {
        return .{ .allocator = allocator };
    }

    pub fn deinit(system: *TextSystem) void {
        for (system.layouts) |entry| if (entry) |line| system.destroyLayout(line);
        if (system.temporary) |line| system.destroyLayout(line);
        for (system.fonts) |entry| if (entry) |face| CFRelease(face.value);
        system.* = .{ .allocator = system.allocator };
    }

    /// The font is borrowed. Retain it when keeping it beyond a shaping call,
    /// for example as a renderer's glyph-cache key.
    pub fn font(system: *TextSystem, requested_size: f32, mono: bool) !CTFontRef {
        const size = normalizedSize(requested_size);
        for (system.fonts[0..system.font_count]) |entry| {
            const face = entry.?;
            if (face.size == size and face.mono == mono) return face.value;
        }
        const value = if (mono) try namedFont("Menlo", size) else CTFontCreateUIFontForLanguage(2, size, null) orelse try namedFont("Helvetica", size);
        if (system.font_count < system.fonts.len) {
            system.fonts[system.font_count] = .{ .value = value, .size = size, .mono = mono };
            system.font_count += 1;
        } else {
            const slot = system.next_font;
            CFRelease(system.fonts[slot].?.value);
            system.fonts[slot] = .{ .value = value, .size = size, .mono = mono };
            system.next_font = (slot + 1) % system.fonts.len;
        }
        return value;
    }

    pub fn layout(system: *TextSystem, bytes: []const u8, requested_size: f32, mono: bool) !*Layout {
        if (system.temporary) |line| {
            system.destroyLayout(line);
            system.temporary = null;
        }
        if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
        const size = normalizedSize(requested_size);
        const hash = std.hash.Wyhash.hash(0, bytes);
        for (0..system.layout_count) |i| {
            const entry = system.layouts[(system.first_layout + i) % max_layouts].?;
            if (entry.hash == hash and entry.size == size and entry.mono == mono and std.mem.eql(u8, entry.text, bytes)) {
                system.shape_hits +%= 1;
                return entry;
            }
        }
        system.shape_misses +%= 1;
        const face = try system.font(size, mono);
        const string = try createString(bytes);
        errdefer CFRelease(string);
        const attributed = CFAttributedStringCreateMutable(null, 0) orelse return error.OutOfMemory;
        defer CFRelease(attributed);
        CFAttributedStringReplaceString(attributed, .{ .location = 0, .length = 0 }, string);
        const whole: CFRange = .{ .location = 0, .length = CFStringGetLength(string) };
        CFAttributedStringSetAttribute(attributed, whole, kCTFontAttributeName, face);
        const zero: i32 = 0;
        const ligature = CFNumberCreate(null, 3, &zero) orelse return error.OutOfMemory;
        defer CFRelease(ligature);
        CFAttributedStringSetAttribute(attributed, whole, kCTLigatureAttributeName, ligature);
        const line = CTLineCreateWithAttributedString(attributed) orelse return error.OutOfMemory;
        errdefer CFRelease(line);
        const owned_bytes = try system.allocator.dupe(u8, bytes);
        errdefer system.allocator.free(owned_bytes);
        const entry = try system.allocator.create(Layout);
        const glyphs: usize = @intCast(@max(0, CTLineGetGlyphCount(line)));
        // Includes the copied UTF-8 key, CoreText's UTF-16 string and estimated
        // run/glyph storage. It is a cache budget, not an OS allocation counter.
        const cost = bytes.len *| 4 +| glyphs *| 64 +| @sizeOf(Layout) +| 256;
        entry.* = .{ .line = line, .string = string, .text = owned_bytes, .cost = cost, .hash = hash, .size = size, .mono = mono };
        if (cost > layout_budget) {
            system.temporary = entry;
            return entry;
        }
        while (system.layout_count > 0 and (system.layout_count == max_layouts or system.layout_bytes + cost > layout_budget)) {
            const old = system.layouts[system.first_layout].?;
            system.layouts[system.first_layout] = null;
            system.first_layout = (system.first_layout + 1) % max_layouts;
            system.layout_count -= 1;
            system.layout_bytes -= old.cost;
            system.destroyLayout(old);
        }
        const slot = (system.first_layout + system.layout_count) % max_layouts;
        system.layouts[slot] = entry;
        system.layout_count += 1;
        system.layout_bytes += cost;
        return entry;
    }

    pub fn width(system: *TextSystem, bytes: []const u8, size: f32, mono: bool) f32 {
        if (bytes.len == 0) return 0;
        const shaped = system.layout(bytes, size, mono) catch return 0;
        return @floatCast(CTLineGetTypographicBounds(shaped.line, null, null, null));
    }

    pub fn caret(system: *TextSystem, bytes: []const u8, size: f32, mono: bool, at: usize) f32 {
        if (bytes.len == 0) return 0;
        const shaped = system.layout(bytes, size, mono) catch return 0;
        return @floatCast(CTLineGetOffsetForStringIndex(shaped.line, @intCast(byteToUtf16(bytes, at)), null));
    }

    pub fn index(system: *TextSystem, bytes: []const u8, size: f32, mono: bool, x: f32) usize {
        if (bytes.len == 0 or x <= 0 or std.math.isNan(x)) return 0;
        if (std.math.isInf(x)) return bytes.len;
        const shaped = system.layout(bytes, size, mono) catch return 0;
        const at = CTLineGetStringIndexForPosition(shaped.line, .{ .x = x, .y = 0 });
        if (at < 0) return bytes.len;
        return utf16ToByte(bytes, @intCast(at));
    }

    fn destroyLayout(system: *TextSystem, entry: *Layout) void {
        CFRelease(entry.line);
        CFRelease(entry.string);
        system.allocator.free(entry.text);
        system.allocator.destroy(entry);
    }
};

fn normalizedSize(size: f32) f32 {
    if (!std.math.isFinite(size)) return 14;
    return @round(std.math.clamp(size, 4, 256) * 64) / 64;
}

fn namedFont(name: []const u8, size: f32) !CTFontRef {
    const string = try createString(name);
    defer CFRelease(string);
    return CTFontCreateWithName(string, size, null) orelse return error.OutOfMemory;
}

fn createString(bytes: []const u8) !CFStringRef {
    return CFStringCreateWithBytes(null, bytes.ptr, @intCast(bytes.len), 0x08000100, 0) orelse error.OutOfMemory;
}

/// Clamp a byte offset to a code-point boundary and count native UTF-16 units.
/// Valid UTF-8 is the public text contract; malformed bytes advance as one unit
/// so a rejected native event cannot cause an out-of-bounds read here.
pub fn byteToUtf16(bytes: []const u8, byte_offset: usize) usize {
    const limit = @min(byte_offset, bytes.len);
    var at: usize = 0;
    var units: usize = 0;
    while (at < limit) {
        const length: usize = std.unicode.utf8ByteSequenceLength(bytes[at]) catch 1;
        if (at + length > limit or at + length > bytes.len) break;
        const codepoint = std.unicode.utf8Decode(bytes[at..][0..length]) catch 0xfffd;
        units += if (codepoint > 0xffff) @as(usize, 2) else 1;
        at += length;
    }
    return units;
}

/// A native offset within a surrogate pair maps to the code point's first byte.
pub fn utf16ToByte(bytes: []const u8, utf16_offset: usize) usize {
    var at: usize = 0;
    var units: usize = 0;
    while (at < bytes.len) {
        const length: usize = std.unicode.utf8ByteSequenceLength(bytes[at]) catch 1;
        if (at + length > bytes.len) return at;
        const codepoint = std.unicode.utf8Decode(bytes[at..][0..length]) catch 0xfffd;
        const step: usize = if (codepoint > 0xffff) 2 else 1;
        if (units >= utf16_offset or units + step > utf16_offset) return at;
        units += step;
        at += length;
    }
    return bytes.len;
}

test "native UTF-16 ranges preserve accented code points and surrogate pairs" {
    const text = "aé🌍日";
    try std.testing.expectEqual(@as(usize, 0), byteToUtf16(text, 0));
    try std.testing.expectEqual(@as(usize, 1), byteToUtf16(text, 2));
    try std.testing.expectEqual(@as(usize, 2), byteToUtf16(text, 3));
    try std.testing.expectEqual(@as(usize, 2), byteToUtf16(text, 6));
    try std.testing.expectEqual(@as(usize, 4), byteToUtf16(text, 7));
    try std.testing.expectEqual(@as(usize, 5), byteToUtf16(text, 999));
    try std.testing.expectEqual(@as(usize, 3), utf16ToByte(text, 3));
    try std.testing.expectEqual(@as(usize, 7), utf16ToByte(text, 4));
    try std.testing.expectEqual(text.len, utf16ToByte(text, 999));
}
