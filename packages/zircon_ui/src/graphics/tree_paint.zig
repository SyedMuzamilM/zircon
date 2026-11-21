//! Paints an arranged frame in tree order. Scene storage belongs to that same
//! frame, so staging failure can discard layout and paint together.
const std = @import("std");
const metrics = @import("../controls/metrics.zig");
const flex = @import("../layout/flex.zig");
const g = @import("../layout/geometry.zig");
const measure = @import("../layout/measure.zig");
const text_style = @import("../text/style.zig");
const cache_key_module = @import("../ui/cache_key.zig");
const ui_custom = @import("../ui/custom.zig");
const tree = @import("../ui/tree.zig");
const cache_module = @import("cache.zig");
const painter_module = @import("painter.zig");
const Painter = painter_module.Painter;
pub fn paint(frame: *tree.Frame, layout: *const flex.Layout, painter: *Painter, measurer: measure.Measurer) !void {
    return paintWithCache(frame, layout, painter, measurer, null);
}
pub fn paintWithCache(frame: *tree.Frame, layout: *const flex.Layout, painter: *Painter, measurer: measure.Measurer, cache: ?*cache_module.SceneCache) !void {
    const root = frame.root orelse return error.NoFrameRoot;
    if (layout.frame_epoch != frame.epoch) return error.InvalidFrame;
    var hover_nodes: [129]u32 = undefined;
    var hover_count: usize = 0;
    var hovered = frame.hovered_node;
    while (hovered) |index| : (hovered = frame.nodes.items[index].parent) {
        if (hover_count == hover_nodes.len) return error.PaintDepthExceeded;
        hover_nodes[hover_count] = index;
        hover_count += 1;
    }
    const hover_path = hover_nodes[0..hover_count];
    std.mem.reverse(u32, hover_path);
    var fingerprints: ?[]?u64 = null;
    try node(frame, layout, painter, root.index, 1, 0, measurer, cache, &fingerprints, hover_path);
    try tooltip(frame, layout, painter, measurer);
}
fn node(frame: *tree.Frame, layout: *const flex.Layout, painter: *Painter, index: u32, inherited_opacity: f32, depth: usize, measurer: measure.Measurer, cache: ?*cache_module.SceneCache, fingerprints: *?[]?u64, hover_path: []const u32) anyerror!void {
    if (depth > 128) return error.PaintDepthExceeded;
    const value = frame.nodes.items[index];
    const bounds = layout.bounds[index];
    const opacity = inherited_opacity * value.style.opacity;
    const within_hover = depth < hover_path.len and hover_path[depth] == index;
    const background_value = if (within_hover) value.style.hover_background orelse value.style.background else value.style.background;
    const cache_key = if (cache != null and value.cache and value.key != null) cache_key_module.scoped(frame, index) else null;
    const own_fingerprint = if (cache_key != null) blk: {
        if (fingerprints.* == null) {
            const memo = try painter.allocator.alloc(?u64, frame.nodes.items.len);
            @memset(memo, null);
            fingerprints.* = memo;
        }
        break :blk fingerprintNode(frame, layout, index, measurer.generation, fingerprints.*.?, depth, hover_path);
    } else 0;
    const cacheable = own_fingerprint != 0;
    const fingerprint = if (cacheable) cache_key_module.hash(own_fingerprint, inherited_opacity) else 0;
    const cache_clip = painter.clip();
    if (cache_key) |key| if (cache) |store| if (cacheable) if (store.lookup(key, fingerprint, bounds, cache_clip)) |items| {
        store.hits += 1;
        try painter.items.ensureUnusedCapacity(painter.allocator, items.len);
        for (items) |item| {
            var copied = item;
            if (item.kind == .text) copied.text = try painter.allocator.dupe(u8, item.text);
            painter.items.appendAssumeCapacity(copied);
        }
        return;
    };
    if (cache_key != null and cache != null and cacheable) cache.?.misses += 1;
    const start = painter.items.items.len;
    if (background_value) |background| {
        var color = background;
        color.a *= opacity;
        try painter.fillRect(.{ .bounds = bounds, .color = color, .radius = value.style.radius });
    }
    if (value.style.overflow == .hidden) try painter.pushClip(bounds);
    defer if (value.style.overflow == .hidden) painter.popClip();
    switch (value.kind) {
        .custom => |custom| {
            const previous_opacity = painter.opacity;
            painter.opacity = opacity;
            defer painter.opacity = previous_opacity;
            var cx: ui_custom.PaintCx = .{ .painter = painter, .measurer = measurer, .focused = frame.focused_node == index, .text_input = &frame.text_input, .time = frame.time, .next_deadline = &frame.next_deadline };
            try custom.paint(custom.object, &cx, bounds);
        },
        .container => {},
        .text, .button => {
            const text = if (value.kind == .text) value.kind.text else value.kind.button.label;
            var style = value.style.text;
            style.color.a *= opacity;
            var content: g.Rect = .{ .x = bounds.x + value.style.padding.left, .y = bounds.y + value.style.padding.top, .width = @max(0, bounds.width - value.style.padding.horizontal()), .height = @max(0, bounds.height - value.style.padding.vertical()) };
            // A bare button label follows the same alignment as a text child.
            // Previously its top-left paint origin ignored centered layout.
            if (value.kind == .button and value.children.len == 0) {
                const measured = try measurer.text(measurer.context, text, style);
                const horizontal = value.style.direction == .row;
                const center_x = if (horizontal) value.style.justify_content == .center else value.style.align_items == .center;
                const center_y = if (horizontal) value.style.align_items == .center else value.style.justify_content == .center;
                if (center_x) content.x += @max(0, content.width - measured.width) / 2;
                if (center_y) content.y += @max(0, content.height - measured.height) / 2;
                content.width = @min(content.width, measured.width);
                content.height = @min(content.height, measured.height);
            }
            if (value.kind == .text or value.children.len == 0) try painter.drawText(.{ .bounds = content, .text = text, .style = style });
        },
    }
    for (value.children) |child| try node(frame, layout, painter, child, opacity, depth + 1, measurer, cache, fingerprints, hover_path);
    if (cache_key) |key| if (cache) |store| if (cacheable) {
        store.put(key, fingerprint, bounds, cache_clip, painter.items.items[start..]) catch |err| if (err != error.UncacheableScene) return err;
    };
}

fn fingerprintNode(frame: *const tree.Frame, layout: *const flex.Layout, index: u32, generation: u64, fingerprints: []?u64, depth: usize, hover_path: []const u32) u64 {
    if (depth > 128) return 0;
    if (fingerprints[index]) |known| return known;
    const value = frame.nodes.items[index];
    const within_hover = depth < hover_path.len and hover_path[depth] == index;
    var hash = cache_key_module.hash(generation, value.style);
    hash = cache_key_module.hash(hash, layout.bounds[index]);
    hash = cache_key_module.hash(hash, within_hover);
    hash = cache_key_module.hash(hash, frame.focused_node == index);
    hash = cache_key_module.hash(hash, std.meta.activeTag(value.kind));
    var cacheable = true;
    switch (value.kind) {
        .container => {},
        .text => |text| hash = cache_key_module.hash(hash, text),
        .button => |button| hash = cache_key_module.hash(hash, button.label),
        .custom => |custom| {
            const own = custom.fingerprint(custom.object);
            cacheable = own != 0;
            hash = cache_key_module.hash(hash, own);
        },
    }
    hash = cache_key_module.hash(hash, value.children.len);
    for (value.children) |child| {
        const child_hash = fingerprintNode(frame, layout, child, generation, fingerprints, depth + 1, hover_path);
        if (child_hash == 0) cacheable = false;
        hash = cache_key_module.hash(hash, child_hash);
    }
    const result = if (cacheable) hash else 0;
    fingerprints[index] = result;
    return result;
}

fn tooltip(frame: *tree.Frame, layout: *const flex.Layout, painter: *Painter, measurer: measure.Measurer) !void {
    if (!frame.tooltips_enabled) return;
    var hovered = frame.hovered_node;
    while (hovered) |index| : (hovered = frame.nodes.items[index].parent) if (frame.nodes.items[index].tooltip) |label| {
        const delay = frame.tooltip_delay - (frame.time - frame.hover_started);
        if (delay > 0) {
            frame.next_deadline = @min(frame.next_deadline orelse (frame.time + delay), frame.time + delay);
            return;
        }
        const colors = frame.nodes.items[index].tooltip_colors orelse [3]g.Color{ g.Color.rgb(0x262b33), g.Color.rgb(0xf0f2f5), g.Color.rgb(0x5a6270) };
        const style: text_style.TextStyle = .{ .size = 12, .color = colors[1] };
        const size = try measurer.text(measurer.context, label, style);
        const anchor = layout.bounds[index];
        const width = @min(@max(0, frame.viewport.width - 12), size.width + 16);
        const height = size.height + 12;
        const x = @max(6, @min(anchor.x, frame.viewport.width - width - 6));
        const below = anchor.y + anchor.height + 6;
        const y = if (below + height <= frame.viewport.height - 6) below else @max(6, anchor.y - height - 6);
        const rect: g.Rect = .{ .x = x, .y = y, .width = @max(0, width), .height = height };
        const radius = metrics.popover_radius;
        try painter.fillRect(.{ .bounds = rect, .radius = radius, .color = colors[2] });
        try painter.fillRect(.{ .bounds = .{ .x = x + 1, .y = y + 1, .width = @max(0, width - 2), .height = height - 2 }, .radius = radius - 1, .color = colors[0] });
        try painter.drawText(.{ .bounds = .{ .x = x + 8, .y = y + 6, .width = @max(0, width - 16), .height = size.height }, .text = label, .style = style });
        return;
    };
}
