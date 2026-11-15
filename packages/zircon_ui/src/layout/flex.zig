//! Deterministic, single-line flex rows and columns. Logical units only.
//! Supports padding, margins, gap, grow/shrink with min/max freezing and alignment.
//! Text measurement is injected. CSS wrapping/grid/baseline alignment are not claimed.
const std = @import("std");
const cache_key = @import("../ui/cache_key.zig");
const ui_custom = @import("../ui/custom.zig");
const elements = @import("../ui/element.zig");
const styles = @import("../ui/style.zig");
const tree = @import("../ui/tree.zig");
const layout_cache = @import("cache.zig");
const geometry = @import("geometry.zig");
const measure_module = @import("measure.zig");
const Measurer = measure_module.Measurer;
pub const Constraints = struct { viewport: geometry.Size, rem: f32 = 16 };
pub const Layout = struct {
    allocator: std.mem.Allocator,
    bounds: []geometry.Rect,
    frame_epoch: u64,
    pub fn deinit(layout: *Layout) void {
        layout.allocator.free(layout.bounds);
        layout.* = undefined;
    }
    pub fn get(layout: *const Layout, frame: *const tree.Frame, handle: elements.Element) !geometry.Rect {
        _ = try frame.get(handle);
        if (handle.frame_epoch != layout.frame_epoch) return error.InvalidFrame;
        return layout.bounds[handle.index];
    }
};
pub fn calculate(a: std.mem.Allocator, frame: *const tree.Frame, root: elements.Element, constraints: Constraints, measurer: Measurer) !Layout {
    return calculateWithCache(a, frame, root, constraints, measurer, null);
}
pub fn calculateWithCache(a: std.mem.Allocator, frame: *const tree.Frame, root: elements.Element, constraints: Constraints, measurer: Measurer, cache: ?*layout_cache.LayoutCache) !Layout {
    if (!valid(constraints.viewport.width) or !valid(constraints.viewport.height) or !valid(constraints.rem) or constraints.rem == 0) return error.InvalidConstraints;
    _ = try frame.get(root);
    const bounds = try a.alloc(geometry.Rect, frame.nodes.items.len);
    errdefer a.free(bounds);
    @memset(bounds, .{});
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const intrinsic = try arena.allocator().alloc(geometry.Size, frame.nodes.items.len);
    @memset(intrinsic, .{ .width = 0, .height = 0 });
    const fingerprints = try arena.allocator().alloc(u64, frame.nodes.items.len);
    @memset(fingerprints, 0);
    if (cache != null) _ = fingerprintNode(frame, root.index, cache_key.hash(0, .{ constraints, measurer.generation }), fingerprints, 0);
    var engine: Engine = .{ .frame = frame, .constraints = constraints, .measure = measurer, .bounds = bounds, .intrinsic = intrinsic, .scratch = arena.allocator(), .frame_allocator = a, .cache = cache, .fingerprints = fingerprints };
    try engine.measureNode(root.index, constraints.viewport, 0);
    const style = frame.nodes.items[root.index].style;
    const size = try engine.resolveSize(style, constraints.viewport, .{ .width = @max(0, constraints.viewport.width - style.margin.horizontal()), .height = @max(0, constraints.viewport.height - style.margin.vertical()) });
    try engine.arrange(root.index, .{ .x = style.margin.left, .y = style.margin.top, .width = size.width, .height = size.height }, 0);
    return .{ .allocator = a, .bounds = bounds, .frame_epoch = frame.epoch };
}
const Engine = struct {
    frame: *const tree.Frame,
    constraints: Constraints,
    measure: Measurer,
    bounds: []geometry.Rect,
    intrinsic: []geometry.Size,
    scratch: std.mem.Allocator,
    frame_allocator: std.mem.Allocator,
    cache: ?*layout_cache.LayoutCache,
    fingerprints: []const u64,
    fn length(e: *Engine, value: styles.Length, parent: f32) ?f32 {
        return switch (value) {
            .auto => null,
            .px => |n| n,
            .percent => |n| parent * n / 100,
            .rem => |n| n * e.constraints.rem,
            .viewport_width => |n| e.constraints.viewport.width * n / 100,
            .viewport_height => |n| e.constraints.viewport.height * n / 100,
        };
    }
    fn limits(e: *Engine, style: styles.Style, parent: geometry.Size, horizontal: bool) struct { min: f32, max: f32 } {
        const available = if (horizontal) parent.width else parent.height;
        const min = e.length(if (horizontal) style.min_width else style.min_height, available) orelse 0;
        const max = @max(min, e.length(if (horizontal) style.max_width else style.max_height, available) orelse std.math.inf(f32));
        return .{ .min = min, .max = max };
    }
    fn resolveSize(e: *Engine, style: styles.Style, parent: geometry.Size, natural: geometry.Size) !geometry.Size {
        const x = e.limits(style, parent, true);
        const y = e.limits(style, parent, false);
        const size: geometry.Size = .{ .width = std.math.clamp(e.length(style.width, parent.width) orelse natural.width, x.min, x.max), .height = std.math.clamp(e.length(style.height, parent.height) orelse natural.height, y.min, y.max) };
        if (!valid(size.width) or !valid(size.height)) return error.InvalidStyle;
        return size;
    }
    fn measureNode(e: *Engine, index: u32, available: geometry.Size, depth: usize) anyerror!void {
        if (depth > 128) return error.LayoutDepthExceeded;
        const node = e.frame.nodes.items[index];
        const style = node.style;
        const declared = try e.resolveSize(style, available, available);
        const content: geometry.Size = .{ .width = @max(0, declared.width - style.padding.horizontal()), .height = @max(0, declared.height - style.padding.vertical()) };
        const key = if (node.cache and node.key != null) cache_key.scoped(e.frame, index) else null;
        const fingerprint = e.fingerprints[index];
        if (key) |id| if (e.cache) |store| if (fingerprint != 0) if (store.lookup(id, fingerprint, available)) |cached| {
            var cursor: usize = 0;
            e.restoreSizes(index, cached, &cursor);
            return;
        };
        var natural: geometry.Size = .{ .width = 0, .height = 0 };
        switch (node.kind) {
            .custom => |custom| {
                var cx: ui_custom.LayoutCx = .{ .allocator = e.frame_allocator, .available = content, .measurer = e.measure };
                natural = try custom.measure(custom.object, &cx);
            },
            .text => |text| natural = try e.measure.text(e.measure.context, text, style.text),
            .container, .button => container: {
                if (node.kind == .button and node.children.len == 0) {
                    natural = try e.measure.text(e.measure.context, node.kind.button.label, style.text);
                    break :container;
                }
                if (style.direction == .stack) {
                    for (node.children) |child| {
                        try e.measureNode(child, content, depth + 1);
                        const child_style = e.frame.nodes.items[child].style;
                        natural.width = @max(natural.width, e.intrinsic[child].width + child_style.margin.horizontal());
                        natural.height = @max(natural.height, e.intrinsic[child].height + child_style.margin.vertical());
                    }
                    break :container;
                }
                var main: f32 = 0;
                var cross: f32 = 0;
                for (node.children) |child| {
                    try e.measureNode(child, content, depth + 1);
                    const child_style = e.frame.nodes.items[child].style;
                    const measured = e.intrinsic[child];
                    if (style.direction == .row) {
                        main += measured.width + child_style.margin.horizontal();
                        cross = @max(cross, measured.height + child_style.margin.vertical());
                    } else {
                        main += measured.height + child_style.margin.vertical();
                        cross = @max(cross, measured.width + child_style.margin.horizontal());
                    }
                }
                if (node.children.len > 1) main += @as(f32, @floatFromInt(node.children.len - 1)) * style.gap;
                natural = if (style.direction == .row) .{ .width = main, .height = cross } else .{ .width = cross, .height = main };
            },
        }
        if (!valid(natural.width) or !valid(natural.height)) return error.InvalidMeasurement;
        natural.width += style.padding.horizontal();
        natural.height += style.padding.vertical();
        e.intrinsic[index] = try e.resolveSize(style, available, natural);
        if (key) |id| if (e.cache) |store| if (fingerprint != 0) {
            var sizes: std.ArrayList(geometry.Size) = .empty;
            try e.collectSizes(index, &sizes);
            try store.put(id, fingerprint, available, sizes.items);
        };
    }
    fn arrange(e: *Engine, index: u32, rect: geometry.Rect, depth: usize) anyerror!void {
        const node = e.frame.nodes.items[index];
        const key = if (node.cache and node.key != null) cache_key.scoped(e.frame, index) else null;
        if (key) |id| if (e.cache) |store| if (e.fingerprints[index] != 0) if (store.arranged(id, e.fingerprints[index], rect)) |cached| {
            var cursor: usize = 0;
            e.restoreBounds(index, cached, &cursor);
            return;
        };
        try e.arrangeFresh(index, rect, depth);
        if (key) |id| if (e.cache) |store| if (e.fingerprints[index] != 0) {
            var bounds: std.ArrayList(geometry.Rect) = .empty;
            try e.collectBounds(index, &bounds);
            try store.putArrangement(id, e.fingerprints[index], rect, bounds.items);
        };
    }
    fn restoreSizes(e: *Engine, index: u32, sizes: []const geometry.Size, cursor: *usize) void {
        e.intrinsic[index] = sizes[cursor.*];
        cursor.* += 1;
        for (e.frame.nodes.items[index].children) |child| e.restoreSizes(child, sizes, cursor);
    }
    fn restoreBounds(e: *Engine, index: u32, bounds: []const geometry.Rect, cursor: *usize) void {
        e.bounds[index] = bounds[cursor.*];
        cursor.* += 1;
        for (e.frame.nodes.items[index].children) |child| e.restoreBounds(child, bounds, cursor);
    }
    fn collectSizes(e: *Engine, index: u32, sizes: *std.ArrayList(geometry.Size)) anyerror!void {
        try sizes.append(e.scratch, e.intrinsic[index]);
        for (e.frame.nodes.items[index].children) |child| try e.collectSizes(child, sizes);
    }
    fn collectBounds(e: *Engine, index: u32, bounds: *std.ArrayList(geometry.Rect)) anyerror!void {
        try bounds.append(e.scratch, e.bounds[index]);
        for (e.frame.nodes.items[index].children) |child| try e.collectBounds(child, bounds);
    }
    fn arrangeFresh(e: *Engine, index: u32, rect: geometry.Rect, depth: usize) anyerror!void {
        if (depth > 128) return error.LayoutDepthExceeded;
        e.bounds[index] = rect;
        const node = e.frame.nodes.items[index];
        if (node.children.len == 0) return;
        const style = node.style;
        const horizontal = style.direction == .row;
        const content: geometry.Rect = .{ .x = rect.x + style.padding.left, .y = rect.y + style.padding.top - style.scroll_y, .width = @max(0, rect.width - style.padding.horizontal()), .height = @max(0, rect.height - style.padding.vertical()) };
        const available: geometry.Size = .{ .width = content.width, .height = content.height };
        if (style.direction == .stack) {
            for (node.children) |child| {
                const cs = e.frame.nodes.items[child].style;
                const size = try e.resolveSize(cs, available, .{ .width = @max(0, available.width - cs.margin.horizontal()), .height = @max(0, available.height - cs.margin.vertical()) });
                const free_x = @max(0, content.width - size.width - cs.margin.horizontal());
                const free_y = @max(0, content.height - size.height - cs.margin.vertical());
                const x: f32 = switch (style.align_items) {
                    .center => free_x / 2,
                    .end => free_x,
                    else => 0,
                };
                const y: f32 = switch (style.justify_content) {
                    .center => free_y / 2,
                    .end => free_y,
                    else => 0,
                };
                try e.arrange(child, .{ .x = content.x + cs.margin.left + x, .y = content.y + cs.margin.top + y, .width = size.width, .height = size.height }, depth + 1);
            }
            return;
        }
        const bases = try e.scratch.alloc(f32, node.children.len);
        const sizes = try e.scratch.alloc(f32, node.children.len);
        const frozen = try e.scratch.alloc(bool, node.children.len);
        @memset(frozen, false);
        var total: f32 = 0;
        var margin_total: f32 = 0;
        for (node.children, 0..) |child, i| {
            const child_style = e.frame.nodes.items[child].style;
            const measured = try e.resolveSize(child_style, available, e.intrinsic[child]);
            bases[i] = if (horizontal) measured.width else measured.height;
            sizes[i] = bases[i];
            total += bases[i];
            margin_total += if (horizontal) child_style.margin.horizontal() else child_style.margin.vertical();
        }
        const gap_total = style.gap * @as(f32, @floatFromInt(node.children.len - 1));
        var remaining = (if (horizontal) content.width else content.height) - gap_total - margin_total - total;
        const growing = remaining >= 0;
        var iterations: usize = 0;
        while (@abs(remaining) > 0.001 and iterations <= node.children.len) : (iterations += 1) {
            var weight: f32 = 0;
            for (node.children, 0..) |child, i| if (!frozen[i]) {
                const cs = e.frame.nodes.items[child].style;
                weight += if (growing) cs.flex_grow else cs.flex_shrink * bases[i];
            };
            if (weight <= 0) break;
            var consumed: f32 = 0;
            for (node.children, 0..) |child, i| if (!frozen[i]) {
                const cs = e.frame.nodes.items[child].style;
                const w = if (growing) cs.flex_grow else cs.flex_shrink * bases[i];
                if (w == 0) continue;
                const limit = e.limits(cs, available, horizontal);
                const proposed = sizes[i] + remaining * w / weight;
                const next = std.math.clamp(proposed, limit.min, limit.max);
                consumed += next - sizes[i];
                sizes[i] = next;
                if (next != proposed) frozen[i] = true;
            };
            if (@abs(consumed) < 0.001) break;
            remaining -= consumed;
        }
        const free = @max(0, remaining);
        var position: f32 = switch (style.justify_content) {
            .center => free / 2,
            .end => free,
            else => 0,
        };
        const gap = style.gap + if (style.justify_content == .space_between and node.children.len > 1) free / @as(f32, @floatFromInt(node.children.len - 1)) else @as(f32, 0);
        for (node.children, 0..) |child, i| {
            const cs = e.frame.nodes.items[child].style;
            const measured = try e.resolveSize(cs, available, e.intrinsic[child]);
            const cross_margin = if (horizontal) cs.margin.vertical() else cs.margin.horizontal();
            const cross_available = @max(0, (if (horizontal) content.height else content.width) - cross_margin);
            const cross_length = if (horizontal) cs.height else cs.width;
            const limits_cross = e.limits(cs, available, !horizontal);
            const natural_cross = if (horizontal) measured.height else measured.width;
            const cross_size = std.math.clamp(if (style.align_items == .stretch and cross_length == .auto) cross_available else natural_cross, limits_cross.min, limits_cross.max);
            const cross_offset = switch (style.align_items) {
                .center => (cross_available - cross_size) / 2,
                .end => cross_available - cross_size,
                else => 0,
            };
            const before = if (horizontal) cs.margin.left else cs.margin.top;
            const after = if (horizontal) cs.margin.right else cs.margin.bottom;
            const cross_before = if (horizontal) cs.margin.top else cs.margin.left;
            position += before;
            const child_rect: geometry.Rect = if (horizontal) .{ .x = content.x + position, .y = content.y + cross_before + cross_offset, .width = sizes[i], .height = cross_size } else .{ .x = content.x + cross_before + cross_offset, .y = content.y + position, .width = cross_size, .height = sizes[i] };
            try e.arrange(child, child_rect, depth + 1);
            position += sizes[i] + after + gap;
        }
    }
};
fn fingerprintNode(frame: *const tree.Frame, index: u32, environment: u64, fingerprints: []u64, depth: usize) u64 {
    if (depth > 128) return 0;
    const node = frame.nodes.items[index];
    var hash = cache_key.hash(environment, node.style);
    hash = cache_key.hash(hash, std.meta.activeTag(node.kind));
    var cacheable = true;
    switch (node.kind) {
        .custom => |custom| {
            const own = custom.fingerprint(custom.object);
            cacheable = own != 0 and custom.layout_cacheable;
            hash = cache_key.hash(hash, own);
        },
        .text => |text| hash = cache_key.hash(hash, text),
        .button => |button| hash = cache_key.hash(hash, button.label),
        .container => {},
    }
    hash = cache_key.hash(hash, node.children.len);
    for (node.children) |child| {
        const child_hash = fingerprintNode(frame, child, environment, fingerprints, depth + 1);
        cacheable = cacheable and child_hash != 0;
        hash = cache_key.hash(hash, child_hash);
    }
    fingerprints[index] = if (cacheable) hash else 0;
    return fingerprints[index];
}
fn valid(n: f32) bool {
    return std.math.isFinite(n) and n >= 0;
}
