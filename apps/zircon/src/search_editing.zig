//! Project-search excerpts retain live source identities and independent pane editors.
const std = @import("std");
const builtin = @import("builtin");
const editing = @import("zircon_editor");
const multibuffer = @import("zircon_multibuffer");
const search = @import("zircon_search");
const text = @import("zircon_text");
const ui = @import("zircon_ui");
const ws = @import("zircon_workspace");
const actions = @import("actions.zig");
const commands = @import("commands.zig");
const autoscroll = @import("excerpt_autoscroll.zig");
const multibuffer_editing = @import("multibuffer_editing.zig");
const panes = @import("panes.zig");
const search_selection = @import("search_selection.zig");
const git = @import("services/git.zig");
const language = @import("services/language.zig");
const search_service = @import("services/search.zig");
const symbol_hover = @import("services/symbol_hover.zig");
const shell = @import("shell.zig");
const context_menu = @import("views/editor_context_menu.zig");
const overlays = @import("views/overlays.zig");
const Shell = shell.Shell;
const a = if (builtin.single_threaded) std.heap.page_allocator else std.heap.smp_allocator;
const Sources = editing.SourceEditors(ws.DocumentId);
pub const header_height = 36;
const Position = struct {
    rows: usize = 0,
    padding: usize = 0,

    fn pixels(self: Position, line_height: f32) f32 {
        return @as(f32, @floatFromInt(self.rows)) * line_height + @as(f32, @floatFromInt(self.padding));
    }
};
const File = struct {
    document: ?ws.DocumentId = null,
    excerpts: []Excerpt = &.{},
    matches: []text.Range = &.{},
    revision: u64 = 0,
    rows: usize = 0,
    fallback_excerpts: usize = 0,
    stale: bool = false,
    top: Position = .{},
};
pub const Model = struct {
    projection: multibuffer.MultiBuffer = .init(a),
    files: std.ArrayList(File) = .empty,
    extent: Position = .{},
    panes: [2]Sources = @splat(.{}),
    active_excerpt: [2]?multibuffer.ExcerptId = @splat(null),
    scroll: [2]ui.controls.Scroll = @splat(.{}),
    viewport: [2]?f32 = @splat(null),
    generation: u64 = 0,
    selection: [2]?multibuffer.Selection = @splat(null),
    dragging: [2]bool = @splat(false),
    autoscroll: [2]?autoscroll.Drag = @splat(null),

    pub fn deinit(self: *Model) void {
        for (self.files.items) |file| {
            a.free(file.excerpts);
            a.free(file.matches);
        }
        self.files.deinit(a);
        self.projection.deinit();
        for (&self.panes) |*pane| pane.deinit();
        self.* = .{};
    }
    pub fn remove(self: *Model, id: ws.DocumentId) void {
        self.selection = @splat(null);
        self.dragging = @splat(false);
        self.autoscroll = @splat(null);
        self.projection.removeSource(id) catch {};
        for (&self.panes) |*pane| pane.remove(id);
        var removed = false;
        for (self.files.items) |*file| if (file.document != null and std.meta.eql(file.document.?, id)) {
            file.document = null;
            removed = true;
        };
        if (removed) self.updateLayout();
    }

    fn updateLayout(self: *Model) void {
        self.extent = .{};
        for (self.files.items) |*file| {
            file.top = self.extent;
            self.extent.padding += header_height;
            if (file.document != null and !file.stale) {
                self.extent.rows += file.rows;
                self.extent.padding += file.excerpts.len * 12;
            } else {
                self.extent.padding += file.fallback_excerpts * 40;
            }
        }
    }

    fn markStale(self: *Model, id: ws.DocumentId) void {
        for (self.files.items) |*file| if (std.meta.eql(file.document, @as(?ws.DocumentId, id))) {
            file.stale = true;
        };
        self.updateLayout();
    }

    pub fn contentHeight(self: *const Model, line_height: f32) f32 {
        return self.extent.pixels(line_height);
    }

    pub fn firstVisible(self: *const Model, top: f32, line_height: f32) struct { group: usize, y: f32 } {
        if (self.files.items.len == 0) return .{ .group = 0, .y = 0 };
        var lo: usize = 0;
        var hi = self.files.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.files.items[mid].top.pixels(line_height) <= top) lo = mid + 1 else hi = mid;
        }
        const group = lo -| 1;
        return .{ .group = group, .y = self.files.items[group].top.pixels(line_height) };
    }
};
pub const Target = struct { group: u32, excerpt: u32, generation: u64, revision: u64, first_row: usize, pane: u8 };
pub const Excerpt = struct { document: ws.DocumentId, id: multibuffer.ExcerptId, range: text.Range, first_row: usize, rows: usize };

pub fn install(self: *Shell, results: search.Results) !void {
    var next: Model = .{ .generation = results.generation };
    errdefer next.deinit();
    try next.files.resize(a, results.groups.len);
    @memset(next.files.items, .{});
    for (results.groups, next.files.items) |group, *file| {
        file.fallback_excerpts = group.excerpts.len;
        const id = resolve(self, group) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => continue,
        };
        var snapshot = try self.workspace.snapshot(id);
        defer snapshot.deinit();
        try next.projection.addSource(id, snapshot);
        const ranges = try a.alloc(text.Range, group.excerpts.len);
        defer a.free(ranges);
        for (group.excerpts, ranges) |item, *range| range.* = item.source_range;
        try next.projection.setExcerpts(id, ranges);
        file.document = id;
        file.excerpts = try a.alloc(Excerpt, group.excerpts.len);
        file.revision = snapshot.revision();
        var index: usize = 0;
        for (next.projection.excerpts.items) |item| if (std.meta.eql(item.value.source, id)) {
            file.excerpts[index] = try describe(snapshot, id, item.value.id, item.value.source_range);
            file.rows += file.excerpts[index].rows;
            index += 1;
        };
        file.matches = try a.alloc(text.Range, group.matches.len);
        for (group.matches, file.matches) |match, *range| range.* = match.range;
        for (&next.panes) |*pane| {
            var editor = try editing.Editor.init(a);
            errdefer editor.deinit();
            const record = try self.workspace.getConst(id);
            self.configureEditor(&editor, record.path orelse group.title);
            editor.show_scrollbars = false;
            editor.show_fold_controls = false;
            editor.show_git_gutters = false;
            editor.soft_wrap = .none;
            editor.search_visible = true;
            editor.search_query = try a.dupe(u8, self.search.query);
            editor.synchronize(snapshot);
            try pane.append(.{ .document = id, .editor = editor });
        }
    }
    next.updateLayout();
    releaseUnusedSources(self, &self.search.editing, &next);
    self.search.editing.deinit();
    self.search.editing = next;
}

fn resolve(self: *Shell, group: search.Group) !ws.DocumentId {
    switch (group.source) {
        .buffer => |buffer| {
            for (self.workspace.slots.items, 0..) |slot, index| if (slot.record) |record| {
                const id: ws.DocumentId = .{ .workspace = self.workspace.identity, .slot = @intCast(index), .generation = slot.generation };
                if (search_service.id(id) != buffer.document_id) continue;
                var snapshot = record.doc.snapshot();
                defer snapshot.deinit();
                if (!group.isCurrentBuffer(buffer.document_id, snapshot)) return error.StaleSearchResult;
                return id;
            };
            return error.StaleSearchResult;
        },
        .disk => |disk| {
            if (!try group.isCurrentDisk(self.workspace.io)) return error.StaleSearchResult;
            const id = try self.workspace.open(disk.path);
            const record = try self.workspace.getConst(id);
            if (record.dirty() or record.disk == null or !std.mem.eql(u8, &record.disk.?.digest, &disk.stamp.fingerprint)) return error.StaleSearchResult;
            return id;
        },
    }
}

fn describe(snapshot: text.Snapshot, document: ws.DocumentId, id: multibuffer.ExcerptId, range: text.Range) !Excerpt {
    const first = (try snapshot.pointAt(range.start)).line;
    const last = (try snapshot.pointAt(range.end)).line;
    const trailing_row = range.end == range.start or range.end == snapshot.byteLen() or (try snapshot.lineRange(last)).start != range.end;
    return .{ .document = document, .id = id, .range = range, .first_row = first, .rows = last - first + @as(usize, @intFromBool(trailing_row)) };
}

pub fn currentFile(self: *const Shell, group: usize) bool {
    if (group >= self.search.editing.files.items.len) return false;
    const file = self.search.editing.files.items[group];
    if (file.stale) return false;
    const record = self.workspace.getConst(file.document orelse return false) catch return false;
    return file.revision == record.doc.revision();
}

pub fn groupHeight(self: *const Shell, group: usize, line_height: f32, count: usize) f32 {
    if (!currentFile(self, group)) return @as(f32, @floatFromInt(count)) * 40;
    const file = self.search.editing.files.items[group];
    return @as(f32, @floatFromInt(file.rows)) * line_height + @as(f32, @floatFromInt(file.excerpts.len)) * 12;
}

pub fn excerpt(self: *const Shell, group: usize, index: usize) !?Excerpt {
    if (!currentFile(self, group)) return null;
    const file = self.search.editing.files.items[group];
    if (index >= file.excerpts.len) return null;
    return file.excerpts[index];
}

pub fn view(self: *Shell, pane: u8, id: ws.DocumentId) !*Sources.View {
    for (self.search.editing.panes[pane].views.items) |*item| if (std.meta.eql(item.document, id)) return item;
    return error.StaleSearchResult;
}

pub fn render(self: *const Shell, b: *ui.Ui, target: Target, source: Excerpt, first_row: usize, row_count: usize) !ui.Element {
    const stored = self.search.editing.panes[target.pane].find(source.document) orelse return error.StaleSearchResult;
    const record = try self.workspace.getConst(source.document);
    var state = stored.editor;
    state.edit_scope = source.range;
    state.scroll.offset = @as(f32, @floatFromInt(first_row)) * state.line_height;
    const pane_active = target.pane == @as(u8, if (self.active_pane == .secondary) 1 else 0);
    const active = pane_active and self.search.editing.active_excerpt[target.pane] != null and std.meta.eql(self.search.editing.active_excerpt[target.pane].?, source.id);
    state.highlight_active_line = active and self.editor_options.active_line;
    state.show_indent_guides = self.editor_options.indent_guides;
    var selected: [1]editing.Selection = undefined;
    if (search_selection.paint(self, target.pane, source)) |range| {
        selected[0] = .{ .anchor = range.start, .head = range.end };
        state.selections.items = .empty;
        state.selections.items.items = &selected;
        state.selections.items.capacity = 1;
    }
    var canvas = try state.renderExcerpt(&record.doc, b, row_count);
    if (active) canvas = try b.fluent().adopt(canvas).id(.{ .string = "search-result-editor" }).build();
    return b.fluent().div()
        .h(.{ .px = @as(f32, @floatFromInt(row_count)) * state.line_height })
        .shrink_0()
        .overflow_hidden()
        .children(.{canvas})
        .id(.{ .string = try std.fmt.allocPrint(b.allocator(), "search-excerpt:{d}:{d}:{d}", .{ target.pane, target.group, target.excerpt }) })
        .listeners(.{ .focusable = true, .on_input = b.onInputWith(onInput, target) })
        .request_focus(if (active) self.editor_focus_request else 0)
        .build();
}

fn onInput(self: *Shell, event: *ui.Event(ui.Input), cx: *ui.Context(Shell), target: Target) !void {
    handle(self, event, cx, target) catch |err| try self.reportError(err);
}

fn handle(self: *Shell, event: *ui.Event(ui.Input), cx: *ui.Context(Shell), target: Target) !void {
    if (event.data == .scroll) return;
    if (event.data == .pointer_down and event.data.pointer_down.button == .primary) return;
    if (event.data == .pointer_move and self.search.editing.dragging[target.pane]) return;
    if (target.generation != self.search.editing.generation) return;
    const source = try excerpt(self, target.group, target.excerpt) orelse return;
    const record = try self.workspace.get(source.document);
    if (try search_selection.input(self, cx, target.pane, event)) {
        event.preventDefault();
        event.stopPropagation();
        cx.notify();
        return;
    }
    if (try navigate(self, event, cx, target, source)) return;
    if (event.data == .pointer_down and target.revision != record.doc.revision()) return;
    const current = try view(self, target.pane, source.document);
    current.editor.edit_scope = source.range;
    // Visible excerpt elements retain a source row origin even when virtualized.
    if (event.data == .pointer_down) {
        self.active_pane = if (target.pane == 1 and self.secondary != null) .secondary else .primary;
        self.search.editing.panes[target.pane].active = source.document;
        self.search.editing.active_excerpt[target.pane] = source.id;
        _ = try actions.ensureTab(self, source.document);
        self.editor_focus_request +%= 1;
        event.focus();
    }
    current.editor.scroll.offset = @as(f32, @floatFromInt(target.first_row)) * current.editor.line_height;
    if (try context_menu.pointer(self, cx, &current.editor, &record.doc, source.document, target.pane, event)) return;
    if (try language.definitionPointer(self, cx, &current.editor, &record.doc, event)) return;
    try symbol_hover.pointer(self, cx, &current.editor, &record.doc, source.document, event);
    var outcome = current.editor.handle(&record.doc, event) catch |err| switch (err) {
        error.CrossExcerptEdit => editing.Outcome{ .handled = true },
        else => return err,
    };
    const edited = outcome.change != null or outcome.reset;
    if (outcome.handled) {
        if (!edited) for (current.editor.selections.items.items) |*selection| {
            selection.anchor = std.math.clamp(selection.anchor, source.range.start, source.range.end);
            selection.head = std.math.clamp(selection.head, source.range.start, source.range.end);
        };
        try actions.applyOutcome(self, cx, source.document, 3 + target.pane, &outcome, .typing);
        if (edited) {
            try git.edited(self, cx);
            if (language.completionTrigger(event.data)) language.request(self, cx) catch |err| switch (err) {
                error.NoLanguageServer, error.ServerNotReady, error.CompletionNotSupported => {},
                else => try self.reportError(err),
            };
        }
        if (edited or event.data == .key_down) try search_selection.sync(self, target.pane, source, event.data == .key_down and event.data.key_down.modifiers.shift);
        if (edited or event.data == .key_down) try reveal(self, cx, target, current.editor.primary().head);
        event.preventDefault();
        event.stopPropagation();
        cx.notify();
    }
}

/// Every workspace edit maps these source-backed ranges, including edits made
/// in ordinary tabs, splits, Git views, formatting and language actions.
pub fn changed(self: *Shell, id: ws.DocumentId, change: ?*const text.Change, origin_pane: u8) !void {
    const model = &self.search.editing;
    const revision = model.projection.sourceRevision(id) catch return;
    var snapshot = try self.workspace.snapshot(id);
    defer snapshot.deinit();
    if (revision == snapshot.revision()) return;
    errdefer model.markStale(id);
    var fallback: text.Change = undefined;
    const actual = change orelse blk: {
        var before: ?text.Snapshot = null;
        for (model.projection.sources.items) |source| if (std.meta.eql(source.id, id)) {
            before = source.snapshot;
            break;
        };
        fallback = try resetChange(before orelse return, snapshot);
        break :blk &fallback;
    };
    defer if (change == null) fallback.deinit();
    if (actual.before != revision) {
        model.markStale(id);
        return;
    }
    for (&model.selection) |*selected| if (selected.*) |*value| {
        for (model.projection.excerpts.items) |item| if (std.meta.eql(item.value.source, id)) {
            if (std.meta.eql(value.anchor.excerpt, item.value.id)) value.anchor.offset = actual.map(value.anchor.offset, .before);
            if (std.meta.eql(value.head.excerpt, item.value.id)) value.head.offset = actual.map(value.head.offset, .after);
        };
    };
    try model.projection.updateSource(id, actual, snapshot);
    for (model.files.items) |*file| if (file.document != null and std.meta.eql(file.document.?, id)) {
        file.rows = 0;
        for (file.excerpts) |*item| {
            const range: text.Range = .{ .start = actual.map(item.range.start, .before), .end = actual.map(item.range.end, .after) };
            item.* = try describe(snapshot, id, item.id, range);
            file.rows += item.rows;
        }
        file.revision = snapshot.revision();
        file.stale = false;
    };
    model.updateLayout();
    for (model.files.items) |*file| if (file.document != null and std.meta.eql(file.document.?, id)) for (file.matches) |*range| {
        range.start = actual.map(range.start, .before);
        range.end = actual.map(range.end, .after);
    };
    for (&model.panes, 0..) |*pane, index| for (pane.views.items) |*item| if (std.meta.eql(item.document, id)) {
        if (origin_pane != 3 + index) item.editor.mapChange(actual);
        item.editor.synchronize(snapshot);
    };
}

fn resetChange(before: text.Snapshot, after: text.Snapshot) !text.Change {
    const old = try before.copy(a, .{ .start = 0, .end = before.byteLen() });
    defer a.free(old);
    const new = try after.copy(a, .{ .start = 0, .end = after.byteLen() });
    defer a.free(new);
    var first: usize = 0;
    while (first < @min(old.len, new.len) and old[first] == new[first]) : (first += 1) {}
    while (!before.isBoundary(first) or !after.isBoundary(first)) first -= 1;
    var old_end = old.len;
    var new_end = new.len;
    while (old_end > first and new_end > first and old[old_end - 1] == new[new_end - 1]) {
        old_end -= 1;
        new_end -= 1;
    }
    while (!before.isBoundary(old_end) or !after.isBoundary(new_end)) {
        old_end += 1;
        new_end += 1;
    }
    const mappings = try a.alloc(text.Mapping, 1);
    mappings[0] = .{ .range = .{ .start = first, .end = old_end }, .inserted = new_end - first };
    return .{ .allocator = a, .before = before.revision(), .after = after.revision(), .state = after.stateId(), .mappings = mappings };
}

pub fn command(self: *Shell, cx: *ui.Context(Shell), which: commands.Command) !bool {
    const pane: u8 = if (self.active_pane == .secondary) 1 else 0;
    if (self.currentTool(pane) != .search or self.search.editing.projection.sources.items.len == 0) return false;
    if (which == .save) {
        for (self.search.editing.projection.sources.items) |source| {
            const record = try self.workspace.getConst(source.id);
            if (!record.dirty()) continue;
            _ = try actions.ensureTab(self, source.id);
            if (record.path == null) {
                self.active = try actions.ensureTab(self, source.id);
                self.active_pane = .primary;
                self.panel = .editor;
                try overlays.show(self, cx, .save_as);
                return true;
            }
            try self.workspace.save(source.id, null);
        }
        if (self.git.repository) try git.edited(self, cx);
        cx.notify();
        return true;
    }
    var projected_event: ui.Event(ui.Input) = .{ .data = .{ .key_down = .{ .key = .unknown } }, ._surface = (try cx.app.window(self.window.?)).surface };
    if (try search_selection.command(self, cx, pane, which, &projected_event)) return true;
    if (which != .undo and which != .redo and which != .select_all and which != .delete_line and which != .toggle_comment and which != .cut and which != .copy and which != .paste) return false;
    const current = self.search.editing.panes[pane].current() orelse return true;
    const id = current.document;
    if (which == .undo or which == .redo) if (try multibuffer_editing.travel(self, cx, id, if (which == .undo) .undo else .redo)) return true;
    const state = try view(self, pane, id);
    const record = try self.workspace.get(id);
    var outcome: editing.Outcome = undefined;
    switch (which) {
        .cut, .copy, .paste => {
            var event: ui.Event(ui.Input) = .{ .data = .{ .key_down = .{ .key = if (which == .cut) .x else if (which == .copy) .c else .v, .modifiers = .{ .command = true } } }, ._surface = (try cx.app.window(self.window.?)).surface };
            outcome = try state.editor.handle(&record.doc, &event);
        },
        else => outcome = try state.editor.execute(&record.doc, switch (which) {
            .undo => .undo,
            .redo => .redo,
            .select_all => .select_all,
            .delete_line => .delete_line,
            .toggle_comment => .toggle_comment,
            else => unreachable,
        }),
    }
    try actions.applyOutcome(self, cx, id, 3 + pane, &outcome, if (which == .undo) .undo else if (which == .redo) .redo else .project_edit);
    cx.notify();
    return true;
}

pub fn activate(self: *Shell, cx: *ui.Context(Shell), group: usize, match_index: usize) !bool {
    if (group >= self.search.editing.files.items.len) return false;
    const file = self.search.editing.files.items[group];
    const id = file.document orelse return false;
    if (try self.search.editing.projection.sourceRevision(id) != (try self.workspace.getConst(id)).doc.revision()) return error.StaleSearchResult;
    if (match_index >= file.matches.len) return false;
    const index = try actions.ensureTab(self, id);
    if (self.active_pane == .secondary and self.secondary != null) {
        try panes.selectSecondary(self, index);
        self.secondary_tool = null;
    } else {
        self.active = index;
        self.tabs.items[index].primary = true;
        self.panel = .editor;
    }
    const current = try actions.active(self);
    var snapshot = try self.workspace.snapshot(id);
    defer snapshot.deinit();
    try current.editor.setSelection(snapshot, file.matches[match_index]);
    current.editor.reveal(snapshot);
    self.editor_focus_request +%= 1;
    cx.notify();
    return true;
}

pub fn reveal(self: *Shell, cx: *ui.Context(Shell), target: Target, cursor: usize) !void {
    const results = self.search.results orelse return;
    const lh = self.editor_options.font_size * self.editor_options.line_height;
    var y: f32 = 0;
    for (results.groups, 0..) |group, group_index| {
        y += header_height;
        for (group.excerpts, 0..) |_, index| {
            const source = try excerpt(self, group_index, index) orelse {
                y += 40;
                continue;
            };
            if (group_index == target.group and index == target.excerpt) {
                var snapshot = try self.workspace.snapshot(source.document);
                defer snapshot.deinit();
                const row = (try snapshot.pointAt(cursor)).line;
                const top = y + @as(f32, @floatFromInt(row -| source.first_row)) * lh;
                const viewport = self.search.editing.viewport[target.pane] orelse @max(1, (try cx.app.window(self.window.?)).surface.?.size().height - 170);
                const scroll = &self.search.editing.scroll[target.pane];
                if (top < scroll.offset) scroll.offset = top;
                if (top + lh > scroll.offset + viewport) scroll.offset = @max(0, top + lh - viewport);
                return;
            }
            y += @as(f32, @floatFromInt(source.rows)) * lh + 12;
        }
    }
}

fn navigate(self: *Shell, event: *ui.Event(ui.Input), cx: *ui.Context(Shell), target: Target, source: Excerpt) !bool {
    if (event.data != .key_down) return false;
    const key = event.data.key_down;
    if (key.modifiers.command or key.modifiers.control or key.modifiers.alt) return false;
    if (key.key != .up and key.key != .down and key.key != .left and key.key != .right) return false;
    const current = try view(self, target.pane, source.document);
    var snapshot = try self.workspace.snapshot(source.document);
    defer snapshot.deinit();
    const position = try snapshot.pointAt(current.editor.primary().head);
    const forward = key.key == .down or key.key == .right;
    const boundary = switch (key.key) {
        .up => position.line <= source.first_row,
        .down => position.line + 1 >= source.first_row + source.rows,
        .left => current.editor.primary().head <= source.range.start,
        .right => current.editor.primary().head >= source.range.end,
        else => unreachable,
    };
    if (!boundary) return false;
    if (key.modifiers.shift and self.search.editing.selection[target.pane] == null) try search_selection.sync(self, target.pane, source, false);
    const model = &self.search.editing;
    const index = for (model.projection.excerpts.items, 0..) |item, index| {
        if (std.meta.eql(item.value.id, source.id)) break index;
    } else return false;
    const next_index = if (forward) index + 1 else index -| 1;
    if (next_index == index or next_index >= model.projection.excerpts.items.len) return false;
    const next = model.projection.excerpts.items[next_index].value;
    const destination = try view(self, target.pane, next.source);
    var after = try self.workspace.snapshot(next.source);
    defer after.deinit();
    const row = if (forward) (try after.pointAt(next.source_range.start)).line else (try after.pointAt(next.source_range.end)).line;
    const line = try after.lineRange(row);
    var offset = switch (key.key) {
        .left => next.source_range.end,
        .right => next.source_range.start,
        else => line.start + @min(position.byte_column, line.end - line.start),
    };
    offset = std.math.clamp(offset, next.source_range.start, next.source_range.end);
    while (!after.isBoundary(offset)) offset -= 1;
    try destination.editor.setSelection(after, .{ .start = offset, .end = offset });
    destination.editor.edit_scope = next.source_range;
    model.panes[target.pane].active = next.source;
    model.active_excerpt[target.pane] = next.id;
    const head: multibuffer.Position = .{ .excerpt = next.id, .offset = offset };
    model.selection[target.pane] = .{ .anchor = if (key.modifiers.shift and model.selection[target.pane] != null) model.selection[target.pane].?.anchor else head, .head = head };
    _ = try actions.ensureTab(self, next.source);
    for (model.files.items, 0..) |file, group| for (file.excerpts, 0..) |id, index_in_file| if (std.meta.eql(id.id, next.id)) {
        try reveal(self, cx, .{ .group = @intCast(group), .excerpt = @intCast(index_in_file), .generation = model.generation, .revision = after.revision(), .first_row = row, .pane = target.pane }, offset);
    };
    self.editor_focus_request +%= 1;
    event.preventDefault();
    event.stopPropagation();
    cx.notify();
    return true;
}

/// Search may load clean files before a tab exists. Drop those roots once a
/// later result set no longer needs them; tab-backed and Git sources stay owned.
fn releaseUnusedSources(self: *Shell, previous: *const Model, next: *const Model) void {
    for (previous.projection.sources.items) |source| {
        if ((next.projection.sourceRevision(source.id) catch null) != null) continue;
        const tab_owned = for (self.tabs.items) |tab| {
            if (std.meta.eql(tab.document, source.id)) break true;
        } else false;
        if (tab_owned or self.git.editing.find(source.id) != null) continue;
        if (self.git.editable) |projection| if ((projection.sourceRevision(source.id) catch null) != null) continue;
        _ = self.workspace.close(source.id, .if_clean) catch false;
    }
}

pub fn clear(self: *Shell) void {
    const empty: Model = .{};
    releaseUnusedSources(self, &self.search.editing, &empty);
    self.search.editing.deinit();
}
