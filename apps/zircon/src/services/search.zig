//! Captured buffers override disk search. Results carry source revisions and
//! generations; navigation refuses stale offsets instead of editing old text.
const std = @import("std");
const search = @import("zircon_search");
const text = @import("zircon_text");
const ui = @import("zircon_ui");
const zircon_workspace = @import("zircon_workspace");
const actions = @import("../actions.zig");
const panes = @import("../panes.zig");
const shell = @import("../shell.zig");
const handoff = @import("handoff.zig");
const Shell = shell.Shell;
const a = std.heap.page_allocator;
pub const Model = struct {
    results: ?search.Results = null,
    generation: u64 = 0,
    busy: bool = false,
    task: ?ui.tasks.Handle = null,
    scroll: ui.controls.Scroll = .{},
    pub fn deinit(self: *Model) void {
        if (self.results) |*result| result.deinit();
    }
};
const Result = struct {
    value: search.Results,
    pub fn deinit(self: *Result) void {
        self.value.deinit();
    }
};
const Box = handoff.Handoff(Result);
const Job = struct {
    pub const Output = *Box;
    io: std.Io,
    generation: u64,
    query: []u8,
    buffers: []search.Buffer,
    files: [][]const u8,
    pub fn run(self: *Job, cancel: *ui.tasks.Cancellation) !*Box {
        var result = try search.search(a, self.io, .{ .generation = self.generation, .query = .{ .text = self.query }, .open_buffers = self.buffers, .files = self.files }, .{ .context = cancel, .is_canceled = struct {
            fn check(raw: ?*anyopaque) bool {
                const c: *ui.tasks.Cancellation = @ptrCast(@alignCast(raw.?));
                return c.isCanceled();
            }
        }.check });
        errdefer result.deinit();
        return Box.create(a, .{ .value = result });
    }
    pub fn discard(_: *Job, result: *Box) void {
        result.destroy();
    }
    pub fn deinit(self: *Job, _: std.mem.Allocator) void {
        a.free(self.query);
        for (self.buffers) |*buffer| {
            var snapshot = buffer.snapshot;
            snapshot.deinit();
            if (buffer.path) |path| a.free(path);
            a.free(buffer.title);
        }
        a.free(self.buffers);
        for (self.files) |path| a.free(path);
        a.free(self.files);
    }
};
pub fn start(self: *Shell, cx: *ui.Context(Shell)) !void {
    var query: []u8 = undefined;
    try cx.read(self.fields.?.project_search.query, ui.controls.TextInput.copy, .{ a, &query });
    errdefer a.free(query);
    if (query.len == 0) {
        if (self.search.task) |task| cx.app.cancelTask(task) catch {};
        if (self.search.results) |*results| results.deinit();
        self.search.results = null;
        self.search.generation = std.math.add(u64, self.search.generation, 1) catch return error.SearchGenerationExhausted;
        self.search.task = null;
        self.search.busy = false;
        self.search.scroll.offset = 0;
        a.free(query);
        cx.notify();
        return;
    }
    var buffers: std.ArrayList(search.Buffer) = .empty;
    errdefer {
        for (buffers.items) |*buffer| {
            var snap = buffer.snapshot;
            snap.deinit();
            if (buffer.path) |path| a.free(path);
            a.free(buffer.title);
        }
        buffers.deinit(a);
    }
    for (self.tabs.items) |tab| {
        const record = try self.workspace.getConst(tab.document);
        var snapshot = record.doc.snapshot();
        errdefer snapshot.deinit();
        const path = if (record.path) |p| try a.dupe(u8, p) else null;
        errdefer if (path) |p| a.free(p);
        const title = try a.dupe(u8, record.title());
        errdefer a.free(title);
        try buffers.append(a, .{ .document_id = id(tab.document), .path = path, .title = title, .snapshot = snapshot });
    }
    const files = try a.alloc([]const u8, self.file_index.items.len);
    var owned: usize = 0;
    errdefer {
        for (files[0..owned]) |path| a.free(path);
        a.free(files);
    }
    for (self.file_index.items, 0..) |entry, i| {
        files[i] = try a.dupe(u8, entry.path);
        owned += 1;
    }
    const buffer_slice = try buffers.toOwnedSlice(a);
    errdefer {
        for (buffer_slice) |*buffer| {
            var snapshot = buffer.snapshot;
            snapshot.deinit();
            if (buffer.path) |path| a.free(path);
            a.free(buffer.title);
        }
        a.free(buffer_slice);
    }
    if (self.search.task) |task| cx.app.cancelTask(task) catch {};
    self.search.generation = std.math.add(u64, self.search.generation, 1) catch return error.SearchGenerationExhausted;
    errdefer {
        self.search.busy = false;
        self.search.task = null;
    }
    const task = try cx.spawn(Job, .{ .io = self.workspace.io, .generation = self.search.generation, .query = query, .buffers = buffer_slice, .files = files }, complete);
    self.search.task = task;
    self.search.busy = true;
    self.showTool(.search);
    self.tool_tabs.search = true;
    self.overlay = .none;
    self.search.scroll.offset = 0;
    cx.notify();
}

fn complete(self: *Shell, cx: *ui.Context(Shell), result: anyerror!*Box) !void {
    const box = result catch |err| {
        if (err != error.Canceled) {
            self.search.busy = false;
            try self.reportError(err);
            cx.notify();
        }
        return;
    };
    if (box.value.?.value.generation != self.search.generation) return;
    const value = box.take();
    if (self.search.results) |*old| old.deinit();
    self.search.results = value.value;
    self.search.busy = false;
    self.search.task = null;
    cx.notify();
}

pub fn id(document: zircon_workspace.DocumentId) u64 {
    return (@as(u64, document.generation) << 32) | document.slot;
}

pub fn activate(self: *Shell, cx: *ui.Context(Shell), group_index: usize, match_index: usize) !void {
    const results = self.search.results orelse return;
    if (group_index >= results.groups.len) return;
    const group = results.groups[group_index];
    if (match_index >= group.matches.len) return;
    switch (group.source) {
        .buffer => |source| {
            var found = false;
            for (self.tabs.items, 0..) |tab, index| if (id(tab.document) == source.document_id) {
                var snapshot = try self.workspace.snapshot(tab.document);
                defer snapshot.deinit();
                if (!group.isCurrentBuffer(source.document_id, snapshot)) return error.StaleSearchResult;
                if (self.active_pane == .secondary and self.secondary != null) try panes.selectSecondary(self, index) else {
                    self.active = index;
                    self.tabs.items[index].primary = true;
                }
                found = true;
                break;
            };
            if (!found) return error.StaleSearchResult;
        },
        .disk => |source| {
            if (!try group.isCurrentDisk(self.workspace.io)) return error.StaleSearchResult;
            // A file may have been opened and edited after this disk search.
            // Its unsaved document now owns the path and must not accept offsets
            // captured from an older disk version.
            for (self.tabs.items) |tab| {
                const record = try self.workspace.getConst(tab.document);
                if (record.path) |path| if (std.mem.eql(u8, path, source.path) and record.dirty()) return error.StaleSearchResult;
            }
            try self.openPath(source.path);
        },
    }
    const current = try actions.active(self);
    var snapshot = try self.workspace.snapshot(current.id);
    defer snapshot.deinit();
    try current.editor.setSelection(snapshot, group.matches[match_index].range);
    current.editor.reveal(snapshot);
    if (self.active_pane == .secondary and self.secondary != null) self.secondary_tool = null else self.panel = .editor;
    self.editor_focus_request +%= 1;
    cx.notify();
}
