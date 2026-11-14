//! Native Metal rendering through direct Zig bindings. The renderer owns its
//! glyph atlas, shaped text cache and three leased instance buffers. Applications
//! submit platform-neutral scenes and never handle Objective-C or GPU objects.
const std = @import("std");
const geometry = @import("../../layout/geometry.zig");
const objc = @import("../../platform/macos/objc.zig");
const text_mod = @import("../../text/shaping.zig");
const text_typography = @import("../../text/typography.zig");
const images_module = @import("../images.zig");
const scene = @import("../scene.zig");
const Allocator = std.mem.Allocator;
const Id = objc.Id;
const CFRef = text_mod.CFRef;
const Rect = geometry.Rect;
const Color = geometry.Color;
const Size = geometry.Size;
const atlas_side = 2048;
const max_instances = 262144;

extern "c" fn MTLCreateSystemDefaultDevice() Id;
extern "c" fn CFHash(CFRef) usize;
extern "c" fn CFEqual(CFRef, CFRef) u8;
extern "c" fn CTFontCreateCopyWithAttributes(CFRef, f64, ?*const anyopaque, ?CFRef) ?CFRef;
extern "c" fn CTFontGetBoundingRectsForGlyphs(CFRef, u32, [*]const u16, ?[*]objc.CGRect, isize) objc.CGRect;
extern "c" fn CTFontDrawGlyphs(CFRef, [*]const u16, [*]const objc.CGPoint, usize, *anyopaque) void;
extern "c" fn CGBitmapContextCreate(?*anyopaque, usize, usize, usize, usize, ?CFRef, u32) ?*anyopaque;
extern "c" fn CGContextRelease(*anyopaque) void;
extern "c" fn CGContextSetGrayFillColor(*anyopaque, f64, f64) void;
extern "c" fn CGContextSetShouldAntialias(*anyopaque, bool) void;
extern "c" fn CGContextSetShouldSmoothFonts(*anyopaque, bool) void;
extern "c" fn CGContextSetAllowsFontSubpixelPositioning(*anyopaque, bool) void;
extern "c" fn CGContextSetShouldSubpixelPositionFonts(*anyopaque, bool) void;
extern "c" fn CGContextSetAllowsFontSubpixelQuantization(*anyopaque, bool) void;
extern "c" fn CGContextSetShouldSubpixelQuantizeFonts(*anyopaque, bool) void;
extern "c" fn CGContextTranslateCTM(*anyopaque, f64, f64) void;

const Origin = extern struct { x: usize = 0, y: usize = 0, z: usize = 0 };
const TextureSize = extern struct { width: usize, height: usize, depth: usize = 1 };
const Region = extern struct { origin: Origin = .{}, size: TextureSize };
const ClearColor = extern struct { red: f64, green: f64, blue: f64, alpha: f64 };
const Instance = extern struct {
    rect: [4]f32,
    clip: [4]f32,
    color: [4]f32,
    uv: [4]f32,
    radius: f32,
    mode: f32,
    transform_scale: [2]f32 = .{ 1, 1 },
    transform_translate: [2]f32 = .{ 0, 0 },
    rotation: f32 = 0,
    padding: f32 = 0,
    gradient_color: [4]f32 = .{ 0, 0, 0, 0 },
    gradient_start: [2]f32 = .{ 0, 0 },
    gradient_end: [2]f32 = .{ 1, 0 },
};
comptime {
    std.debug.assert(@sizeOf(Instance) == 128);
}

const GlyphKey = struct { font: CFRef, scale: u32, glyph: u16, phase_x: u8, phase_y: u8 };
const Glyph = struct { bounds: Rect, uv: Rect };
const GlyphContext = struct {
    pub fn hash(_: GlyphContext, key: GlyphKey) u64 {
        const parts = [4]u64{ CFHash(key.font), key.scale, key.glyph, @as(u64, key.phase_x) * 4 + key.phase_y };
        return std.hash.Wyhash.hash(0, std.mem.asBytes(&parts));
    }
    pub fn eql(_: GlyphContext, a: GlyphKey, b: GlyphKey) bool {
        return a.scale == b.scale and a.glyph == b.glyph and a.phase_x == b.phase_x and a.phase_y == b.phase_y and CFEqual(a.font, b.font) != 0;
    }
};
const BufferSlot = struct { buffer: Id = null, command: Id = null, capacity: usize = 0 };
const ImageTexture = struct { texture: Id, width: u32, height: u32, bytes: usize, touched: u64 };
const Batch = struct { start: usize, count: usize, texture: Id };
const image_cache_limit = 64 * 1024 * 1024;
const image_cache_entries = 64;

pub const Stats = struct {
    frames: u64 = 0,
    glyphs: u64 = 0,
    shape_hits: u64 = 0,
    shape_misses: u64 = 0,
    cpu_ns: u64 = 0,
    gpu_ns: u64 = 0,
    atlas_bytes: usize = 0,
    layout_bytes: usize = 0,
    instance_bytes: usize = 0,
    image_bytes: usize = 0,
    image_textures: usize = 0,
    image_uploads: u64 = 0,
    image_hits: u64 = 0,
};

pub const Renderer = struct {
    allocator: Allocator,
    text: text_mod.TextSystem,
    device: Id,
    queue: Id,
    pipeline: Id,
    atlas: Id = null,
    atlas_x: usize = 1,
    atlas_y: usize = 1,
    atlas_row: usize = 0,
    glyphs: std.HashMapUnmanaged(GlyphKey, Glyph, GlyphContext, std.hash_map.default_max_load_percentage) = .empty,
    instances: std.ArrayList(Instance) = .empty,
    batches: std.ArrayList(Batch) = .empty,
    images: std.AutoHashMapUnmanaged(u64, ImageTexture) = .empty,
    image_bytes: usize = 0,
    image_clock: u64 = 0,
    buffers: [3]BufferSlot = @splat(.{}),
    next_slot: usize = 0,
    counters: Stats = .{},

    fn clearBatches(r: *Renderer) void {
        for (r.batches.items) |batch| objc.release(batch.texture);
        r.batches.clearRetainingCapacity();
    }
    fn addBatch(r: *Renderer, start: usize, texture: Id) !void {
        const count = r.instances.items.len - start;
        if (count == 0) return;
        if (r.batches.items.len > 0) {
            const previous = &r.batches.items[r.batches.items.len - 1];
            if (previous.texture == texture and previous.start + previous.count == start) {
                previous.count += count;
                return;
            }
        }
        try r.batches.ensureUnusedCapacity(r.allocator, 1);
        r.batches.appendAssumeCapacity(.{ .start = start, .count = count, .texture = objc.retain(texture) });
    }
    fn imageTexture(r: *Renderer, view: images_module.View) !Id {
        r.image_clock +%= 1;
        if (r.images.getPtr(view.id)) |cached| {
            if (cached.width != view.width or cached.height != view.height) return error.InvalidScene;
            cached.touched = r.image_clock;
            r.counters.image_hits +%= 1;
            return cached.texture;
        }
        while (r.images.count() >= image_cache_entries or r.image_bytes + view.pixels.len > image_cache_limit) {
            var oldest: ?u64 = null;
            var touched: u64 = std.math.maxInt(u64);
            var iterator = r.images.iterator();
            while (iterator.next()) |entry| if (oldest == null or entry.value_ptr.touched < touched) {
                oldest = entry.key_ptr.*;
                touched = entry.value_ptr.touched;
            };
            const removed = r.images.fetchRemove(oldest orelse return error.ImageTooLarge).?.value;
            r.image_bytes -= removed.bytes;
            // Batches retain their own references until encoding. Submitted
            // Metal commands retain resources until GPU completion as well.
            objc.release(removed.texture);
        }
        const texture = objc.send(Id, r.device, "newTextureWithDescriptor:", .{textureDescriptor(70, view.width, view.height, 1)}) orelse return error.MetalAllocationFailed;
        errdefer objc.release(texture);
        objc.send(void, texture, "replaceRegion:mipmapLevel:withBytes:bytesPerRow:", .{ Region{ .size = .{ .width = view.width, .height = view.height } }, @as(usize, 0), @as(*const anyopaque, view.pixels.ptr), @as(usize, view.width) * 4 });
        try r.images.put(r.allocator, view.id, .{ .texture = texture, .width = view.width, .height = view.height, .bytes = view.pixels.len, .touched = r.image_clock });
        r.image_bytes += view.pixels.len;
        r.counters.image_uploads +%= 1;
        return texture;
    }

    fn clearGlyphs(r: *Renderer) void {
        var keys = r.glyphs.keyIterator();
        while (keys.next()) |key| text_mod.CFRelease(key.font);
        r.glyphs.clearRetainingCapacity();
    }

    fn resetAtlas(r: *Renderer) !void {
        const descriptor = textureDescriptor(10, atlas_side, atlas_side, 1);
        const fresh = objc.send(Id, r.device, "newTextureWithDescriptor:", .{descriptor}) orelse return error.MetalAllocationFailed;
        errdefer objc.release(fresh);
        const zero = try r.allocator.alloc(u8, atlas_side * atlas_side);
        defer r.allocator.free(zero);
        @memset(zero, 0);
        objc.send(void, fresh, "replaceRegion:mipmapLevel:withBytes:bytesPerRow:", .{
            Region{ .size = .{ .width = atlas_side, .height = atlas_side } },
            @as(usize, 0),
            @as(*const anyopaque, zero.ptr),
            @as(usize, atlas_side),
        });
        // Metal command buffers retain referenced textures. Old generations
        // therefore survive until every in-flight command using them completes.
        objc.release(r.atlas);
        r.atlas = fresh;
        r.clearGlyphs();
        r.atlas_x = 1;
        r.atlas_y = 1;
        r.atlas_row = 0;
    }

    fn glyph(r: *Renderer, font: CFRef, glyph_id: u16, scale: f32, phase_x: u8, phase_y: u8) !Glyph {
        const key: GlyphKey = .{ .font = font, .scale = @bitCast(scale), .glyph = glyph_id, .phase_x = phase_x, .phase_y = phase_y };
        if (r.glyphs.get(key)) |cached| return cached;
        const pixel_font = CTFontCreateCopyWithAttributes(font, text_mod.CTFontGetSize(font) * scale, null, null) orelse return error.NativeFontUnavailable;
        defer text_mod.CFRelease(pixel_font);
        const native_bounds = CTFontGetBoundingRectsForGlyphs(pixel_font, 0, @ptrCast(&glyph_id), null, 1);
        const min_x: f32 = @floatCast(@floor(native_bounds.origin.x));
        const min_y: f32 = @floatCast(@floor(native_bounds.origin.y));
        const width_f: f32 = @floatCast(@ceil(native_bounds.origin.x + native_bounds.size.width - min_x) + 3);
        const height_f: f32 = @floatCast(@ceil(native_bounds.origin.y + native_bounds.size.height - min_y) + 3);
        if (!std.math.isFinite(width_f) or !std.math.isFinite(height_f) or width_f < 0 or height_f < 0 or width_f > atlas_side - 2 or height_f > atlas_side - 2) return error.GlyphTooLarge;
        const width: usize = @intFromFloat(width_f);
        const height: usize = @intFromFloat(height_f);
        if (r.atlas_x + width + 1 > atlas_side) {
            r.atlas_x = 1;
            r.atlas_y += r.atlas_row + 1;
            r.atlas_row = 0;
        }
        if (r.atlas_y + height + 1 > atlas_side or r.glyphs.count() >= 32768) return error.AtlasFull;
        const pixels = try r.allocator.alloc(u8, width * height);
        defer r.allocator.free(pixels);
        @memset(pixels, 0);
        const context = CGBitmapContextCreate(pixels.ptr, width, height, 8, width, null, 7) orelse return error.GlyphRasterizationFailed;
        defer CGContextRelease(context);
        CGContextSetGrayFillColor(context, 1, 1);
        CGContextSetShouldAntialias(context, true);
        CGContextSetShouldSmoothFonts(context, false);
        CGContextSetAllowsFontSubpixelPositioning(context, true);
        CGContextSetShouldSubpixelPositionFonts(context, true);
        CGContextSetAllowsFontSubpixelQuantization(context, false);
        CGContextSetShouldSubpixelQuantizeFonts(context, false);
        CGContextTranslateCTM(context, 1 - min_x, 1 - min_y);
        const zero: objc.CGPoint = .{ .x = @as(f64, @floatFromInt(phase_x)) / 4, .y = -@as(f64, @floatFromInt(phase_y)) / 4 };
        CTFontDrawGlyphs(pixel_font, @ptrCast(&glyph_id), @ptrCast(&zero), 1, context);
        objc.send(void, r.atlas, "replaceRegion:mipmapLevel:withBytes:bytesPerRow:", .{
            Region{ .origin = .{ .x = r.atlas_x, .y = r.atlas_y }, .size = .{ .width = width, .height = height } },
            @as(usize, 0),
            @as(*const anyopaque, pixels.ptr),
            width,
        });
        const result: Glyph = .{
            .bounds = .{ .x = (min_x - 1) / scale, .y = (min_y - 1) / scale, .width = width_f / scale, .height = height_f / scale },
            .uv = .{ .x = @as(f32, @floatFromInt(r.atlas_x)) / atlas_side, .y = @as(f32, @floatFromInt(r.atlas_y)) / atlas_side, .width = width_f / atlas_side, .height = height_f / atlas_side },
        };
        _ = text_mod.CFRetain(font);
        errdefer text_mod.CFRelease(font);
        try r.glyphs.put(r.allocator, key, result);
        r.atlas_x += width + 1;
        r.atlas_row = @max(r.atlas_row, height);
        return result;
    }

    fn append(r: *Renderer, rect: Rect, clip: Rect, color: Color, uv: Rect, radius: f32, mode: f32, transform: scene.Transform, gradient: ?scene.Gradient) !void {
        if (rect.intersection(clip).width <= 0 or rect.intersection(clip).height <= 0) return;
        if (r.instances.items.len >= max_instances) return error.SceneTooLarge;
        try r.instances.append(r.allocator, .{
            .rect = .{ rect.x, rect.y, rect.width, rect.height },
            .clip = .{ clip.x, clip.y, clip.width, clip.height },
            .color = .{ color.r, color.g, color.b, color.a },
            .uv = .{ uv.x, uv.y, uv.width, uv.height },
            .radius = radius,
            .mode = mode,
            .transform_scale = .{ transform.scale_x, transform.scale_y },
            .transform_translate = .{ transform.translate_x, transform.translate_y },
            .rotation = transform.rotation,
            .padding = transform.opacity,
            .gradient_color = if (gradient) |value| .{ value.end_color.r, value.end_color.g, value.end_color.b, value.end_color.a } else .{ 0, 0, 0, 0 },
            .gradient_start = if (gradient) |value| .{ value.start.x, value.start.y } else .{ 0, 0 },
            .gradient_end = if (gradient) |value| .{ value.end.x, value.end.y } else .{ 1, 0 },
        });
    }

    fn build(r: *Renderer, frame: scene.Frame, scale: f32) !void {
        r.clearBatches();
        errdefer r.clearBatches();
        r.instances.clearRetainingCapacity();
        for (frame.items) |item| {
            const start = r.instances.items.len;
            const texture = if (item.kind == .image) try r.imageTexture(item.image.?) else r.atlas;
            switch (item.kind) {
                .line => {
                    const segment = item.segment orelse return error.InvalidScene;
                    try r.append(item.rect, item.clip, item.color, .{ .x = segment.start.x, .y = segment.start.y, .width = segment.end.x, .height = segment.end.y }, segment.width / 2, 3, item.transform, null);
                },
                .rect => try r.append(item.rect, item.clip, item.color, .{}, item.radius, 0, item.transform, null),
                .image => try r.append(item.rect, item.clip, item.color, item.uv, 0, 2, item.transform, null),
                .gradient => try r.append(item.rect, item.clip, item.color, .{}, item.radius, 4, item.transform, item.gradient),
                .text => {
                    if (item.text.len == 0) continue;
                    const layout = try r.text.layout(item.text, item.font_size, item.mono);
                    var ascent: f64 = 0;
                    var descent: f64 = 0;
                    _ = text_mod.CTLineGetTypographicBounds(layout.line, &ascent, &descent, null);
                    const baseline: f32 = item.rect.y + @max(0, (item.rect.height - @as(f32, @floatCast(ascent + descent))) * 0.5) + @as(f32, @floatCast(ascent));
                    const runs = text_mod.CTLineGetGlyphRuns(layout.line);
                    var run_index: isize = 0;
                    while (run_index < text_mod.CFArrayGetCount(runs)) : (run_index += 1) {
                        const run = text_mod.CFArrayGetValueAtIndex(runs, run_index);
                        const font = text_mod.CFDictionaryGetValue(text_mod.CTRunGetAttributes(run), text_mod.kCTFontAttributeName) orelse return error.NativeFontUnavailable;
                        const count = text_mod.CTRunGetGlyphCount(run);
                        var glyph_index: isize = 0;
                        while (glyph_index < count) : (glyph_index += 1) {
                            var glyph_id: u16 = 0;
                            var position: text_mod.CGPoint = undefined;
                            const range: text_mod.CFRange = .{ .location = glyph_index, .length = 1 };
                            text_mod.CTRunGetGlyphs(run, range, @ptrCast(&glyph_id));
                            text_mod.CTRunGetPositions(run, range, @ptrCast(&position));
                            const at = item.rect.x + @as(f32, @floatCast(position.x));
                            if (at > item.clip.x + item.clip.width + item.font_size * 2 or at < item.clip.x - item.font_size * 3) continue;
                            // Rasterize fractional origins into distinct masks, then place
                            // those masks on device pixels instead of blurring them again.
                            const pixel_x = @round(at * scale * 4) / 4;
                            const pixel_y = @round((baseline - @as(f32, @floatCast(position.y))) * scale * 4) / 4;
                            const base_x = @floor(pixel_x);
                            const base_y = @floor(pixel_y);
                            const cached = try r.glyph(font, glyph_id, scale, @intFromFloat((pixel_x - base_x) * 4), @intFromFloat((pixel_y - base_y) * 4));
                            const b = cached.bounds;
                            try r.append(.{ .x = base_x / scale + b.x, .y = base_y / scale - b.y - b.height, .width = b.width, .height = b.height }, item.clip, item.color, cached.uv, 0, 1, item.transform, null);
                        }
                    }
                },
            }
            try r.addBatch(start, texture);
        }
    }
};

pub fn create(allocator: Allocator) !*Renderer {
    return createRenderer(allocator);
}
pub fn destroy(r: *Renderer) void {
    destroyRenderer(r);
}
pub fn draw(r: *Renderer, frame: scene.Frame, size: Size, scale: f32, texture: Id, drawable: Id, synchronous: bool) !void {
    try drawFrame(r, frame, size, scale, texture, drawable, synchronous);
}
pub fn snapshot(r: *Renderer, frame: scene.Frame, size: Size, path: []const u8) !void {
    try snapshotFrame(r, frame, size, path);
}
pub fn stats(r: *Renderer) Stats {
    return rendererStats(r);
}
pub fn setTypography(r: *Renderer, value: text_typography.Typography) void {
    if (std.meta.eql(r.text.typography, value)) return;
    r.clearGlyphs();
    r.text.setTypography(value);
}

fn createRenderer(allocator: Allocator) !*Renderer {
    const pool = objc.Pool.init();
    defer pool.deinit();
    const device = MTLCreateSystemDefaultDevice() orelse return error.MetalUnavailable;
    errdefer objc.release(device);
    const queue = objc.send(Id, device, "newCommandQueue", .{}) orelse return error.MetalUnavailable;
    errdefer objc.release(queue);
    var native_error: Id = null;
    const library = objc.send(Id, device, "newLibraryWithSource:options:error:", .{ objc.string(@embedFile("metal.metal")), @as(Id, null), &native_error }) orelse {
        reportNativeError(native_error);
        return error.MetalShaderCompilationFailed;
    };
    defer objc.release(library);
    const vertex = objc.send(Id, library, "newFunctionWithName:", .{objc.string("vertex_main")}) orelse return error.MetalShaderUnavailable;
    defer objc.release(vertex);
    const fragment = objc.send(Id, library, "newFunctionWithName:", .{objc.string("fragment_main")}) orelse return error.MetalShaderUnavailable;
    defer objc.release(fragment);
    const descriptor = objc.send(Id, objc.class("MTLRenderPipelineDescriptor"), "new", .{}) orelse return error.MetalAllocationFailed;
    defer objc.release(descriptor);
    objc.send(void, descriptor, "setVertexFunction:", .{vertex});
    objc.send(void, descriptor, "setFragmentFunction:", .{fragment});
    const attachments = objc.send(Id, descriptor, "colorAttachments", .{});
    const attachment = objc.send(Id, attachments, "objectAtIndexedSubscript:", .{@as(usize, 0)});
    objc.send(void, attachment, "setPixelFormat:", .{@as(usize, 80)});
    objc.send(void, attachment, "setBlendingEnabled:", .{true});
    objc.send(void, attachment, "setSourceRGBBlendFactor:", .{@as(usize, 1)});
    objc.send(void, attachment, "setDestinationRGBBlendFactor:", .{@as(usize, 5)});
    objc.send(void, attachment, "setSourceAlphaBlendFactor:", .{@as(usize, 1)});
    objc.send(void, attachment, "setDestinationAlphaBlendFactor:", .{@as(usize, 5)});
    const pipeline = objc.send(Id, device, "newRenderPipelineStateWithDescriptor:error:", .{ descriptor, &native_error }) orelse {
        reportNativeError(native_error);
        return error.MetalPipelineUnavailable;
    };
    errdefer objc.release(pipeline);
    const r = try allocator.create(Renderer);
    errdefer allocator.destroy(r);
    r.* = .{ .allocator = allocator, .text = .init(allocator), .device = device, .queue = queue, .pipeline = pipeline };
    try r.resetAtlas();
    return r;
}

fn destroyRenderer(r: *Renderer) void {
    for (&r.buffers) |*slot| {
        if (slot.command != null) objc.send(void, slot.command, "waitUntilCompleted", .{});
        objc.release(slot.command);
        objc.release(slot.buffer);
    }
    r.clearGlyphs();
    r.glyphs.deinit(r.allocator);
    r.instances.deinit(r.allocator);
    r.clearBatches();
    r.batches.deinit(r.allocator);
    var image_iterator = r.images.valueIterator();
    while (image_iterator.next()) |image| objc.release(image.texture);
    r.images.deinit(r.allocator);
    r.text.deinit();
    objc.release(r.atlas);
    objc.release(r.pipeline);
    objc.release(r.queue);
    objc.release(r.device);
    r.allocator.destroy(r);
}

fn textureDescriptor(format: usize, width: usize, height: usize, usage: usize) Id {
    const descriptor = objc.send(Id, objc.class("MTLTextureDescriptor"), "texture2DDescriptorWithPixelFormat:width:height:mipmapped:", .{ format, width, height, false });
    objc.send(void, descriptor, "setStorageMode:", .{@as(usize, 0)});
    objc.send(void, descriptor, "setUsage:", .{usage});
    return descriptor;
}

fn finishSlot(r: *Renderer, slot: *BufferSlot) !void {
    if (slot.command == null) return;
    // Three slots permit asynchronous frames. Only recycling a still-busy slot
    // throttles submission; there is no wait after an ordinary presentation.
    if (objc.send(usize, slot.command, "status", .{}) < 4) objc.send(void, slot.command, "waitUntilCompleted", .{});
    const status = objc.send(usize, slot.command, "status", .{});
    const start = objc.send(f64, slot.command, "GPUStartTime", .{});
    const end = objc.send(f64, slot.command, "GPUEndTime", .{});
    if (end > start) r.counters.gpu_ns = @intFromFloat((end - start) * 1e9);
    if (status == 5) {
        reportNativeError(objc.send(Id, slot.command, "error", .{}));
        objc.release(slot.command);
        slot.command = null;
        return error.MetalExecutionFailed;
    }
    objc.release(slot.command);
    slot.command = null;
}

fn drawFrame(r: *Renderer, frame: scene.Frame, size: Size, scale: f32, texture: Id, drawable: Id, synchronous: bool) !void {
    if (texture == null or !std.math.isFinite(size.width) or !std.math.isFinite(size.height) or size.width <= 0 or size.height <= 0 or !std.math.isFinite(scale) or scale <= 0 or scale > 8) return error.InvalidRenderTarget;
    try validateScene(frame);
    const pool = objc.Pool.init();
    defer pool.deinit();
    const start = objc.clockNs();
    r.build(frame, scale) catch |err| {
        if (err != error.AtlasFull) return err;
        try r.resetAtlas();
        r.build(frame, scale) catch |retry| return if (retry == error.AtlasFull) error.FrameExceedsAtlas else retry;
    };
    const slot = &r.buffers[r.next_slot];
    try finishSlot(r, slot);
    const required = @max(4096, r.instances.items.len * @sizeOf(Instance));
    if (slot.buffer == null or slot.capacity < required) {
        var capacity: usize = 4096;
        while (capacity < required) capacity *= 2;
        const fresh = objc.send(Id, r.device, "newBufferWithLength:options:", .{ capacity, @as(usize, 0) }) orelse return error.MetalAllocationFailed;
        objc.release(slot.buffer);
        slot.buffer = fresh;
        slot.capacity = capacity;
    }
    const bytes = std.mem.sliceAsBytes(r.instances.items);
    const destination = objc.send(?[*]u8, slot.buffer, "contents", .{}) orelse return error.MetalAllocationFailed;
    @memcpy(destination[0..bytes.len], bytes);
    const pass = objc.send(Id, objc.class("MTLRenderPassDescriptor"), "renderPassDescriptor", .{});
    const attachments = objc.send(Id, pass, "colorAttachments", .{});
    const attachment = objc.send(Id, attachments, "objectAtIndexedSubscript:", .{@as(usize, 0)});
    objc.send(void, attachment, "setTexture:", .{texture});
    objc.send(void, attachment, "setLoadAction:", .{@as(usize, 2)});
    objc.send(void, attachment, "setStoreAction:", .{@as(usize, 1)});
    const background = frame.background;
    objc.send(void, attachment, "setClearColor:", .{ClearColor{ .red = background.r, .green = background.g, .blue = background.b, .alpha = background.a }});
    const command = objc.send(Id, r.queue, "commandBuffer", .{}) orelse return error.MetalCommandUnavailable;
    const encoder = objc.send(Id, command, "renderCommandEncoderWithDescriptor:", .{pass}) orelse return error.MetalCommandUnavailable;
    objc.send(void, encoder, "setRenderPipelineState:", .{r.pipeline});
    objc.send(void, encoder, "setVertexBuffer:offset:atIndex:", .{ slot.buffer, @as(usize, 0), @as(usize, 0) });
    const logical_size = [2]f32{ size.width, size.height };
    objc.send(void, encoder, "setVertexBytes:length:atIndex:", .{ @as(*const anyopaque, &logical_size), @as(usize, @sizeOf(@TypeOf(logical_size))), @as(usize, 1) });
    for (r.batches.items) |batch| {
        objc.send(void, encoder, "setVertexBuffer:offset:atIndex:", .{ slot.buffer, batch.start * @sizeOf(Instance), @as(usize, 0) });
        objc.send(void, encoder, "setFragmentTexture:atIndex:", .{ batch.texture, @as(usize, 0) });
        objc.send(void, encoder, "drawPrimitives:vertexStart:vertexCount:instanceCount:", .{ @as(usize, 3), @as(usize, 0), @as(usize, 6), batch.count });
    }
    objc.send(void, encoder, "endEncoding", .{});
    if (drawable != null) objc.send(void, command, "presentDrawable:", .{drawable});
    slot.command = objc.retain(command);
    objc.send(void, command, "commit", .{});
    r.counters.cpu_ns = objc.clockNs() - start;
    r.counters.frames +%= 1;
    r.next_slot = (r.next_slot + 1) % r.buffers.len;
    if (synchronous) try finishSlot(r, slot);
}

fn snapshotFrame(r: *Renderer, frame: scene.Frame, size: Size, path: []const u8) !void {
    if (!std.math.isFinite(size.width) or !std.math.isFinite(size.height) or size.width <= 0 or size.height <= 0 or size.width > 16384 or size.height > 16384) return error.InvalidSnapshotSize;
    if (path.len == 0 or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidSnapshotPath;
    const pool = objc.Pool.init();
    defer pool.deinit();
    const width: usize = @intFromFloat(@ceil(size.width));
    const height: usize = @intFromFloat(@ceil(size.height));
    const texture = objc.send(Id, r.device, "newTextureWithDescriptor:", .{textureDescriptor(80, width, height, 4)}) orelse return error.MetalAllocationFailed;
    defer objc.release(texture);
    try drawFrame(r, frame, size, 1, texture, null, true);
    const raw_image = objc.send(Id, objc.class("NSBitmapImageRep"), "alloc", .{}) orelse return error.SnapshotAllocationFailed;
    const image = objc.send(Id, raw_image, "initWithBitmapDataPlanes:pixelsWide:pixelsHigh:bitsPerSample:samplesPerPixel:hasAlpha:isPlanar:colorSpaceName:bitmapFormat:bytesPerRow:bitsPerPixel:", .{
        @as(?*anyopaque, null),               width,         height,    @as(usize, 8),  @as(usize, 4), true, false,
        objc.string("NSDeviceRGBColorSpace"), @as(usize, 0), width * 4, @as(usize, 32),
    }) orelse return error.SnapshotAllocationFailed;
    defer objc.release(image);
    const pixels = objc.send(?[*]u8, image, "bitmapData", .{}) orelse return error.SnapshotAllocationFailed;
    objc.send(void, texture, "getBytes:bytesPerRow:fromRegion:mipmapLevel:", .{
        @as(*anyopaque, pixels), width * 4, Region{ .size = .{ .width = width, .height = height } }, @as(usize, 0),
    });
    var offset: usize = 0;
    while (offset < width * height * 4) : (offset += 4) std.mem.swap(u8, &pixels[offset], &pixels[offset + 2]);
    const properties = objc.send(Id, objc.class("NSDictionary"), "dictionary", .{});
    const png = objc.send(Id, image, "representationUsingType:properties:", .{ @as(usize, 4), properties }) orelse return error.SnapshotEncodingFailed;
    var native_error: Id = null;
    const written = objc.send(bool, png, "writeToFile:options:error:", .{ objc.string(path), @as(usize, 1), &native_error });
    if (!written) {
        reportNativeError(native_error);
        return error.SnapshotWriteFailed;
    }
}

fn rendererStats(r: *Renderer) Stats {
    var result = r.counters;
    result.glyphs = r.glyphs.count();
    result.shape_hits = r.text.shape_hits;
    result.shape_misses = r.text.shape_misses;
    result.atlas_bytes = atlas_side * atlas_side;
    result.layout_bytes = r.text.layout_bytes;
    result.instance_bytes = r.instances.capacity * @sizeOf(Instance);
    result.image_bytes = r.image_bytes;
    result.image_textures = r.images.count();
    for (r.buffers) |slot| result.instance_bytes += slot.capacity;
    return result;
}

fn reportNativeError(value: Id) void {
    if (value != null) std.debug.print("Zircon UI: {s}\n", .{objc.fromString(objc.send(Id, value, "localizedDescription", .{}))});
}

fn validateScene(frame: scene.Frame) !void {
    for (frame.items) |item| {
        inline for (.{ "rect", "clip" }) |field| {
            const bounds = @field(item, field);
            inline for (.{ "x", "y", "width", "height" }) |axis| if (!std.math.isFinite(@field(bounds, axis))) return error.InvalidScene;
            if (bounds.width < 0 or bounds.height < 0) return error.InvalidScene;
        }
        inline for (.{ "r", "g", "b", "a" }) |channel| {
            const n = @field(item.color, channel);
            if (!std.math.isFinite(n) or n < 0 or n > 1) return error.InvalidScene;
        }
        if (!std.math.isFinite(item.radius) or item.radius < 0) return error.InvalidScene;
        if (!std.math.isFinite(item.transform.scale_x) or !std.math.isFinite(item.transform.scale_y) or item.transform.scale_x <= 0 or item.transform.scale_y <= 0 or !std.math.isFinite(item.transform.translate_x) or !std.math.isFinite(item.transform.translate_y) or !std.math.isFinite(item.transform.rotation) or !std.math.isFinite(item.transform.opacity) or item.transform.opacity < 0 or item.transform.opacity > 1) return error.InvalidScene;
        if (item.kind == .line) {
            const segment = item.segment orelse return error.InvalidScene;
            inline for (.{ segment.start.x, segment.start.y, segment.end.x, segment.end.y, segment.width }) |value| if (!std.math.isFinite(value)) return error.InvalidScene;
            if (segment.width <= 0) return error.InvalidScene;
        }
        if (item.kind == .text and (!std.math.isFinite(item.font_size) or item.font_size <= 0)) return error.InvalidScene;
        if (item.kind == .image) {
            const image = item.image orelse return error.InvalidScene;
            try image.validate();
            inline for (.{ "x", "y", "width", "height" }) |field| if (!std.math.isFinite(@field(item.uv, field)) or @field(item.uv, field) < 0 or @field(item.uv, field) > 1) return error.InvalidScene;
            if (item.uv.x + item.uv.width > 1.00001 or item.uv.y + item.uv.height > 1.00001) return error.InvalidScene;
        }
    }
}
