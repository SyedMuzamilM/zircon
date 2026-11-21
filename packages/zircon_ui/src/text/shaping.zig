//! CoreText shaping and bounded ownership, implemented with direct Zig bindings.
//! Cached lines retain their CoreFoundation strings and font runs. A returned
//! layout is borrowed until the next `layout` call; callers consume its runs
//! before requesting another line. UTF-16 never escapes the platform adapter.

const std = @import("std");
const typography_module = @import("typography.zig");
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
extern "c" fn CFHash(value: CFRef) usize;
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
extern "c" fn CFDataCreate(?CFRef, [*]const u8, CFIndex) ?CFRef;
extern "c" fn CFDataCreateWithBytesNoCopy(?CFRef, [*]const u8, CFIndex, CFRef) ?CFRef;
extern "c" const kCFAllocatorNull: CFRef;
extern "c" fn CGDataProviderCreateWithCFData(CFRef) ?CFRef;
extern "c" fn CGDataProviderRelease(CFRef) void;
extern "c" fn CGFontCreateWithDataProvider(CFRef) ?CFRef;
extern "c" fn CGFontRelease(CFRef) void;
extern "c" fn CTFontCreateWithGraphicsFont(CFRef, f64, ?*const anyopaque, ?CFRef) ?CTFontRef;
extern "c" fn CTFontCreateCopyWithAttributes(CTFontRef, f64, ?*const anyopaque, ?CFRef) ?CTFontRef;
extern "c" fn CTFontDescriptorCreateWithAttributes(CFRef) ?CFRef;
const DictionaryKeyCallbacks = extern struct { version: CFIndex, retain: ?*const anyopaque, release: ?*const anyopaque, description: ?*const anyopaque, equal: ?*const anyopaque, hash: ?*const anyopaque };
const ValueCallbacks = extern struct { version: CFIndex, retain: ?*const anyopaque, release: ?*const anyopaque, description: ?*const anyopaque, equal: ?*const anyopaque };
extern "c" const kCFTypeDictionaryKeyCallBacks: DictionaryKeyCallbacks;
extern "c" const kCFTypeDictionaryValueCallBacks: ValueCallbacks;
extern "c" const kCFTypeArrayCallBacks: ValueCallbacks;
extern "c" const kCTFontFeatureSettingsAttribute: CFRef;
extern "c" const kCTFontOpenTypeFeatureTag: CFRef;
extern "c" const kCTFontOpenTypeFeatureValue: CFRef;
extern "c" fn CFDictionaryCreate(?CFRef, [*]const CFRef, [*]const CFRef, CFIndex, *const DictionaryKeyCallbacks, *const ValueCallbacks) ?CFRef;
extern "c" fn CFArrayCreate(?CFRef, [*]const CFRef, CFIndex, *const ValueCallbacks) ?CFRef;
pub extern "c" fn CTLineCreateWithAttributedString(string: CFRef) ?CTLineRef;
pub extern "c" fn CTLineGetTypographicBounds(line: CTLineRef, ascent: ?*f64, descent: ?*f64, leading: ?*f64) f64;
pub extern "c" fn CTLineGetOffsetForStringIndex(line: CTLineRef, index_value: CFIndex, secondary_offset: ?*f64) f64;
pub extern "c" fn CTLineGetStringIndexForPosition(line: CTLineRef, position: CGPoint) CFIndex;
pub extern "c" fn CTLineGetGlyphCount(line: CTLineRef) CFIndex;
pub extern "c" fn CTLineGetGlyphRuns(line: CTLineRef) CFRef;
pub extern "c" fn CTRunGetGlyphCount(run: CTRunRef) CFIndex;
pub extern "c" fn CTRunGetGlyphs(run: CTRunRef, range: CFRange, glyphs: [*]u16) void;
pub extern "c" fn CTRunGetPositions(run: CTRunRef, range: CFRange, positions: [*]CGPoint) void;
extern "c" fn CTRunGetStringIndices(run: CTRunRef, range: CFRange, indices: [*]CFIndex) void;
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
    width: f64,
    ascent: f64,
    descent: f64,
    leading: f64,
    glyph_count: usize,
    ascii: bool,
    printable_ascii: bool,
    uniform_advance: ?f32 = null,
    geometry: ?GlyphGeometry = null,
    previous: ?*Layout = null,
    next: ?*Layout = null,

    pub fn uniformAdvance(entry: *Layout) f32 {
        if (entry.uniform_advance) |advance| return advance;
        const advance = entry.checkUniformAdvance();
        entry.uniform_advance = advance;
        return advance;
    }

    fn checkUniformAdvance(entry: *const Layout) f32 {
        if (!entry.mono or !entry.printable_ascii or entry.text.len == 0 or entry.glyph_count != entry.text.len) return 0;
        const runs = CTLineGetGlyphRuns(entry.line);
        if (CFArrayGetCount(runs) != 1) return 0;
        const run = CFArrayGetValueAtIndex(runs, 0);
        const advance: f32 = @floatCast(entry.width / @as(f64, @floatFromInt(entry.glyph_count)));
        if (advance <= 0) return 0;
        var positions: [256]CGPoint = undefined;
        var indices: [256]CFIndex = undefined;
        var start: usize = 0;
        while (start < entry.glyph_count) {
            const count = @min(positions.len, entry.glyph_count - start);
            const range: CFRange = .{ .location = @intCast(start), .length = @intCast(count) };
            CTRunGetPositions(run, range, &positions);
            CTRunGetStringIndices(run, range, &indices);
            for (positions[0..count], indices[0..count], start..) |position, character, column| {
                const expected = @as(f32, @floatFromInt(column)) * advance;
                if (character != column or @abs(position.x - expected) > 0.01 or position.y != 0) return 0;
            }
            start += count;
        }
        const end = CTLineGetOffsetForStringIndex(entry.line, @intCast(entry.text.len), null);
        if (@abs(end - entry.width) > 0.01) return 0;
        return advance;
    }

    pub fn caret(entry: *Layout, at: usize) f32 {
        const offset = @min(at, entry.text.len);
        const advance = entry.uniformAdvance();
        if (advance > 0) return @as(f32, @floatFromInt(offset)) * advance;
        return @floatCast(CTLineGetOffsetForStringIndex(entry.line, @intCast(if (entry.ascii) offset else byteToUtf16(entry.text, offset)), null));
    }

    pub fn glyphGeometry(entry: *Layout, allocator: std.mem.Allocator) !GlyphGeometry {
        if (entry.geometry) |cached| return cached;
        const native_runs = CTLineGetGlyphRuns(entry.line);
        const run_count: usize = @intCast(CFArrayGetCount(native_runs));
        const runs = try allocator.alloc(GlyphRun, run_count);
        errdefer allocator.free(runs);
        const glyphs = try allocator.alloc(ShapedGlyph, entry.glyph_count);
        errdefer allocator.free(glyphs);
        var offset: usize = 0;
        var run_index: usize = 0;
        var ids: [256]u16 = undefined;
        var positions: [256]CGPoint = undefined;
        for (0..run_count) |index| {
            const run = CFArrayGetValueAtIndex(native_runs, @intCast(index));
            const count: usize = @intCast(CTRunGetGlyphCount(run));
            if (count == 0) continue;
            const font = CFDictionaryGetValue(CTRunGetAttributes(run), kCTFontAttributeName) orelse return error.NativeFontUnavailable;
            const run_glyphs = glyphs[offset..][0..count];
            var start: usize = 0;
            while (start < count) {
                const length = @min(ids.len, count - start);
                const range: CFRange = .{ .location = @intCast(start), .length = @intCast(length) };
                CTRunGetGlyphs(run, range, &ids);
                CTRunGetPositions(run, range, &positions);
                for (run_glyphs[start..][0..length], ids[0..length], positions[0..length]) |*glyph, id, position| {
                    glyph.* = .{ .id = id, .x = @floatCast(position.x), .y = @floatCast(position.y) };
                }
                start += length;
            }
            runs[run_index] = .{ .font = font, .font_hash = CFHash(font), .start = offset, .count = count };
            run_index += 1;
            offset += count;
        }
        std.debug.assert(offset == glyphs.len);
        entry.geometry = .{ .runs = runs, .run_count = run_index, .glyphs = glyphs };
        return entry.geometry.?;
    }
};

const ShapedGlyph = struct { id: u16, x: f32, y: f32 };
const GlyphRun = struct { font: CTFontRef, font_hash: usize, start: usize, count: usize };
const GlyphGeometry = struct { runs: []GlyphRun, run_count: usize, glyphs: []ShapedGlyph };

pub const max_layouts = 4096;
pub const layout_budget = 16 * 1024 * 1024;
const Font = struct { value: CTFontRef, size: f32, mono: bool };
const CacheKey = struct { bytes: []const u8, hash: u64, size: f32, mono: bool };
const CacheContext = struct {
    pub fn hash(_: @This(), key: CacheKey) u64 {
        return key.hash ^ (@as(u64, @as(u32, @bitCast(key.size))) << 1) ^ @as(u64, @intFromBool(key.mono));
    }
    pub fn eql(_: @This(), a: CacheKey, b: CacheKey) bool {
        return a.hash == b.hash and a.size == b.size and a.mono == b.mono and std.mem.eql(u8, a.bytes, b.bytes);
    }
};

pub const TextSystem = struct {
    allocator: std.mem.Allocator,
    typography: typography_module.Typography = .{},
    newest_layout: ?*Layout = null,
    oldest_layout: ?*Layout = null,
    layout_count: usize = 0,
    fonts: [64]?Font = @splat(null),
    font_count: usize = 0,
    next_font: usize = 0,
    bundled_faces: [2]?CFRef = .{ null, null },
    /// An oversized line can be shaped without displacing the entire cache.
    /// It is released on the next layout request and is not cached memory.
    temporary: ?*Layout = null,
    layout_bytes: usize = 0,
    shape_hits: u64 = 0,
    shape_misses: u64 = 0,
    lookup: std.HashMapUnmanaged(CacheKey, *Layout, CacheContext, std.hash_map.default_max_load_percentage) = .empty,

    pub fn init(allocator: std.mem.Allocator) TextSystem {
        return .{ .allocator = allocator };
    }

    pub fn deinit(system: *TextSystem) void {
        system.lookup.deinit(system.allocator);
        while (system.oldest_layout) |line| {
            system.unlinkLayout(line);
            system.destroyLayout(line);
        }
        if (system.temporary) |line| system.destroyLayout(line);
        for (system.fonts) |entry| if (entry) |face| CFRelease(face.value);
        for (system.bundled_faces) |face| if (face) |value| CGFontRelease(value);
        system.* = .{ .allocator = system.allocator };
    }
    pub fn setTypography(system: *TextSystem, value: typography_module.Typography) void {
        if (std.meta.eql(system.typography, value)) return;
        system.deinit();
        system.typography = value;
    }

    /// The font is borrowed. Retain it when keeping it beyond a shaping call,
    /// for example as a renderer's glyph-cache key.
    pub fn font(system: *TextSystem, requested_size: f32, mono: bool) !CTFontRef {
        const size = normalizedSize(requested_size * if (mono) @as(f32, 1) else system.typography.ui_size / 13);
        for (system.fonts[0..system.font_count]) |entry| {
            const face = entry.?;
            if (face.size == size and face.mono == mono) return face.value;
        }
        const family = if (mono) system.typography.code_family else system.typography.ui_family;
        var value = if (family.len > 0) try namedFont(family.slice(), size) else if (mono) switch (system.typography.code_font) {
            .lilex => try bundledFont(system, 0, @embedFile("fonts/Lilex-Regular.ttf"), size),
            .menlo => try namedFont("Menlo-Regular", size),
            .monaco => try namedFont("Monaco", size),
        } else switch (system.typography.ui_font) {
            .plex => try bundledFont(system, 1, @embedFile("fonts/IBMPlexSans-Regular.ttf"), size),
            .system => CTFontCreateUIFontForLanguage(2, size, null) orelse try namedFont("Helvetica", size),
        };
        errdefer CFRelease(value);
        if (mono) {
            const configured = try featureFont(value, size, system.typography.ligatures);
            CFRelease(value);
            value = configured;
        }
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
        const size = normalizedSize(requested_size);
        const hash = std.hash.Wyhash.hash(0, bytes);
        const key: CacheKey = .{ .bytes = bytes, .hash = hash, .size = size, .mono = mono };
        if (system.lookup.get(key)) |entry| {
            system.shape_hits +%= 1;
            if (system.newest_layout != entry) {
                system.unlinkLayout(entry);
                system.linkLayout(entry);
            }
            return entry;
        }
        if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
        system.shape_misses +%= 1;
        const face = try system.font(size, mono);
        const string = try createString(bytes);
        errdefer CFRelease(string);
        const attributed = CFAttributedStringCreateMutable(null, 0) orelse return error.OutOfMemory;
        defer CFRelease(attributed);
        CFAttributedStringReplaceString(attributed, .{ .location = 0, .length = 0 }, string);
        const whole: CFRange = .{ .location = 0, .length = CFStringGetLength(string) };
        CFAttributedStringSetAttribute(attributed, whole, kCTFontAttributeName, face);
        const enabled: i32 = if (mono and system.typography.ligatures) 1 else 0;
        const ligature = CFNumberCreate(null, 3, &enabled) orelse return error.OutOfMemory;
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
        const run_count: usize = @intCast(CFArrayGetCount(CTLineGetGlyphRuns(line)));
        const cost = bytes.len *| 4 +| glyphs *| (64 + @sizeOf(ShapedGlyph)) +| run_count *| @sizeOf(GlyphRun) +| @sizeOf(Layout) +| 256;
        var ascent: f64 = 0;
        var descent: f64 = 0;
        var leading: f64 = 0;
        const advance = CTLineGetTypographicBounds(line, &ascent, &descent, &leading);
        var ascii = true;
        var printable_ascii = true;
        for (bytes) |byte| {
            ascii = ascii and byte < 0x80;
            printable_ascii = printable_ascii and std.ascii.isPrint(byte);
            if (!ascii) break;
        }
        entry.* = .{
            .line = line,
            .string = string,
            .text = owned_bytes,
            .cost = cost,
            .hash = hash,
            .size = size,
            .mono = mono,
            .glyph_count = glyphs,
            .ascii = ascii,
            .printable_ascii = printable_ascii,
            .width = advance,
            .ascent = ascent,
            .descent = descent,
            .leading = leading,
        };
        if (cost > layout_budget) {
            system.temporary = entry;
            return entry;
        }
        // Reserve before evicting: allocation failure preserves existing hits.
        system.lookup.ensureUnusedCapacity(system.allocator, 1) catch |err| {
            system.allocator.destroy(entry);
            return err;
        };
        while (system.layout_count > 0 and (system.layout_count == max_layouts or system.layout_bytes + cost > layout_budget)) {
            const old = system.oldest_layout.?;
            _ = system.lookup.remove(.{ .bytes = old.text, .hash = old.hash, .size = old.size, .mono = old.mono });
            system.unlinkLayout(old);
            system.layout_count -= 1;
            system.layout_bytes -= old.cost;
            system.destroyLayout(old);
        }
        system.linkLayout(entry);
        system.layout_count += 1;
        system.layout_bytes += cost;
        system.lookup.putAssumeCapacity(.{ .bytes = owned_bytes, .hash = hash, .size = size, .mono = mono }, entry);
        return entry;
    }

    pub fn width(system: *TextSystem, bytes: []const u8, size: f32, mono: bool) f32 {
        if (bytes.len == 0) return 0;
        const shaped = system.layout(bytes, size, mono) catch return 0;
        return @floatCast(shaped.width);
    }

    pub fn caret(system: *TextSystem, bytes: []const u8, size: f32, mono: bool, at: usize) f32 {
        if (bytes.len == 0) return 0;
        const shaped = system.layout(bytes, size, mono) catch return 0;
        return shaped.caret(at);
    }

    pub fn index(system: *TextSystem, bytes: []const u8, size: f32, mono: bool, x: f32) usize {
        if (bytes.len == 0 or x <= 0 or std.math.isNan(x)) return 0;
        if (std.math.isInf(x)) return bytes.len;
        const shaped = system.layout(bytes, size, mono) catch return 0;
        const advance = shaped.uniformAdvance();
        if (advance > 0) {
            const end = @as(f32, @floatFromInt(bytes.len));
            const column = x / advance;
            if (column >= end) return bytes.len;
            const nearest = @round(column);
            // Preserve Core Text's tie-breaking near the middle of a glyph.
            if (@abs(@abs(column - nearest) - 0.5) * advance > 0.02) return @intFromFloat(nearest);
        }
        const at = CTLineGetStringIndexForPosition(shaped.line, .{ .x = x, .y = 0 });
        if (at < 0) return bytes.len;
        return if (shaped.ascii) @min(bytes.len, @as(usize, @intCast(at))) else utf16ToByte(bytes, @intCast(at));
    }

    pub fn fitsSingleRow(system: *TextSystem, bytes: []const u8, size: f32, mono: bool, available: f32) bool {
        const shaped = system.layout(bytes, size, mono) catch return false;
        // Only use the shortcut for verified uniform left-to-right positions.
        const advance = shaped.uniformAdvance();
        if (advance <= 0) return false;
        return @as(f32, @floatFromInt(bytes.len)) * advance <= available;
    }

    fn unlinkLayout(system: *TextSystem, entry: *Layout) void {
        if (entry.previous) |previous| previous.next = entry.next else system.oldest_layout = entry.next;
        if (entry.next) |next| next.previous = entry.previous else system.newest_layout = entry.previous;
    }

    fn linkLayout(system: *TextSystem, entry: *Layout) void {
        entry.previous = system.newest_layout;
        entry.next = null;
        if (system.newest_layout) |newest| newest.next = entry else system.oldest_layout = entry;
        system.newest_layout = entry;
    }

    fn destroyLayout(system: *TextSystem, entry: *Layout) void {
        if (entry.geometry) |geometry| {
            system.allocator.free(geometry.runs);
            system.allocator.free(geometry.glyphs);
        }
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
fn bundledFont(system: *TextSystem, slot: usize, bytes: []const u8, size: f32) !CTFontRef {
    if (system.bundled_faces[slot] == null) {
        // Embedded bytes have process lifetime. One face per family shares them
        // across point sizes instead of copying the font file for every size.
        const data = CFDataCreateWithBytesNoCopy(null, bytes.ptr, @intCast(bytes.len), kCFAllocatorNull) orelse return error.OutOfMemory;
        defer CFRelease(data);
        const provider = CGDataProviderCreateWithCFData(data) orelse return error.NativeFontUnavailable;
        defer CGDataProviderRelease(provider);
        system.bundled_faces[slot] = CGFontCreateWithDataProvider(provider) orelse return error.NativeFontUnavailable;
    }
    return CTFontCreateWithGraphicsFont(system.bundled_faces[slot].?, size, null, null) orelse error.NativeFontUnavailable;
}
fn featureFont(font_value: CTFontRef, size: f32, enabled: bool) !CTFontRef {
    // Programming ligatures in Lilex use contextual alternates, not `liga`.
    // Set both features explicitly so the UI's off state actually disables them.
    const value: i32 = @intFromBool(enabled);
    const number = CFNumberCreate(null, 3, &value) orelse return error.OutOfMemory;
    defer CFRelease(number);
    var features: [2]CFRef = undefined;
    var made: usize = 0;
    defer for (features[0..made]) |feature| CFRelease(feature);
    for ([_][]const u8{ "calt", "liga" }, 0..) |tag, index| {
        const name = try createString(tag);
        defer CFRelease(name);
        features[index] = CFDictionaryCreate(null, &.{ kCTFontOpenTypeFeatureTag, kCTFontOpenTypeFeatureValue }, &.{ name, number }, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks) orelse return error.OutOfMemory;
        made += 1;
    }
    const array = CFArrayCreate(null, &features, 2, &kCFTypeArrayCallBacks) orelse return error.OutOfMemory;
    defer CFRelease(array);
    const attributes = CFDictionaryCreate(null, &.{kCTFontFeatureSettingsAttribute}, &.{array}, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks) orelse return error.OutOfMemory;
    defer CFRelease(attributes);
    const descriptor = CTFontDescriptorCreateWithAttributes(attributes) orelse return error.NativeFontUnavailable;
    defer CFRelease(descriptor);
    return CTFontCreateCopyWithAttributes(font_value, size, null, descriptor) orelse error.NativeFontUnavailable;
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

extern "c" fn CTFontManagerCopyAvailableFontFamilyNames() ?CFRef;
extern "c" fn CFStringGetCString(CFStringRef, [*]u8, CFIndex, u32) u8;
pub fn fontFamilies(a: std.mem.Allocator) ![]typography_module.FontName {
    const Name = typography_module.FontName;
    const array = CTFontManagerCopyAvailableFontFamilyNames() orelse return error.NativeFontUnavailable;
    defer CFRelease(array);
    var result: std.ArrayList(Name) = .empty;
    errdefer result.deinit(a);
    const count = CFArrayGetCount(array);
    var i: CFIndex = 0;
    while (i < count) : (i += 1) {
        var bytes: [256]u8 = @splat(0);
        if (CFStringGetCString(CFArrayGetValueAtIndex(array, i), &bytes, bytes.len, 0x08000100) == 0) continue;
        const value = std.mem.sliceTo(&bytes, 0);
        if (value.len == 0 or value[0] == '.') continue;
        try result.append(a, try Name.init(value));
    }
    std.mem.sort(Name, result.items, {}, struct {
        fn less(_: void, lhs: Name, rhs: Name) bool {
            return std.ascii.orderIgnoreCase(lhs.slice(), rhs.slice()) == .lt;
        }
    }.less);
    return result.toOwnedSlice(a);
}
