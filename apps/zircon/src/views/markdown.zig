//! Native Markdown preview. Parsed generations and decoded images live outside
//! frame arenas; committed custom elements retain a generation until retirement.
const std = @import("std");
const zircon_editor = @import("zircon_editor");
const md = @import("zircon_markdown");
const text = @import("zircon_text");
const ui = @import("zircon_ui");
const syntax = zircon_editor.syntax;
const Image = ui.graphics.images.Image;
pub const Outcome = struct { handled: bool = false, source_offset: ?usize = null, open_path: ?[]const u8 = null, open_url: ?[]const u8 = null };
pub const Colors = struct {
    background: ui.Color = ui.Color.rgb(0x242830),
    text: ui.Color = ui.Color.rgb(0xd3dae5),
    muted: ui.Color = ui.Color.rgb(0x929cab),
    accent: ui.Color = ui.Color.rgb(0x87afd6),
    code: ui.Color = ui.Color.rgb(0x1c222b),
    border: ui.Color = ui.Color.rgb(0x3c4350),
    tokens: [7]ui.Color = (zircon_editor.Theme{}).tokens,
};
const Asset = struct { stamp: ?std.Io.File.Stat = null, target: []const u8, path: ?[]u8 = null, image: ?Image = null, failure: ?anyerror = null };
const Generation = struct {
    allocator: std.mem.Allocator,
    refs: usize = 1,
    layout_builds: usize = 0,
    cached: ?*Layout = null,
    owner: std.Thread.Id,
    document: md.Document,
    revision: u64,
    path: ?[]u8,
    assets: []Asset,
    fn retain(self: *Generation) *Generation {
        std.debug.assert(self.owner == std.Thread.getCurrentId());
        self.refs += 1;
        return self;
    }
    fn release(self: *Generation) void {
        std.debug.assert(self.owner == std.Thread.getCurrentId() and self.refs > 0);
        self.refs -= 1;
        if (self.refs != 0) return;
        const a = self.allocator;
        for (self.assets) |*asset| {
            if (asset.image) |*image| image.deinit();
            if (asset.path) |path| a.free(path);
        }
        if (self.cached) |cached| cached.release();
        a.free(self.assets);
        if (self.path) |path| a.free(path);
        self.document.deinit();
        a.destroy(self);
    }
    fn findAsset(self: *const Generation, target: []const u8) ?*const Asset {
        for (self.assets) |*entry| if (std.mem.eql(u8, entry.target, target)) return entry;
        return null;
    }
};
pub const Preview = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    generation: *Generation,
    scroll: ui.controls.Scroll = .{},
    follow_end: bool = false,
    colors: Colors = .{},
    compact: bool = false,
    pub fn init(a: std.mem.Allocator, io: std.Io, path: ?[]const u8, snapshot: text.Snapshot) !Preview {
        return .{ .allocator = a, .io = io, .generation = try prepare(a, io, path, snapshot, null) };
    }
    pub fn deinit(self: *Preview) void {
        self.generation.release();
        self.* = undefined;
    }
    /// Builds a complete replacement before releasing old parsed/image state.
    pub fn refresh(self: *Preview, snapshot: text.Snapshot) !void {
        if (self.generation.revision == snapshot.revision()) return;
        const next = try prepare(self.allocator, self.io, self.generation.path, snapshot, self.generation);
        self.generation.release();
        self.generation = next;
    }
    pub fn imageIdentity(self: *const Preview, target: []const u8) ?u64 {
        const asset = self.generation.findAsset(target) orelse return null;
        return if (asset.image) |image| image.id() else null;
    }
    pub fn layoutBuilds(self: *const Preview) usize {
        return self.generation.layout_builds;
    }
    pub fn revision(self: *const Preview) u64 {
        return self.generation.revision;
    }
    pub fn render(self: *const Preview, builder: *ui.Ui) !ui.Element {
        const value: Canvas = .{ .generation = self.generation.retain(), .scroll = self.scroll.offset, .follow_end = self.follow_end, .colors = self.colors, .compact = self.compact };
        errdefer value.generation.release();
        return builder.custom(Canvas, value, .{ .flex_grow = 1, .overflow = .hidden, .background = self.colors.background });
    }
    pub fn contentHeight(self: *const Preview, metrics: ui.layout.Measurer, width: f32) !f32 {
        return (try cachedLayout(self.generation, metrics, width, self.colors, self.compact)).prepared.height;
    }
    /// Link paths/URLs are borrowed from this preview generation until refresh.
    /// Source offsets let the host reveal the actual editable Markdown document.
    pub fn handle(self: *Preview, event: *ui.Event(ui.Input)) !Outcome {
        switch (event.data) {
            .scroll => |wheel| {
                const prepared = (try cachedLayout(self.generation, try event.textMetrics(), event.bounds.width, self.colors, self.compact)).prepared;
                if (self.follow_end) self.scroll.offset = @max(0, prepared.height - event.bounds.height);
                self.follow_end = false;
                self.scroll.wheel(wheel.y, prepared.height, event.bounds.height);
                event.preventDefault();
                return .{ .handled = true };
            },
            .pointer_down => |pointer| {
                if (pointer.button != .primary) return .{};
                const prepared = (try cachedLayout(self.generation, try event.textMetrics(), event.bounds.width, self.colors, self.compact)).prepared;
                const point: ui.Point = .{ .x = pointer.position.x - event.bounds.x, .y = pointer.position.y - event.bounds.y + self.scroll.offset };
                for (prepared.hits) |hit| if (contains(hit.bounds, point)) {
                    event.preventDefault();
                    event.focus();
                    if (hit.target) |target| {
                        if (external(target)) return .{ .handled = true, .source_offset = hit.source, .open_url = target };
                        if (std.mem.startsWith(u8, target, "#")) return .{ .handled = true, .source_offset = anchor(self.generation.document, target[1..]) orelse hit.source };
                        return .{ .handled = true, .source_offset = hit.source, .open_path = target };
                    }
                    return .{ .handled = true, .source_offset = hit.source };
                };
                return .{};
            },
            else => return .{},
        }
    }
};
fn prepare(a: std.mem.Allocator, io: std.Io, path: ?[]const u8, snapshot: text.Snapshot, previous: ?*Generation) !*Generation {
    if (snapshot.byteLen() > 16 * 1024 * 1024) return error.MarkdownTooLarge;
    const bytes = try snapshot.copy(a, .{ .start = 0, .end = snapshot.byteLen() });
    defer a.free(bytes);
    var document = try md.parse(a, bytes);
    errdefer document.deinit();
    const owned_path = if (path) |p| try a.dupe(u8, p) else null;
    errdefer if (owned_path) |p| a.free(p);
    var assets: std.ArrayList(Asset) = .empty;
    errdefer {
        for (assets.items) |*item| {
            if (item.image) |*image| image.deinit();
            if (item.path) |p| a.free(p);
        }
        assets.deinit(a);
    }
    for (document.blocks) |block| {
        for (block.inlines) |span| if (span.kind == .image) try loadAsset(a, io, owned_path, span.target.?, &assets, previous);
        if (block.table) |table| for (table.rows) |row| for (row.cells) |cell| for (cell.content) |span| if (span.kind == .image) try loadAsset(a, io, owned_path, span.target.?, &assets, previous);
    }
    const owned_assets = try assets.toOwnedSlice(a);
    errdefer {
        for (owned_assets) |*item| {
            if (item.image) |*image| image.deinit();
            if (item.path) |p| a.free(p);
        }
        a.free(owned_assets);
    }
    const result = try a.create(Generation);
    result.* = .{ .allocator = a, .owner = std.Thread.getCurrentId(), .document = document, .revision = snapshot.revision(), .path = owned_path, .assets = owned_assets };
    return result;
}

fn loadAsset(a: std.mem.Allocator, io: std.Io, path: ?[]const u8, target: []const u8, list: *std.ArrayList(Asset), previous: ?*Generation) !void {
    for (list.items) |item| if (std.mem.eql(u8, item.target, target)) return;
    var asset: Asset = .{ .target = target };
    errdefer {
        if (asset.image) |*image| image.deinit();
        if (asset.path) |p| a.free(p);
    }
    if (external(target) or std.mem.startsWith(u8, target, "data:")) asset.failure = error.RemoteImageUnavailable else {
        const parent = if (path) |p| std.fs.path.dirname(p) orelse "." else ".";
        asset.path = try std.fs.path.resolve(a, &.{ parent, target });
        asset.stamp = std.Io.Dir.cwd().statFile(io, asset.path.?, .{}) catch null;
        if (previous) |old| if (old.findAsset(target)) |cached| if (cached.stamp != null and asset.stamp != null) {
            const before = cached.stamp.?;
            const after = asset.stamp.?;
            if (before.inode == after.inode and before.size == after.size and before.mtime.nanoseconds == after.mtime.nanoseconds and before.ctime.nanoseconds == after.ctime.nanoseconds) {
                asset.image = if (cached.image) |image| image.clone() else null;
                asset.failure = cached.failure;
                try list.append(a, asset);
                return;
            }
        };
        if (std.Io.Dir.cwd().readFileAlloc(io, asset.path.?, a, .limited(ui.graphics.images.max_bytes))) |bytes| {
            defer a.free(bytes);
            asset.image = loadImage(a, bytes) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => blk: {
                    asset.failure = err;
                    break :blk null;
                },
            };
        } else |err| {
            if (err == error.OutOfMemory) return err;
            asset.failure = err;
        }
    }
    try list.append(a, asset);
}

fn external(target: []const u8) bool {
    return std.mem.startsWith(u8, target, "https://") or std.mem.startsWith(u8, target, "http://") or std.mem.startsWith(u8, target, "mailto:");
}

fn anchor(document: md.Document, target: []const u8) ?usize {
    for (document.blocks) |block| if (block.kind == .heading) {
        var i: usize = 0;
        var j: usize = 0;
        while (i < block.content.len and j < target.len) : (i += 1) {
            const byte = std.ascii.toLower(block.content[i]);
            if (std.ascii.isAlphanumeric(byte) or byte >= 0x80) {
                if (target[j] != byte) break;
                j += 1;
            } else if (byte == ' ' or byte == '-') {
                if (target[j] != '-') break;
                j += 1;
            }
        }
        if (i == block.content.len and j == target.len) return block.source.start;
    };
    return null;
}
const TextDraw = struct { bounds: ui.Rect, text: []const u8, style: ui.TextStyle };
const Fill = struct { bounds: ui.Rect, color: ui.Color, radius: f32 = 0 };
const ImageDraw = struct { bounds: ui.Rect, image: Image };
const Hit = struct { bounds: ui.Rect, source: usize, target: ?[]const u8 = null };
const Prepared = struct { texts: []const TextDraw, fills: []const Fill, images: []const ImageDraw, hits: []const Hit, height: f32 };
// A frame retains its own layout while the generation replaces its cache on
// resize or font/theme changes. Retirement can therefore never free live draws.
const Layout = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    refs: usize = 1,
    width: f32,
    metrics: ui.layout.Measurer,
    colors: Colors,
    compact: bool,
    prepared: Prepared,
    fn retain(self: *Layout) *Layout {
        self.refs += 1;
        return self;
    }
    fn release(self: *Layout) void {
        self.refs -= 1;
        if (self.refs != 0) return;
        const a = self.allocator;
        self.arena.deinit();
        a.destroy(self);
    }
};
fn cachedLayout(generation: *Generation, metrics: ui.layout.Measurer, width: f32, colors: Colors, compact: bool) !*Layout {
    if (generation.cached) |cached| if (cached.width == width and cached.compact == compact and std.meta.eql(cached.colors, colors) and cached.metrics.context == metrics.context and cached.metrics.text == metrics.text and cached.metrics.generation == metrics.generation) return cached;
    const a = generation.allocator;
    const result = try a.create(Layout);
    errdefer a.destroy(result);
    var arena = std.heap.ArenaAllocator.init(a);
    errdefer arena.deinit();
    const prepared = try layout(arena.allocator(), generation, metrics, width, colors, compact);
    result.* = .{ .allocator = a, .arena = arena, .width = width, .metrics = metrics, .colors = colors, .compact = compact, .prepared = prepared };
    if (generation.cached) |old| old.release();
    generation.cached = result;
    return result;
}
const Flow = struct {
    allocator: std.mem.Allocator,
    generation: *Generation,
    metrics: ui.layout.Measurer,
    colors: Colors,
    texts: std.ArrayList(TextDraw) = .empty,
    fills: std.ArrayList(Fill) = .empty,
    images: std.ArrayList(ImageDraw) = .empty,
    hits: std.ArrayList(Hit) = .empty,
    left: f32 = 30,
    right: f32,
    x: f32 = 30,
    y: f32 = 24,
    line_height: f32 = 24,
    fn newline(self: *Flow) void {
        self.x = self.left;
        self.y += self.line_height;
    }
    fn textRun(self: *Flow, value: []const u8, style: ui.TextStyle, source: usize, target: ?[]const u8, background: bool, wrap: bool) !void {
        if (value.len == 0) return;
        var start: usize = 0;
        while (start < value.len) {
            if (value[start] == '\r' or value[start] == '\n' or value[start] == ' ' or value[start] == '\t') {
                if (value[start] == '\r' and start + 1 < value.len and value[start + 1] == '\n') start += 1;
                const code_space = style.mono and !background;
                if ((!wrap or code_space) and (value[start] == '\r' or value[start] == '\n')) self.newline() else if (code_space) {
                    const advance = @max(1, (try self.metrics.text(self.metrics.context, " ", style)).width);
                    const column: usize = @intFromFloat(@round(@max(0, self.x - self.left) / advance));
                    const count: usize = if (value[start] == '\t') 4 - column % 4 else 1;
                    for (0..count) |_| {
                        if (wrap and self.x + advance > self.right and self.x > self.left) self.newline();
                        self.x += advance;
                    }
                } else if (self.x > self.left) self.x += (try self.metrics.text(self.metrics.context, " ", style)).width;
                start += 1;
                continue;
            }
            var end = start;
            while (end < value.len and !std.ascii.isWhitespace(value[end])) : (end += 1) {}
            var word = value[start..end];
            while (word.len > 0) {
                const size = try self.metrics.text(self.metrics.context, word, style);
                if (wrap and self.x > self.left and self.x + size.width > self.right) self.newline();
                var take = word.len;
                const available = @max(1, self.right - self.x);
                if (wrap and size.width > available) {
                    take = self.metrics.index(word, style, available);
                    while (take > 0 and self.metrics.caret(word, style, take) > available) {
                        take -= 1;
                        while (take > 0 and word[take] & 0xc0 == 0x80) take -= 1;
                    }
                    if (take == 0) {
                        take = 1;
                        while (take < word.len and word[take] & 0xc0 == 0x80) : (take += 1) {}
                    }
                }
                const fragment = word[0..take];
                const width = (try self.metrics.text(self.metrics.context, fragment, style)).width;
                const bounds: ui.Rect = .{ .x = self.x, .y = self.y, .width = @max(1, width), .height = self.line_height };
                if (background) try self.fills.append(self.allocator, .{ .bounds = .{ .x = bounds.x - 2, .y = bounds.y, .width = bounds.width + 4, .height = self.line_height - 1 }, .color = self.colors.code, .radius = ui.controls.metrics.inline_code_radius });
                try self.texts.append(self.allocator, .{ .bounds = bounds, .text = fragment, .style = style });
                try self.hits.append(self.allocator, .{ .bounds = bounds, .source = source, .target = target });
                if (target != null) try self.fills.append(self.allocator, .{ .bounds = .{ .x = self.x, .y = self.y + style.size + 2, .width = width, .height = 1 }, .color = self.colors.accent });
                self.x += width;
                word = word[take..];
                if (word.len > 0 and wrap) self.newline();
            }
            start = end;
        }
    }
    fn inlineSpans(self: *Flow, spans: []const md.Inline, size: f32) !void {
        for (spans) |span| {
            if (span.kind == .image) {
                if (self.x > self.left) self.newline();
                const asset = self.generation.findAsset(span.target.?);
                if (asset != null and asset.?.image != null) {
                    const image = asset.?.image.?;
                    const dimensions = image.size();
                    const scale = @min(1, @min((self.right - self.left) / dimensions.width, 420 / dimensions.height));
                    const rect: ui.Rect = .{ .x = self.left, .y = self.y, .width = dimensions.width * scale, .height = dimensions.height * scale };
                    try self.images.append(self.allocator, .{ .bounds = rect, .image = image });
                    try self.hits.append(self.allocator, .{ .bounds = rect, .source = span.source.start, .target = span.target });
                    self.y += rect.height + 12;
                    self.x = self.left;
                } else {
                    const label = try std.fmt.allocPrint(self.allocator, "[Image unavailable: {s}]", .{span.text});
                    try self.textRun(label, .{ .size = 13, .color = self.colors.muted }, span.source.start, null, false, true);
                    self.newline();
                }
                continue;
            }
            const style: ui.TextStyle = .{ .size = if (span.strong) size + 0.5 else size, .mono = span.kind == .code, .color = if (span.kind == .link or span.emphasis) self.colors.accent else self.colors.text };
            try self.textRun(span.text, style, span.source.start, if (span.kind == .link) span.target else null, span.kind == .code, true);
        }
    }
};
fn layout(a: std.mem.Allocator, generation: *Generation, metrics: ui.layout.Measurer, width: f32, colors: Colors, compact: bool) !Prepared {
    generation.layout_builds += 1;
    const inset: f32 = if (compact) 8 else 30;
    const body_size: f32 = if (compact) 13 else 15;
    const line_height: f32 = if (compact) 20 else 24;
    const gap: f32 = if (compact) 6 else 12;
    var flow: Flow = .{ .allocator = a, .generation = generation, .metrics = metrics, .colors = colors, .right = @max(inset + 1, width - inset), .y = if (compact) 8 else 24 };
    for (generation.document.blocks) |block| {
        flow.left = inset;
        flow.x = inset;
        flow.line_height = line_height;
        const block_top = flow.y;
        switch (block.kind) {
            .heading => {
                const sizes = [_]f32{ 32, 27, 23, 20, 18, 16 };
                const size = if (compact) @min(17, sizes[@min(5, block.level -| 1)]) else sizes[@min(5, block.level -| 1)];
                flow.line_height = size + 10;
                try flow.inlineSpans(block.inlines, size);
                flow.newline();
                if (block.level <= 2) try flow.fills.append(a, .{ .bounds = .{ .x = inset, .y = flow.y + 2, .width = @max(0, flow.right - inset), .height = 1 }, .color = colors.border });
                flow.y += gap;
            },
            .paragraph => {
                try flow.inlineSpans(block.inlines, body_size);
                if (flow.x > flow.left) flow.newline();
                flow.y += gap;
            },
            .list_item => {
                flow.left = 48 + @as(f32, @floatFromInt(block.level)) * 20;
                flow.x = flow.left;
                const bullet = if (block.ordered) try std.fmt.allocPrint(a, "{d}.", .{block.number}) else "•";
                try flow.texts.append(a, .{ .bounds = .{ .x = flow.left - 20, .y = flow.y, .width = 24, .height = 24 }, .text = bullet, .style = .{ .size = 15, .color = colors.muted } });
                try flow.inlineSpans(block.inlines, body_size);
                flow.newline();
                flow.y += 4;
            },
            .quote => {
                flow.left = 48;
                flow.x = 48;
                try flow.inlineSpans(block.inlines, body_size);
                flow.newline();
                try flow.fills.append(a, .{ .bounds = .{ .x = 32, .y = block_top, .width = 3, .height = flow.y - block_top }, .color = colors.accent });
                flow.y += 8;
            },
            .rule => {
                try flow.fills.append(a, .{ .bounds = .{ .x = inset, .y = flow.y + 8, .width = @max(0, flow.right - inset), .height = 1 }, .color = colors.border });
                flow.y += 26;
            },
            .code => {
                flow.left = inset + (if (compact) @as(f32, 8) else 14);
                flow.x = flow.left;
                flow.y += gap;
                flow.line_height = if (compact) 20 else 22;
                const language: syntax.Language = if (std.mem.startsWith(u8, block.info, "zig")) .zig else if (std.mem.startsWith(u8, block.info, "rust") or std.mem.startsWith(u8, block.info, "rs")) .rust else if (std.mem.startsWith(u8, block.info, "json")) .json else .plain;
                var lexical: syntax.State = .{};
                var iterator = std.mem.splitScalar(u8, block.content, '\n');
                while (iterator.next()) |raw| {
                    if (raw.len == 0 and iterator.index == null) break;
                    const line = std.mem.trimEnd(u8, raw, "\r");
                    const lexed = try syntax.lex(a, line, language, lexical);
                    lexical = lexed.state;
                    var at: usize = 0;
                    for (lexed.spans) |span| {
                        if (span.start > at) try flow.textRun(line[at..span.start], .{ .size = if (compact) 13 else 14, .mono = true, .color = colors.text }, block.source.start, null, false, true);
                        const color = tokenColor(span.kind, colors);
                        try flow.textRun(line[span.start..span.end], .{ .size = if (compact) 13 else 14, .mono = true, .color = color }, block.source.start, null, false, true);
                        at = span.end;
                    }
                    if (at < line.len) try flow.textRun(line[at..], .{ .size = if (compact) 13 else 14, .mono = true, .color = colors.text }, block.source.start, null, false, true);
                    flow.newline();
                }
                flow.y += 8;
                try flow.fills.append(a, .{ .bounds = .{ .x = inset, .y = block_top, .width = @max(1, flow.right - inset), .height = flow.y - block_top }, .color = colors.code, .radius = ui.controls.metrics.control_radius });
                flow.y += if (compact) @as(f32, 8) else 14;
            },
            .table => {
                const table = block.table.?;
                var columns: usize = table.alignments.len;
                for (table.rows) |row| columns = @max(columns, row.cells.len);
                const cell_width = @max(40, (flow.right - inset) / @as(f32, @floatFromInt(@max(1, columns))));
                for (table.rows, 0..) |row, ri| {
                    const top = flow.y;
                    var bottom = top + 34;
                    for (row.cells, 0..) |cell, ci| {
                        flow.left = 38 + @as(f32, @floatFromInt(ci)) * cell_width;
                        flow.x = flow.left;
                        flow.right = flow.left + cell_width - 16;
                        flow.y = top + 7;
                        try flow.inlineSpans(cell.content, if (ri == 0) 15.5 else 14.5);
                        flow.newline();
                        bottom = @max(bottom, flow.y + 5);
                    }
                    flow.left = inset;
                    flow.right = @max(64, width - 30);
                    flow.y = bottom;
                    if (ri == 0) try flow.fills.append(a, .{ .bounds = .{ .x = inset, .y = top, .width = @max(1, flow.right - inset), .height = bottom - top }, .color = colors.code });
                    try flow.fills.append(a, .{ .bounds = .{ .x = inset, .y = bottom, .width = @max(1, flow.right - inset), .height = 1 }, .color = colors.border });
                    for (0..columns + 1) |ci| try flow.fills.append(a, .{ .bounds = .{ .x = 30 + @as(f32, @floatFromInt(ci)) * cell_width, .y = top, .width = 1, .height = bottom - top }, .color = colors.border });
                }
                flow.y += 18;
            },
        }
        try flow.hits.append(a, .{ .bounds = .{ .x = 20, .y = block_top, .width = @max(1, width - 40), .height = @max(1, flow.y - block_top) }, .source = block.source.start });
    }
    return .{ .texts = flow.texts.items, .fills = flow.fills.items, .images = flow.images.items, .hits = flow.hits.items, .height = flow.y + if (compact) @as(f32, 8) else 20 };
}

fn tokenColor(kind: syntax.Kind, colors: Colors) ui.Color {
    return colors.tokens[@backingInt(kind)];
}
const Canvas = struct {
    retained_layout: ?*Layout = null,
    generation: *Generation,
    scroll: f32,
    follow_end: bool,
    colors: Colors,
    compact: bool,
    pub const LayoutState = ui.layout.Measurer;
    pub const PrepaintState = Prepared;
    pub fn requestLayout(_: *Canvas, cx: *ui.LayoutCx) !ui.LayoutResult(LayoutState) {
        return .{ .size = cx.available, .state = cx.measurer };
    }
    pub fn prepaint(self: *Canvas, cx: *ui.PrepaintCx, bounds: ui.Rect, metrics: *LayoutState) !Prepared {
        _ = cx;
        const cached = (try cachedLayout(self.generation, metrics.*, bounds.width, self.colors, self.compact)).retain();
        if (self.retained_layout) |old| old.release();
        self.retained_layout = cached;
        self.scroll = if (self.follow_end) @max(0, cached.prepared.height - bounds.height) else std.math.clamp(self.scroll, 0, @max(0, cached.prepared.height - bounds.height));
        return cached.prepared;
    }
    pub fn paint(self: *Canvas, cx: *ui.PaintCx, bounds: ui.Rect, _: *LayoutState, prepared: *Prepared) !void {
        try cx.painter.fillRect(.{ .bounds = bounds, .color = self.colors.background });
        try cx.painter.pushClip(bounds);
        defer cx.painter.popClip();
        for (prepared.fills) |fill| if (onScreen(fill.bounds, bounds.height, self.scroll)) try cx.painter.fillRect(.{ .bounds = translated(fill.bounds, bounds, self.scroll), .color = fill.color, .radius = fill.radius });
        for (prepared.images) |image| if (onScreen(image.bounds, bounds.height, self.scroll)) try cx.painter.drawImage(image.image, translated(image.bounds, bounds, self.scroll), .contain);
        for (prepared.texts) |item| if (onScreen(item.bounds, bounds.height, self.scroll)) try cx.painter.drawText(.{ .bounds = translated(item.bounds, bounds, self.scroll), .text = item.text, .style = item.style });
        if (prepared.height > bounds.height and bounds.height > 0) {
            const height = @max(24, bounds.height * bounds.height / prepared.height);
            const y = bounds.y + (bounds.height - height) * self.scroll / @max(1, prepared.height - bounds.height);
            try cx.painter.fillRect(.{ .bounds = .{ .x = bounds.x + bounds.width - 7, .y = y, .width = 4, .height = height }, .color = self.colors.muted, .radius = 2 });
        }
    }
    pub fn deinit(self: *Canvas) void {
        if (self.retained_layout) |cached| cached.release();
        self.generation.release();
    }
};
fn translated(rect: ui.Rect, viewport: ui.Rect, scroll: f32) ui.Rect {
    var result = rect;
    result.x += viewport.x;
    result.y += viewport.y - scroll;
    return result;
}

fn contains(rect: ui.Rect, point: ui.Point) bool {
    return point.x >= rect.x and point.y >= rect.y and point.x < rect.x + rect.width and point.y < rect.y + rect.height;
}

fn loadImage(a: std.mem.Allocator, bytes: []const u8) anyerror!Image {
    return Image.load(a, bytes);
}

fn onScreen(rect: ui.Rect, height: f32, scroll: f32) bool {
    return rect.y + rect.height > scroll and rect.y < scroll + height;
}
