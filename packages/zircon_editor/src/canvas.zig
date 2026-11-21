//! Editor custom element. It owns an immutable document root, copies visible
//! lines into frame storage, and publishes a bounded surrounding-text excerpt.
const std = @import("std");
const text = @import("zircon_text");
const ui = @import("zircon_ui");
const annotations = @import("annotations.zig");
const blame_view = @import("blame_view.zig");
const brackets = @import("brackets.zig");
const cursor_module = @import("cursor.zig");
const display = @import("display.zig");
const editor = @import("editor.zig");
const element = @import("element.zig");
const folding = @import("folding.zig");
const indent_guides = @import("indent_guides.zig");
const profile_module = @import("profile.zig");
const selection = @import("selections.zig");
const syntax = @import("syntax.zig");
const theme_module = @import("theme.zig");
const wrap = @import("wrap.zig");
const line_limit = 64 * 1024;
const number_right_inset: f32 = 36;
const scrollbar_width: f32 = 12;
pub fn gutterWidth(lines: usize, font_size: f32) f32 {
    var digits: usize = 1;
    var remaining = lines;
    while (remaining >= 10) : (remaining /= 10) digits += 1;
    return @max(76, @as(f32, @floatFromInt(digits)) * font_size * 0.62 + 46);
}
pub fn render(state: *const editor.Editor, document: *const text.Document, b: *ui.Ui, row_limit: usize, show_unfocused_caret: bool) !ui.Element {
    var snapshot = document.snapshot();
    errdefer snapshot.deinit();
    const selections = try b.allocator().dupe(selection.Selection, state.selections.items.items);
    const first = state.rowAt(state.scroll.offset, snapshot.revision());
    const start = first -| 2;
    const projected_gaps = state.projected() and (state.wrap_cache.excerpt_ranges != null or state.wrap_cache.folding.collapsed.items.len != 0);
    const viewport_rows: usize = @intFromFloat(@min(@as(f32, @floatFromInt(row_limit)), @ceil(b.viewport().height / state.line_height)));
    const viewport_limit = if (projected_gaps) row_limit else @min(row_limit, @max(128, viewport_rows +| 8));
    const count = @min(viewport_limit, snapshot.lineCount() - @min(start, snapshot.lineCount()));
    const states = try b.allocator().alloc(?syntax.State, count);
    for (states, 0..) |*item, i| item.* = state.syntax_cache.state(snapshot, start + i);
    const changes = try b.allocator().dupe(annotations.GitChange, state.visibleChanges(snapshot.revision()));
    var expanded_changes: std.ArrayList(annotations.GitChange) = .empty;
    for (changes) |*change| if (change.expanded) {
        change.removed = try b.allocator().dupe(u8, change.removed);
        try expanded_changes.append(b.allocator(), change.*);
    };
    const grammar_spans: ?[]const syntax.Span = if (state.grammar_revision == snapshot.revision()) blk: {
        const begin = try snapshot.lineStart(@min(start, snapshot.lineCount() - 1));
        const end = (try snapshot.lineRange(@min(start + count, snapshot.lineCount() - 1))).end;
        var lo: usize = 0;
        var limit = state.grammar_spans.len;
        while (lo < limit) {
            const mid = lo + (limit - lo) / 2;
            if (state.grammar_spans[mid].end <= begin) lo = mid + 1 else limit = mid;
        }
        var hi = lo;
        while (hi < state.grammar_spans.len and state.grammar_spans[hi].start < end) hi += 1;
        break :blk try b.allocator().dupe(syntax.Span, state.grammar_spans[lo..hi]);
    } else null;
    const vim_command_mode = state.vim.enabled and state.vim.mode != .insert;
    const value: Canvas = .{
        .snapshot = snapshot,
        .grammar_spans = grammar_spans,
        .wrap_cache = state.wrap_cache,
        .soft_wrap = state.projected(),
        .wrap_enabled = state.soft_wrap != .none,
        .vim_command_mode = vim_command_mode,
        .cursor = if (state.vim.enabled and state.vim.visual()) state.vim.cursor else if (selections.len > 0) selections[0].head else 0,
        .profile = if (state.language_profile) |profile| try profile.copy(b.allocator()) else null,
        .blame = if (state.inline_blame != null and state.inline_blame.?.revision == snapshot.revision()) try state.inline_blame.?.copy(b.allocator()) else null,
        .git_changes = changes,
        .expanded_changes = expanded_changes.items,
        .blame_message_scroll = state.blame_message_scroll,
        .theme = state.theme,
        .show_line_numbers = state.show_line_numbers,
        .gutter_hovered = state.gutter_hovered,
        .indent_guides = state.show_indent_guides,
        .highlight_active_line = state.highlight_active_line,
        .fold_controls = state.show_fold_controls,
        .selections = selections,
        .scroll = state.scroll.offset,
        .horizontal = if (state.soft_wrap == .none) state.horizontal else 0,
        .font_size = state.font_size,
        .line_height = state.line_height,
        .tab_width = state.tab_width,
        .language = state.language,
        .states = states,
        .state_start = start,
        .marked = state.marked,
        .search_ranges = if (state.search_visible and state.search_revision == snapshot.revision()) try b.allocator().dupe(text.Range, state.search_ranges) else &.{},
        .external_search = state.search_revision == snapshot.revision(),
        .search = if (state.search_visible or state.search_revision == null) try b.allocator().dupe(u8, state.search_query) else "",
        .cursor_config = state.cursor_config,
        .cursor_runtime = state.cursor_runtime,
        .cursor_shape = if (!state.vim.enabled) state.cursor_config.shape else if (vim_command_mode) .block else .bar,
        .show_unfocused_caret = show_unfocused_caret,
    };
    var canvas = value;
    canvas.diagnostics = if (state.diagnostics_revision == snapshot.revision()) state.diagnostics else &.{};
    if (state.selections.items.items.len > 0) {
        canvas.scope = try state.bracket_cache.get(state, snapshot, b.allocator());
        canvas.scope_guide = state.bracket_cache.guide;
    }
    canvas.show_scrollbars = state.show_scrollbars;
    _ = canvas.wrap_cache.retain();
    errdefer canvas.wrap_cache.release();
    _ = canvas.cursor_runtime.retain();
    errdefer canvas.cursor_runtime.release();
    return b.custom(Canvas, canvas, .{ .flex_grow = 1, .overflow = .hidden, .background = state.theme.background });
}
const RenderLine = struct {
    row: usize,
    range: text.Range,
    original: []const u8,
    display: display.Line,
    spans: []const syntax.Span,
    y: f32,
    height: f32,
    text_size: ui.Size,
    oversized: bool = false,
    segment: ?wrap.Row = null,
};
const Caret = struct {
    offset: usize,
    row: usize,
    visual_row: ?usize,

    fn onLine(self: Caret, line: RenderLine, visual_row: usize) bool {
        return self.row == line.row and (line.segment == null or self.visual_row == visual_row);
    }
};
const CaretPaint = struct {
    layout: cursor_module.Layout,
    start: usize,
    end: usize,
    left: f32,
};
const Prepared = struct {
    lines: []RenderLine,
    first_visual: usize,
    carets: []Caret,
    gutter: f32,
    content_width: f32,
    cursor_shape: ?cursor_module.Shape,
    primary_caret: ?CaretPaint,
    moving_caret: ?ui.Rect,
};
const Canvas = struct {
    scope: ?brackets.Scope = null,
    scope_guide: ?brackets.Scope = null,
    show_scrollbars: bool = true,
    snapshot: text.Snapshot,
    grammar_spans: ?[]const syntax.Span,
    wrap_cache: *wrap.Cache,
    soft_wrap: bool,
    wrap_enabled: bool,
    vim_command_mode: bool,
    cursor: usize,
    cursor_config: cursor_module.Config,
    cursor_runtime: *cursor_module.Runtime,
    cursor_shape: cursor_module.Shape,
    show_unfocused_caret: bool,
    profile: ?profile_module.Profile,
    blame: ?annotations.Blame,
    git_changes: []const annotations.GitChange,
    expanded_changes: []const annotations.GitChange,
    blame_message_scroll: f32,
    theme: theme_module.Theme,
    show_line_numbers: bool,
    gutter_hovered: bool,
    indent_guides: bool,
    highlight_active_line: bool,
    fold_controls: bool,
    selections: []const selection.Selection,
    scroll: f32,
    horizontal: f32,
    font_size: f32,
    line_height: f32,
    tab_width: usize,
    language: syntax.Language,
    states: []const ?syntax.State,
    state_start: usize,
    marked: ?text.Range,
    search: []const u8,
    search_ranges: []const text.Range,
    external_search: bool,
    diagnostics: []const element.Mark = &.{},
    pub const LayoutState = ui.layout.Measurer;
    pub const PrepaintState = Prepared;
    pub fn deinit(self: *Canvas) void {
        self.wrap_cache.release();
        self.cursor_runtime.release();
        self.snapshot.deinit();
    }
    pub fn requestLayout(_: *Canvas, cx: *ui.LayoutCx) !ui.LayoutResult(LayoutState) {
        return .{ .size = cx.available, .state = cx.measurer };
    }
    pub fn prepaint(self: *Canvas, cx: *ui.PrepaintCx, bounds: ui.Rect, metrics: *LayoutState) !Prepared {
        const gutter: f32 = if (self.show_line_numbers) gutterWidth(self.snapshot.lineCount(), self.font_size) else 20;
        if (self.soft_wrap) try self.wrap_cache.ensure(self.snapshot, if (self.wrap_enabled) bounds.width - gutter - 12 else 1e12, self.font_size, self.tab_width, metrics.*);
        const first = if (self.soft_wrap) self.wrap_cache.visualAt(self.scroll, self.line_height, self.expanded_changes) else annotations.sourceRow(self.scroll, self.line_height, self.expanded_changes);
        const total_rows = if (self.soft_wrap) self.wrap_cache.rowCount() else self.snapshot.lineCount();
        const visible = try ui.controls.visibleRows(total_rows, self.line_height, @as(f32, @floatFromInt(first)) * self.line_height, bounds.height, 2);
        const lines = try cx.allocator.alloc(RenderLine, visible.end - visible.start);
        var caret: ui.Rect = .{ .x = bounds.x + gutter - self.horizontal, .y = bounds.y, .width = 1.5, .height = @max(1, self.line_height - 4) };
        const style: ui.TextStyle = .{ .size = self.font_size, .mono = true };
        const needs_text_input = cx.focused and !self.vim_command_mode and self.selections.len > 0;
        const carets = try cx.allocator.alloc(Caret, if (self.vim_command_mode) @min(self.selections.len, 1) else self.selections.len);
        for (carets, self.selections[0..carets.len]) |*entry, item| {
            const offset = if (self.vim_command_mode) self.cursor else item.head;
            entry.* = .{
                .offset = offset,
                .row = (try self.snapshot.pointAt(offset)).line,
                .visual_row = if (self.soft_wrap) self.wrap_cache.atOffset(offset) else null,
            };
        }
        var cursor_shape = if (cx.focused or self.show_unfocused_caret) self.cursor_config.shapeForFocus(self.cursor_shape, cx.focused) else null;
        var primary_caret: ?CaretPaint = null;
        var moving_caret: ?ui.Rect = null;
        var content_width: f32 = 0;
        var stream = if (!self.soft_wrap and lines.len > 0) try self.snapshot.linesFrom(visible.start) else null;
        for (lines, 0..) |*line, i| {
            const visual_row = visible.start + i;
            const segment: ?wrap.Row = if (self.soft_wrap) self.wrap_cache.rowAt(visual_row) else null;
            const row = if (segment) |part| part.line else visual_row;
            const display_row = visual_row + annotations.insertedRows(self.expanded_changes, row);
            const y = bounds.y + @as(f32, @floatFromInt(display_row)) * self.line_height - self.scroll;
            if (i > 0 and lines[i - 1].row == row) {
                line.* = lines[i - 1];
                line.y = y;
                line.segment = segment;
            } else {
                const streamed = if (stream) |*iter| iter.next().? else null;
                const range = if (streamed) |item| item.range else try self.snapshot.lineRange(row);
                const oversized = range.end - range.start > line_limit;
                const borrowed = if (streamed) |item| item.bytes else null;
                const original = if (oversized)
                    "[Line exceeds the 64 KiB display limit]"
                else
                    borrowed orelse try self.snapshot.copy(cx.allocator, range);
                const expanded = try display.Line.build(cx.allocator, original, self.tab_width);
                const size = try metrics.text(metrics.context, expanded.bytes, style);
                content_width = @max(content_width, size.width);
                const initial = if (row >= self.state_start and row - self.state_start < self.states.len) self.states[row - self.state_start] else null;
                const lexed = if (self.profile != null and !oversized) try profile_module.lex(cx.allocator, original, self.profile.?, initial orelse .{}) else try syntax.lex(cx.allocator, original, if (initial != null and !oversized) self.language else .plain, initial orelse .{});
                var spans = lexed.spans;
                if (!oversized) if (self.grammar_spans) |external| {
                    var classified: std.ArrayList(syntax.Span) = .empty;
                    var classified_end: usize = 0;
                    var lex_cursor: usize = 0;
                    var first_span: usize = 0;
                    var span_limit = external.len;
                    while (first_span < span_limit) {
                        const mid = first_span + (span_limit - first_span) / 2;
                        if (external[mid].end <= range.start) first_span = mid + 1 else span_limit = mid;
                    }
                    for (external[first_span..]) |span| {
                        if (span.start >= range.end) break;
                        const begin = @max(span.start, range.start) - range.start;
                        const end = @min(span.end, range.end) - range.start;
                        if (end <= begin) continue;
                        try appendLexical(cx.allocator, &classified, lexed.spans, &lex_cursor, classified_end, begin);
                        try classified.append(cx.allocator, .{ .start = begin, .end = end, .kind = span.kind });
                        classified_end = end;
                    }
                    try appendLexical(cx.allocator, &classified, lexed.spans, &lex_cursor, classified_end, original.len);
                    spans = classified.items;
                };
                line.* = .{ .row = row, .range = range, .original = original, .display = expanded, .spans = spans, .y = y, .oversized = oversized, .height = self.line_height, .text_size = size, .segment = segment };
            }
            if ((needs_text_input or cursor_shape != null) and carets.len != 0 and carets[0].onLine(line.*, visual_row)) {
                const x = bounds.x + gutter - self.horizontal - (if (segment) |part| part.x else 0);
                const offset = @min(carets[0].offset - line.range.start, line.original.len);
                const left = if (line.oversized) 0 else line.display.caret(metrics.*, style, offset);
                caret.x = x + left;
                caret.y = line.y + 3;
                if (!line.oversized) if (cursor_shape) |shape| {
                    primary_caret = try self.caretPaint(line.*, metrics.*, style, x, carets[0].offset, offset, left, shape);
                };
            }
        }
        if (cx.focused and self.selections.len > 0) {
            const runtime = self.cursor_runtime;
            const moved = runtime.sync(
                .{ .head = carets[0].offset, .revision = self.snapshot.revision(), .shape = self.cursor_shape },
                .{ .bounds = bounds, .scroll = self.scroll, .horizontal = self.horizontal, .line_height = self.line_height, .gutter = gutter },
                cx.time,
                cx.retained_focus,
            );
            if (self.cursor_config.smooth and self.marked == null) {
                const target = if (primary_caret) |primary| primary.layout.rect() else null;
                const onscreen = if (target) |rect| rect.intersection(bounds) else ui.Rect{};
                moving_caret = runtime.glide(if (onscreen.width > 0 and onscreen.height > 0) target else null, cx.time, self.cursor_config.smooth_duration, moved);
                if (moving_caret != null) try cx.requestFrameAfter(1.0 / 120.0);
            } else {
                runtime.smooth = null;
            }
            if (primary_caret != null or carets.len > 1) if (runtime.blink.nextWake(self.cursor_config, cx.time, self.cursor_shape)) |delay| {
                try cx.requestFrameAfter(delay);
            };
            if (moving_caret == null and !runtime.blink.visible(self.cursor_config, cx.time, self.cursor_shape)) cursor_shape = null;
            if (needs_text_input) {
                const selected = self.selections[0].range();
                var begin = selected.start -| 2048;
                var end = @min(self.snapshot.byteLen(), selected.end +| 2048);
                if (self.marked) |marked| {
                    begin = @min(begin, marked.start);
                    end = @max(end, marked.end);
                }
                while (!self.snapshot.isBoundary(begin)) begin -= 1;
                while (!self.snapshot.isBoundary(end)) end += 1;
                const surrounding = try self.snapshot.copy(cx.allocator, .{ .start = begin, .end = end });
                try cx.setTextInput(.{ .text = surrounding, .revision = self.snapshot.revision(), .selection = .{ .start = selected.start - begin, .end = selected.end - begin }, .marked = if (self.marked) |marked| .{ .start = marked.start - begin, .end = marked.end - begin } else null, .caret = caret, .base_byte = begin, .base_utf16 = try self.snapshot.utf16Offset(begin) });
            }
        }
        return .{ .lines = lines, .first_visual = visible.start, .carets = carets, .gutter = gutter, .content_width = content_width, .cursor_shape = cursor_shape, .primary_caret = primary_caret, .moving_caret = moving_caret };
    }
    fn caretPaint(self: *const Canvas, line: RenderLine, metrics: LayoutState, style: ui.TextStyle, x: f32, head: usize, offset: usize, left: f32, shape: cursor_module.Shape) !CaretPaint {
        const next = if (shape == .bar) offset else @min(line.original.len, (try self.snapshot.nextGraphemeBoundary(head)) - line.range.start);
        const right = if (next == offset or line.original[offset] == '\t')
            left
        else
            line.display.caret(metrics, style, next);
        const width = if (left == right) self.font_size * 0.6 else @abs(right - left);
        return .{
            .layout = .{
                .shape = shape,
                .cell = .{ .x = x + @min(left, right), .y = line.y, .width = width, .height = line.height },
                .color = self.cursor_config.color orelse self.theme.caret,
                .config = self.cursor_config,
            },
            .start = offset,
            .end = next,
            .left = left,
        };
    }
    pub fn paint(self: *Canvas, cx: *ui.PaintCx, bounds: ui.Rect, metrics: *LayoutState, prepared: *Prepared) !void {
        try cx.painter.fillRect(.{ .bounds = bounds, .color = self.theme.background });
        try cx.painter.pushClip(bounds);
        defer cx.painter.popClip();
        const style: ui.TextStyle = .{ .size = self.font_size, .mono = true, .color = self.theme.foreground };
        const primary_row = if (prepared.carets.len > 0) prepared.carets[0].row else 0;
        const advance = @max(1, metrics.caret(" ", style, 1));
        const step = @as(f32, @floatFromInt(self.tab_width));
        const has_folds = self.wrap_cache.folding.collapsed.items.len != 0;
        for (prepared.lines, prepared.first_visual..) |line, visual_row| {
            if (self.highlight_active_line and cx.focused and line.row == primary_row) try cx.painter.fillRect(.{ .bounds = .{ .x = bounds.x, .y = line.y, .width = bounds.width, .height = self.line_height }, .color = self.theme.active_line });
            for (self.expanded_changes) |change| if (line.row >= change.start and line.row < change.end) {
                var fill = self.theme.git_added;
                fill.a = 0.15;
                try cx.painter.fillRect(.{ .bounds = .{ .x = bounds.x, .y = line.y, .width = bounds.width, .height = self.line_height }, .color = fill });
            };
            const x = bounds.x + prepared.gutter - self.horizontal - (if (line.segment) |part| part.x else 0);
            const segment_start = if (line.segment) |part| part.start - line.range.start else 0;
            const segment_end = if (line.segment) |part| @min(line.original.len, part.end - line.range.start) else line.original.len;
            try cx.painter.pushClip(.{ .x = bounds.x + prepared.gutter - 4, .y = bounds.y, .width = @max(0, bounds.width - prepared.gutter + 4), .height = bounds.height });
            for (self.expanded_changes) |change| if (line.row >= change.start and line.row < change.end and change.old_count == change.end - change.start and !line.oversized) {
                const columns = annotations.changedColumns(annotations.lineAt(change.removed, line.row - change.start), line.original);
                var fill = self.theme.git_added;
                fill.a = 0.25;
                try highlightColumns(cx, metrics.*, line, style, x, @max(columns.start, segment_start), @min(columns.end, segment_end), fill);
            };
            if (!line.oversized) {
                if (cx.focused) if (self.scope) |scope| {
                    var fill = self.theme.foreground;
                    fill.a = 0.16;
                    for ([_]usize{ scope.open, scope.close }) |at| {
                        if (at < line.range.start or at >= line.range.end) continue;
                        const column = at - line.range.start;
                        if (column >= segment_start and column < segment_end) try highlightColumns(cx, metrics.*, line, style, x, column, column + 1, fill);
                    }
                };
                const cells = if (!self.indent_guides) 0 else if (indent_guides.blank(line.original)) try indent_guides.blankCells(self.snapshot, line.row, self.tab_width, cx.painter.allocator) else indent_guides.cells(line.original, self.tab_width);
                var guide = @as(usize, @intFromFloat(@floor(self.horizontal / advance / step))) * self.tab_width;
                const last_guide = @min(cells, @as(usize, @intFromFloat(@ceil((self.horizontal + bounds.width) / advance))));
                while (self.indent_guides and guide < last_guide) : (guide += self.tab_width) {
                    var tint = self.theme.line_number;
                    tint.a = 0.2;
                    if (cx.focused) if (self.scope_guide) |scope| {
                        if (guide == scope.indent and line.row > scope.first_row and line.row < scope.last_row) {
                            tint = if (self.theme.background.r + self.theme.background.g + self.theme.background.b < 1.5) ui.Color.rgb(0xffffff) else self.theme.foreground;
                            tint.a = 0.45;
                        }
                    };
                    const guide_x = @as(f32, @floatFromInt(guide)) * advance;
                    try cx.painter.fillRect(.{ .bounds = .{ .x = bounds.x + prepared.gutter - self.horizontal + guide_x, .y = line.y, .width = 1, .height = self.line_height }, .color = tint });
                }
                var match_start: usize = 0;
                var match_end = self.search_ranges.len;
                while (match_start < match_end) {
                    const mid = match_start + (match_end - match_start) / 2;
                    if (self.search_ranges[mid].end < line.range.start) match_start = mid + 1 else match_end = mid;
                }
                for (self.search_ranges[match_start..]) |range| {
                    if (range.start > line.range.end) break;
                    if (range.end < line.range.start or range.start > line.range.end) continue;
                    const begin = @max(range.start -| line.range.start, segment_start);
                    const end = @min(range.end -| line.range.start, segment_end);
                    if (begin > end) continue;
                    const left = line.display.caret(metrics.*, style, begin);
                    const right = line.display.caret(metrics.*, style, end);
                    var fill = self.theme.caret;
                    fill.a = 0.18;
                    try cx.painter.fillRect(.{ .bounds = .{ .x = x + left, .y = line.y, .width = @max(2, right - left), .height = self.line_height }, .color = fill });
                }
                for (self.selections) |item| {
                    const range = item.range();
                    if (range.start == range.end or range.end <= line.range.start or range.start > line.range.end) continue;
                    const start = @max(@max(range.start, line.range.start) - line.range.start, segment_start);
                    const end = @min(@min(range.end, line.range.end) - line.range.start, segment_end);
                    if (end < start) continue;
                    const left = line.display.caret(metrics.*, style, start);
                    const right = line.display.caret(metrics.*, style, end) + if (range.end > line.range.end and segment_end == line.original.len) self.font_size * 0.6 else @as(f32, 0);
                    try cx.painter.fillRect(.{ .bounds = .{ .x = x + @min(left, right), .y = line.y, .width = @abs(right - left), .height = self.line_height }, .color = if (cx.focused) self.theme.selection else self.theme.inactive_selection });
                }
                if (!self.external_search and self.search.len > 0 and std.mem.indexOfScalar(u8, self.search, '\n') == null) {
                    var at: usize = 0;
                    while (std.mem.indexOfPos(u8, line.original, at, self.search)) |found| {
                        if (found + self.search.len <= segment_start or found >= segment_end) {
                            at = found + self.search.len;
                            continue;
                        }
                        const left = line.display.caret(metrics.*, style, found);
                        const right = line.display.caret(metrics.*, style, found + self.search.len);
                        try cx.painter.fillRect(.{ .bounds = .{ .x = x + @min(left, right), .y = line.y + 1, .width = @abs(right - left), .height = self.line_height - 2 }, .color = .{ .r = 0.6, .g = 0.43, .b = 0.14, .a = 0.3 } });
                        at = found + self.search.len;
                    }
                }
            }
            try paintRuns(cx, line, self.theme, metrics.*, style, x, segment_start, segment_end);
            try paintDiagnostics(self, cx, metrics.*, line, style, x, segment_start, segment_end);
            if (self.marked) |marked| if (!line.oversized and marked.start <= line.range.end and marked.end >= line.range.start) {
                const left = line.display.caret(metrics.*, style, @max(marked.start, line.range.start) - line.range.start);
                const right = line.display.caret(metrics.*, style, @min(marked.end, line.range.end) - line.range.start);
                try cx.painter.fillRect(.{ .bounds = .{ .x = x + @min(left, right), .y = line.y + self.line_height - 3, .width = @max(1, @abs(right - left)), .height = 1 }, .color = self.theme.caret });
            };
            if (!line.oversized) if (prepared.cursor_shape) |shape| for (prepared.carets, 0..) |entry, index| {
                if (!entry.onLine(line, visual_row)) continue;
                if (index == 0 and prepared.moving_caret != null) continue;
                const visual = if (index == 0) prepared.primary_caret.? else blk: {
                    const offset = @min(entry.offset - line.range.start, line.original.len);
                    const left = line.display.caret(metrics.*, style, offset);
                    break :blk try self.caretPaint(line, metrics.*, style, x, entry.offset, offset, left, shape);
                };
                const rect = visual.layout.rect();
                try visual.layout.paint(cx.painter, rect);
                if (shape == .block and visual.end > visual.start) {
                    try cx.painter.pushClip(rect);
                    defer cx.painter.popClip();
                    var inverted = self.theme;
                    inverted.tokens[@backingInt(syntax.Kind.plain)] = self.theme.background;
                    const carets = metrics.lineCarets(line.display.bytes, style);
                    _ = try drawRun(cx, line, inverted, carets, style, x, visual.start, visual.end, .plain, visual.left);
                }
            };
            cx.painter.popClip();

            if (self.fold_controls and self.show_line_numbers and (line.segment == null or line.segment.?.first)) {
                const folded = self.wrap_cache.folding.isCollapsed(line.range.start);
                if (folded or (self.gutter_hovered and folding.isHeader(self.snapshot, line.row, self.tab_width))) try ui.controls.icons.draw(if (folded) .chevron_right else .chevron_down, cx.painter, .{ .x = bounds.x + prepared.gutter - 24, .y = line.y + (self.line_height - 12) / 2, .width = 12, .height = 12 }, self.theme.line_number);
                if (folded) try cx.painter.drawText(.{ .bounds = .{ .x = bounds.x + prepared.gutter - self.horizontal + line.text_size.width + 10, .y = line.y + 2, .width = 20, .height = self.line_height }, .text = "…", .style = .{ .size = self.font_size, .color = self.theme.line_number } });
            }
            if (self.show_line_numbers and (line.segment == null or line.segment.?.first)) {
                var digits: [24]u8 = undefined;
                const number = std.fmt.bufPrint(&digits, "{d}", .{line.row + 1}) catch unreachable;
                const number_style: ui.TextStyle = .{ .size = self.font_size - 1, .mono = true };
                const number_width = metrics.text(metrics.context, number, number_style) catch ui.Size{ .width = 20, .height = 16 };
                try cx.painter.drawText(.{ .bounds = .{ .x = bounds.x + prepared.gutter - number_right_inset - number_width.width, .y = line.y + (self.line_height - number_width.height) / 2, .width = number_width.width + 2, .height = number_width.height }, .text = number, .style = .{ .size = self.font_size - 1, .mono = true, .color = if (cx.focused and line.row == primary_row) self.theme.active_number else self.theme.line_number } });
            }
        }
        for (self.git_changes) |change| {
            if (has_folds and self.wrap_cache.folding.hidden(try self.snapshot.lineStart(@min(change.start, self.snapshot.lineCount() - 1)))) continue;
            if (change.expanded) try self.paintRemoved(cx, metrics.*, prepared.gutter, bounds, change);
            var marker = annotations.marker(change, self.expanded_changes, self.line_height, bounds, self.scroll);
            if (self.soft_wrap) {
                marker.y = bounds.y + self.wrap_cache.y(change.start, self.line_height, self.expanded_changes) - self.scroll - (if (change.expanded) @as(f32, @floatFromInt(change.old_count)) * self.line_height else 0);
                if (change.end > change.start) marker.height = self.wrap_cache.y(change.end, self.line_height, self.expanded_changes) - self.wrap_cache.y(change.start, self.line_height, self.expanded_changes) + (if (change.expanded) @as(f32, @floatFromInt(change.old_count)) * self.line_height else 0);
            }
            try cx.painter.fillRect(.{ .bounds = marker, .color = switch (change.kind) {
                .added => self.theme.git_added,
                .modified => self.theme.git_modified,
                .deleted => self.theme.git_deleted,
            } });
        }
        if (self.blame) |blame| if (try blame_view.layout(cx.painter.allocator, self.snapshot, blame, self.expanded_changes, .{ .source_y = if (self.soft_wrap) self.wrap_cache.rowY(self.wrap_cache.rowStart(blame.line + 1) - 1, self.line_height, self.expanded_changes) else null, .source_x = if (self.soft_wrap) self.wrap_cache.rowAt(self.wrap_cache.rowStart(blame.line + 1) - 1).x else 0, .font = self.font_size, .line_height = self.line_height, .gutter = prepared.gutter, .horizontal = self.horizontal, .scroll = self.scroll, .tab_width = self.tab_width }, metrics.*, bounds)) |geometry| {
            try blame_view.paint(cx, geometry, blame, self.theme, self.font_size, self.blame_message_scroll);
        };
        if (prepared.moving_caret) |rect| {
            try cx.painter.pushClip(.{ .x = bounds.x + prepared.gutter - 4, .y = bounds.y, .width = @max(0, bounds.width - prepared.gutter + 4), .height = bounds.height });
            defer cx.painter.popClip();
            try prepared.primary_caret.?.layout.paint(cx.painter, rect);
        }
        if (!self.show_scrollbars) return;
        const available = @max(1, bounds.width - prepared.gutter - 12);
        const content_width = @max(prepared.content_width, self.horizontal + available);
        if (!self.soft_wrap and (prepared.content_width > available or self.horizontal > 0)) {
            const thumb = @max(24, available * available / @max(1, content_width));
            const offset = (available - thumb) * self.horizontal / @max(1, content_width - available);
            try cx.painter.fillRect(.{ .bounds = .{ .x = bounds.x + prepared.gutter + offset, .y = bounds.y + bounds.height - 7, .width = @min(available, thumb), .height = 4 }, .radius = 2, .color = self.theme.scrollbar });
        }
        const content = if (self.soft_wrap) self.wrap_cache.y(self.snapshot.lineCount(), self.line_height, self.expanded_changes) else annotations.rowY(self.snapshot.lineCount(), self.line_height, self.expanded_changes);
        const track: ui.Rect = .{ .x = bounds.x + bounds.width - scrollbar_width, .y = bounds.y, .width = scrollbar_width, .height = bounds.height };
        try cx.painter.fillRect(.{ .bounds = track, .color = self.theme.background });
        if (content > bounds.height and bounds.height > 0) {
            const height = @min(track.height, @max(24, track.height * track.height / content));
            const y = track.y + (track.height - height) * std.math.clamp(self.scroll / @max(1, content - track.height), 0, 1);
            try cx.painter.fillRect(.{ .bounds = .{ .x = track.x, .y = y, .width = track.width, .height = height }, .color = self.theme.scrollbar });
        }
        if (track.height > 0) for (self.git_changes) |change| {
            const start = if (self.soft_wrap) self.wrap_cache.y(change.start, self.line_height, self.expanded_changes) else annotations.rowY(change.start, self.line_height, self.expanded_changes);
            const end = if (self.soft_wrap) self.wrap_cache.y(change.end, self.line_height, self.expanded_changes) else annotations.rowY(change.end, self.line_height, self.expanded_changes);
            const top = start - if (change.expanded) @as(f32, @floatFromInt(change.old_count)) * self.line_height else 0;
            const scale = track.height / @max(content, track.height);
            const height = @min(track.height, @max(3, (end - top) * scale));
            const y = track.y + std.math.clamp(top * scale, 0, track.height - height);
            try cx.painter.fillRect(.{ .bounds = .{ .x = track.x, .y = y, .width = 3, .height = height }, .color = switch (change.kind) {
                .added => self.theme.git_added,
                .modified => self.theme.git_modified,
                .deleted => self.theme.git_deleted,
            } });
        };
    }
    fn paintRemoved(self: *Canvas, cx: *ui.PaintCx, metrics: LayoutState, gutter: f32, bounds: ui.Rect, change: annotations.GitChange) !void {
        var rows = std.mem.splitScalar(u8, change.removed, '\n');
        var i: usize = 0;
        const top = bounds.y + (if (self.soft_wrap) self.wrap_cache.y(change.start, self.line_height, self.expanded_changes) - @as(f32, @floatFromInt(change.old_count)) * self.line_height else annotations.changeY(change, self.line_height, self.expanded_changes)) - self.scroll;
        while (i < change.old_count) : (i += 1) {
            const raw = rows.next() orelse "";
            const original = std.mem.trimEnd(u8, raw, "\r");
            const y = top + @as(f32, @floatFromInt(i)) * self.line_height;
            if (y + self.line_height < bounds.y or y >= bounds.y + bounds.height) continue;
            var fill = self.theme.git_deleted;
            fill.a = 0.16;
            try cx.painter.fillRect(.{ .bounds = .{ .x = bounds.x, .y = y, .width = bounds.width, .height = self.line_height }, .color = fill });
            const safe = if (original.len <= line_limit) original else "[Removed line exceeds the display limit]";
            const expanded = try display.Line.build(cx.painter.allocator, safe, self.tab_width);
            const lexed = try syntax.lex(cx.painter.allocator, safe, self.language, .{});
            const style: ui.TextStyle = .{ .size = self.font_size, .mono = true };
            const size = try metrics.text(metrics.context, expanded.bytes, style);
            const line: RenderLine = .{ .row = change.old_start + i, .range = .{ .start = 0, .end = safe.len }, .original = safe, .display = expanded, .spans = lexed.spans, .y = y, .height = self.line_height, .text_size = size };
            if (change.old_count == change.end - change.start and change.start + i < self.snapshot.lineCount()) {
                const current_range = try self.snapshot.lineRange(change.start + i);
                if (current_range.end - current_range.start <= line_limit) {
                    const current = try self.snapshot.copy(cx.painter.allocator, current_range);
                    const columns = annotations.changedColumns(current, safe);
                    try highlightColumns(cx, metrics, line, style, bounds.x + gutter - self.horizontal, columns.start, columns.end, self.theme.git_deleted);
                }
            }
            try cx.painter.pushClip(.{ .x = bounds.x + gutter, .y = bounds.y, .width = @max(0, bounds.width - gutter), .height = bounds.height });
            try paintRuns(cx, line, self.theme, metrics, style, bounds.x + gutter - self.horizontal, 0, safe.len);
            cx.painter.popClip();
            if (self.show_line_numbers) {
                var digits: [24]u8 = undefined;
                const number = std.fmt.bufPrint(&digits, "{d}", .{change.old_start + i + 1}) catch unreachable;
                const number_style: ui.TextStyle = .{ .size = self.font_size - 1, .mono = true, .color = self.theme.git_deleted };
                const measured = try metrics.text(metrics.context, number, number_style);
                try cx.painter.drawText(.{ .bounds = .{ .x = bounds.x + gutter - number_right_inset - measured.width, .y = y + (self.line_height - measured.height) / 2, .width = measured.width + 2, .height = measured.height }, .text = number, .style = number_style });
            }
        }
    }
};
fn appendLexical(a: std.mem.Allocator, output: *std.ArrayList(syntax.Span), spans: []const syntax.Span, cursor: *usize, begin: usize, end: usize) !void {
    if (begin >= end) return;
    while (cursor.* < spans.len) {
        const span = spans[cursor.*];
        if (span.start >= end) break;
        if (span.end > begin) try output.append(a, .{ .start = @max(begin, span.start), .end = @min(end, span.end), .kind = span.kind });
        if (span.end > end) break;
        cursor.* += 1;
    }
}
fn paintDiagnostics(self: *const Canvas, cx: *ui.PaintCx, metrics: ui.layout.Measurer, line: RenderLine, style: ui.TextStyle, x: f32, segment_start: usize, segment_end: usize) !void {
    if (line.oversized) return;
    for (self.diagnostics) |mark| {
        if (mark.range.start > line.range.end or mark.range.end < line.range.start) continue;
        const point = mark.range.start == mark.range.end;
        if (point and (mark.range.start < line.range.start or mark.range.start > line.range.end)) continue;
        if (!point and mark.range.end == line.range.start) continue;
        var begin = @max(mark.range.start, line.range.start) - line.range.start;
        var end = @min(@max(mark.range.end, mark.range.start), line.range.end) - line.range.start;
        if (point) {
            if (!element.containsPoint(begin, segment_start, segment_end, line.original.len)) continue;
            end = begin;
        }
        begin = @max(begin, segment_start);
        end = @min(if (point) begin else end, segment_end);
        if (begin > segment_end or (!point and begin >= end)) continue;
        const left = line.display.caret(metrics, style, begin);
        const right = if (point) left + @max(6, self.font_size * 0.55) else line.display.caret(metrics, style, end);
        if (right <= left) continue;
        try element.paint(cx, x + left, right - left, line.y, self.line_height, element.color(self.theme, mark.severity));
    }
}
fn paintRuns(cx: *ui.PaintCx, line: RenderLine, theme: theme_module.Theme, metrics: ui.layout.Measurer, style: ui.TextStyle, x: f32, start: usize, end: usize) !void {
    if (start >= end) return;
    const carets = metrics.lineCarets(line.display.bytes, style);
    var runs = syntax.Runs.init(line.spans, start, end);
    var left: ?f32 = null;
    while (runs.next()) |run| left = try drawRun(cx, line, theme, carets, style, x, run.start, run.end, run.kind, left);
}

fn drawRun(cx: *ui.PaintCx, line: RenderLine, theme: theme_module.Theme, carets: ui.layout.LineCarets, style: ui.TextStyle, x: f32, start: usize, end: usize, kind: syntax.Kind, previous: ?f32) !?f32 {
    const begin = line.display.displayOffset(start);
    const finish = line.display.displayOffset(end);
    const bytes = line.display.bytes[begin..finish];
    if (std.mem.allEqual(u8, bytes, ' ')) return null;
    const left = previous orelse carets.at(begin);
    const right = carets.at(finish);
    var actual = style;
    actual.color = theme.tokens[@backingInt(kind)];
    // Display text belongs to the frame arena or the canvas's retained snapshot.
    try cx.painter.drawTextBorrowed(.{
        .bounds = .{ .x = x + @min(left, right), .y = line.y + (line.height - line.text_size.height) / 2, .width = @max(1, @abs(right - left) + 2), .height = line.text_size.height },
        .text = bytes,
        .style = actual,
    });
    return right;
}

fn highlightColumns(cx: *ui.PaintCx, metrics: ui.layout.Measurer, line: RenderLine, style: ui.TextStyle, x: f32, start: usize, end: usize, color: ui.Color) !void {
    if (end <= start) return;
    const left = line.display.caret(metrics, style, start);
    const right = line.display.caret(metrics, style, end);
    try cx.painter.fillRect(.{ .bounds = .{ .x = x + left, .y = line.y, .width = @max(0, right - left), .height = line.height }, .color = color });
}
