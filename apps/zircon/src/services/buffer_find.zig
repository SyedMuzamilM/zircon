//! Revision-bound buffer search. Matching and regex expansion run in the worker.
const std = @import("std");
const zircon_editor = @import("zircon_editor");
const text = @import("zircon_text");
const ui = @import("zircon_ui");
const ws = @import("zircon_workspace");
const actions = @import("../actions.zig");
const commands = @import("../commands.zig");
const shell = @import("../shell.zig");
const host = @import("extension_host.zig");
const Shell = shell.Shell;
pub const Model = struct {
    visible: bool = false,
    replace: bool = false,
    pane: u8 = 0,
    document: ?ws.DocumentId = null,
    case_sensitive: bool = false,
    whole_word: bool = false,
    regex: bool = false,
    backward: bool = false,
    generation: u64 = 0,
    revision: ?u64 = null,
    waiting: bool = false,
    busy: bool = false,
    changed_at: i96 = 0,
    focus: u64 = 0,
    focus_replacement: bool = false,
    queued: ?commands.Command = null,
    result: ?std.json.Parsed(host.SearchResult) = null,
    error_text: []u8 = &.{},
    pub fn deinit(self: *Model, a: std.mem.Allocator) void {
        if (self.result) |*r| r.deinit();
        a.free(self.error_text);
    }
};
pub fn open(self: *Shell, cx: *ui.Context(Shell), replace: bool) !void {
    const current = try actions.active(self);
    if (target(self)) |previous| {
        previous.editor.search_visible = false;
    } else |_| {}
    self.find.visible = true;
    self.find.replace = replace;
    self.find.pane = if (self.active_pane == .secondary) 1 else 0;
    self.find.document = current.id;
    self.find.backward = self.vim_find_pending and current.editor.vim.search_backward;
    current.editor.search_visible = true;
    self.find.focus +%= 1;
    self.find.focus_replacement = false;
    self.overlay = .none;
    self.panel = .editor;
    try changed(self, cx);
}

pub fn bind(self: *Shell, cx: *ui.Context(Shell), document: ws.DocumentId, pane: u8) !void {
    if (self.find.document != null and std.meta.eql(self.find.document.?, document) and self.find.pane == pane) return;
    if (target(self)) |previous| {
        previous.editor.search_visible = false;
    } else |_| {}
    self.find.document = document;
    self.find.pane = pane;
    self.find.revision = null;
    self.find.queued = null;
    try changed(self, cx);
}

pub fn changed(self: *Shell, cx: *ui.Context(Shell)) !void {
    if (target(self)) |current| {
        current.editor.search_visible = false;
    } else |_| {}
    self.find.generation +%= 1;
    self.find.waiting = true;
    self.find.changed_at = std.Io.Clock.awake.now(self.workspace.io).toNanoseconds();
    if (self.find.result) |*old| old.deinit();
    self.find.result = null;
    self.allocator.free(self.find.error_text);
    self.find.error_text = &.{};
    cx.notify();
}

pub fn close(self: *Shell, cx: *ui.Context(Shell)) void {
    if (target(self)) |current| {
        current.editor.search_visible = false;
    } else |_| {}
    self.find.visible = false;
    self.find.waiting = false;
    self.vim_find_pending = false;
    self.find.queued = null;
    self.editor_focus_request +%= 1;
    cx.notify();
}

fn target(self: *Shell) !struct { id: ws.DocumentId, editor: *zircon_editor.Editor } {
    if (self.find.document) |id| {
        if (self.find.pane == 1) {
            if (self.secondary) |*pane| if (std.meta.eql(pane.document, id)) return .{ .id = id, .editor = &pane.editor };
        } else for (self.tabs.items) |*tab| if (std.meta.eql(tab.document, id)) return .{ .id = id, .editor = &tab.editor };
    }
    return error.FindDocumentClosed;
}

pub fn poll(self: *Shell, cx: *ui.Context(Shell)) !void {
    if (!self.find.visible and !self.find.waiting) return;
    if (self.find.visible and self.find.pane == 0 and self.tabs.items.len > 0) try bind(self, cx, self.tabs.items[self.active].document, 0);
    const current = target(self) catch {
        close(self, cx);
        return;
    };
    const record = try self.workspace.getConst(current.id);
    if (self.find.revision != record.doc.revision() and !self.find.busy and !self.find.waiting) try changed(self, cx);
    if (!self.find.waiting or self.find.busy or std.Io.Clock.awake.now(self.workspace.io).toNanoseconds() - self.find.changed_at < 60 * std.time.ns_per_ms) return;
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var query: []u8 = &.{};
    var replacement: []u8 = &.{};
    try cx.read(self.fields.?.buffer_search.query, ui.controls.TextInput.copy, .{ a, &query });
    try cx.read(self.fields.?.buffer_search.replacement, ui.controls.TextInput.copy, .{ a, &replacement });
    var snapshot = record.doc.snapshot();
    defer snapshot.deinit();
    if (snapshot.byteLen() > 8 * 1024 * 1024) {
        self.allocator.free(self.find.error_text);
        self.find.error_text = try self.allocator.dupe(u8, "Buffer search supports documents up to 8 MiB.");
        self.find.revision = snapshot.revision();
        self.find.waiting = false;
        self.find.queued = null;
        cx.notify();
        return;
    }
    if (query.len == 0) {
        self.allocator.free(current.editor.search_ranges);
        current.editor.search_ranges = &.{};
        current.editor.search_revision = snapshot.revision();
        if (self.find.result) |*old| old.deinit();
        self.find.result = null;
        self.find.revision = snapshot.revision();
        self.find.waiting = false;
        self.find.queued = null;
        cx.notify();
        return;
    }
    const source = try snapshot.copy(a, .{ .start = 0, .end = snapshot.byteLen() });
    const input = try std.json.Stringify.valueAlloc(a, .{ .source = source, .query = query, .replacement = replacement, .regex = self.find.regex, .case_sensitive = self.find.case_sensitive, .whole_word = self.find.whole_word }, .{});
    try host.start(self, cx, &.{"search"}, input, .{ .generation = self.find.generation, .document = current.id, .revision = snapshot.revision() }, completed);
    self.find.revision = snapshot.revision();
    self.find.waiting = false;
    self.find.busy = true;
}

fn completed(self: *Shell, cx: *ui.Context(Shell), raw: anyerror!*host.Box) !void {
    self.find.busy = false;
    const box = raw catch |err| {
        self.allocator.free(self.find.error_text);
        self.find.error_text = try self.allocator.dupe(u8, @errorName(err));
        cx.notify();
        return;
    };
    var value = box.take();
    defer value.deinit();
    if (value.stamp.generation != self.find.generation or !std.meta.eql(value.stamp.document, self.find.document)) return;
    const current = target(self) catch return;
    const record = try self.workspace.getConst(current.id);
    if (value.stamp.revision != record.doc.revision()) {
        try changed(self, cx);
        return;
    }
    self.allocator.free(self.find.error_text);
    self.find.error_text = &.{};
    if (!value.success or value.search == null) {
        self.find.error_text = try self.allocator.dupe(u8, std.mem.trim(u8, value.stderr, "\r\n"));
        cx.notify();
        return;
    }
    var snapshot = record.doc.snapshot();
    defer snapshot.deinit();
    const matches = value.search.?.value.matches;
    const ranges = try self.allocator.alloc(text.Range, matches.len);
    errdefer self.allocator.free(ranges);
    for (matches, ranges) |match, *range| {
        range.* = .{ .start = match.start, .end = match.end };
        try snapshot.validateRange(range.*);
    }
    var query: []u8 = &.{};
    try cx.read(self.fields.?.buffer_search.query, ui.controls.TextInput.copy, .{ self.allocator, &query });
    self.allocator.free(current.editor.search_query);
    current.editor.search_query = query;
    current.editor.search_case_sensitive = self.find.case_sensitive;
    self.allocator.free(current.editor.search_ranges);
    current.editor.search_ranges = ranges;
    current.editor.search_revision = snapshot.revision();
    current.editor.search_visible = self.find.visible;
    if (self.find.result) |*old| old.deinit();
    self.find.result = value.search;
    value.search = null;
    if (self.find.queued) |which| {
        self.find.queued = null;
        try action(self, cx, which);
        if (self.vim_find_pending) close(self, cx);
    }
    cx.notify();
}

pub fn action(self: *Shell, cx: *ui.Context(Shell), which: commands.Command) !void {
    if (self.find.busy or self.find.waiting) {
        self.find.queued = which;
        return;
    }
    const current = try target(self);
    const record = try self.workspace.get(current.id);
    if (self.find.revision != record.doc.revision()) {
        try changed(self, cx);
        self.find.queued = which;
        return;
    }
    if (self.find.error_text.len > 0) return;
    const result = self.find.result orelse return;
    if (result.value.matches.len == 0) return;
    const selected = current.editor.primary().range();
    if (which == .replace_all and result.value.truncated) return error.TooManySearchMatches;
    if (which == .replace_all or which == .replace_one) {
        var edits: std.ArrayList(text.Edit) = .empty;
        defer edits.deinit(self.allocator);
        for (result.value.matches) |match| if (which == .replace_all or (match.start == selected.start and match.end == selected.end)) {
            try edits.append(self.allocator, .{ .range = .{ .start = match.start, .end = match.end }, .text = match.replacement });
            if (which == .replace_one) break;
        };
        if (edits.items.len > 0) {
            var outcome = try current.editor.applyEdits(&record.doc, edits.items, 0);
            try actions.applyOutcome(self, cx, current.id, self.find.pane, &outcome, .project_edit);
            try changed(self, cx);
            return;
        }
    }
    const backwards = which == .find_previous;
    const modal = current.editor.vim.enabled and current.editor.vim.mode != .insert;
    var index: usize = if (backwards) result.value.matches.len - 1 else 0;
    if (backwards) {
        var i = result.value.matches.len;
        while (i > 0) {
            i -= 1;
            if (result.value.matches[i].start < selected.start) {
                index = i;
                break;
            }
        }
    } else for (result.value.matches, 0..) |match, i| if (match.start >= selected.end and !(match.start == selected.start and (modal or match.end == selected.end))) {
        index = i;
        break;
    };
    const found = result.value.matches[index];
    var snapshot = record.doc.snapshot();
    defer snapshot.deinit();
    try current.editor.setSelection(snapshot, .{ .start = found.start, .end = if (modal) found.start else found.end });
    if (modal) {
        current.editor.vim.cursor = found.start;
        current.editor.vim.mode = .normal;
    }
    try actions.prepareEditor(self, cx, current.editor, snapshot, if (self.find.pane == 1) "secondary-editor" else "primary-editor");
    cx.notify();
}
