//! One checkpoint writer owns the session store at a time. Snapshots are
//! retained and released on the UI thread; workers only read their contents.
const std = @import("std");
const editing = @import("zircon_editor");
const text = @import("zircon_text");
const ui = @import("zircon_ui");
const ws = @import("zircon_workspace");
const actions = @import("../actions.zig");
const git_editing = @import("../git_editing.zig");
const panes = @import("../panes.zig");
const shell = @import("../shell.zig");
const handoff = @import("handoff.zig");
const storage = ws.recovery;
const Shell = shell.Shell;
const a = std.heap.page_allocator;
const debounce = 0.25;
const max_delay = 1.0;

const Tracked = struct { runtime: ws.DocumentId, id: u64, state: ?u64 = null, content: ?storage.ContentRef = null };
pub const Close = union(enum) { document: struct { id: ws.DocumentId, state: u64 }, window_save, window_discard: u64 };
const Approval = struct { fingerprint: u64, discarded: bool };
pub const Model = struct {
    home: []u8,
    store: ?storage.Store,
    documents: std.ArrayList(Tracked) = .empty,
    next_id: u64 = 1,
    busy: bool = false,
    observed: ?u64 = null,
    committed: ?u64 = null,
    first_changed: f64 = 0,
    due: ?f64 = null,
    close: ?Close = null,
    approval: ?Approval = null,
    last_checkpoint: ?f64 = null,
    last_error: ?anyerror = null,
    pub fn deinit(self: *Model, allocator: std.mem.Allocator) void {
        if (self.store) |*store| store.deinit();
        self.documents.deinit(allocator);
        allocator.free(self.home);
    }
    fn track(self: *Model, allocator: std.mem.Allocator, id: ws.DocumentId) !*Tracked {
        for (self.documents.items) |*doc| if (std.meta.eql(doc.runtime, id)) return doc;
        if (self.next_id == std.math.maxInt(u64)) return error.RecoveryCapacityExceeded;
        try self.documents.append(allocator, .{ .runtime = id, .id = self.next_id });
        self.next_id += 1;
        return &self.documents.items[self.documents.items.len - 1];
    }
};

const Captured = struct { id: u64, state: u64, snapshot: ?text.Snapshot, content: ?storage.ContentRef };
const Capture = struct {
    arena: std.heap.ArenaAllocator,
    index: storage.Index,
    documents: []Captured,
    fingerprint: u64,
    fn deinit(self: *Capture) void {
        for (self.documents) |*doc| if (doc.snapshot) |*snapshot| snapshot.deinit();
        self.arena.deinit();
    }
};
const Operation = union(enum) { checkpoint, exclude: struct { id: ws.DocumentId, persistent: u64, state: u64 }, discard: u64 };
const Result = struct {
    store: storage.Store,
    operation: Operation,
    fingerprint: u64 = 0,
    documents: []const Captured = &.{},
    failure: ?anyerror = null,
    pub fn deinit(self: *Result) void {
        self.store.deinit();
    }
};
const Box = handoff.Handoff(Result);
const Job = struct {
    pub const Output = *Box;
    box: *Box,
    capture: ?Capture = null,
    pub fn run(self: *Job, cancel: *ui.tasks.Cancellation) !*Box {
        self.perform(cancel) catch |err| {
            self.box.value.?.failure = err;
        };
        ui.App.wake();
        return self.box;
    }
    fn perform(self: *Job, cancel: *ui.tasks.Cancellation) !void {
        try cancel.check();
        const result = &self.box.value.?;
        switch (result.operation) {
            .exclude => |target| try result.store.exclude(target.persistent),
            .discard => try result.store.discard(),
            .checkpoint => {
                const captured = &self.capture.?;
                const allocator = captured.arena.allocator();
                var contents: std.ArrayList(storage.Content) = .empty;
                for (captured.documents) |*doc| if (doc.snapshot) |snapshot| {
                    try cancel.check();
                    const bytes = try snapshot.copy(allocator, .{ .start = 0, .end = snapshot.byteLen() });
                    doc.content = storage.reference(bytes);
                    try contents.append(allocator, .{ .id = doc.id, .bytes = bytes });
                };
                try result.store.publish(allocator, captured.index, contents.items);
                result.documents = captured.documents;
                result.fingerprint = captured.fingerprint;
            },
        }
    }
    pub fn discard(_: *Job, box: *Box) void {
        box.destroy();
    }
    pub fn deinit(self: *Job, _: std.mem.Allocator) void {
        if (self.capture) |*captured| captured.deinit();
    }
};

pub fn init(self: *Shell, home: []const u8) !void {
    if (self.recovery != null) return;
    if (self.window != null) return error.RecoveryMustStartBeforeBootstrap;
    const owned_home = try self.allocator.dupe(u8, home);
    errdefer self.allocator.free(owned_home);
    var store = try storage.Store.init(self.allocator, self.workspace.io, home, self.workspace.root_path);
    errdefer store.deinit();
    var loaded = try store.load(self.allocator);
    defer if (loaded) |*value| value.deinit();
    var model: Model = .{ .home = owned_home, .store = store };
    errdefer model.documents.deinit(self.allocator);
    if (loaded) |*value| {
        model.next_id = value.index.next_document_id;
        try restore(self, &model, value);
    }
    self.recovery = model;
}

fn restore(self: *Shell, model: *Model, loaded: *storage.Loaded) !void {
    var restored: Shell = .{ .allocator = self.allocator, .workspace = try ws.Workspace.init(self.allocator, self.workspace.io, self.workspace.root_path) };
    defer restored.deinit(self.allocator);
    const initial_path = if (self.tabs.items.len == 1) (try self.workspace.getConst(self.tabs.items[0].document)).path else null;
    const requested = if (initial_path) |path| try self.allocator.dupe(u8, path) else null;
    defer if (requested) |path| self.allocator.free(path);
    try restored.tabs.ensureUnusedCapacity(self.allocator, loaded.index.documents.len);
    try model.documents.ensureUnusedCapacity(self.allocator, loaded.index.documents.len);
    var warnings = loaded.warnings;
    for (loaded.index.documents, loaded.contents) |metadata, content| {
        const id = if (metadata.path != null and !metadata.dirty)
            restored.workspace.open(metadata.path.?) catch blk: {
                warnings += 1;
                break :blk try restored.workspace.restore(content.bytes, metadata.path, true, metadata.disk, metadata.untitled_name);
            }
        else
            try restored.workspace.restore(content.bytes, metadata.path, metadata.dirty, metadata.disk, metadata.untitled_name);
        if (!metadata.primary and !metadata.secondary) {
            const source_view = try git_editing.getView(&restored, id);
            restoreView(&source_view.editor, (try restored.workspace.getConst(id)).doc.snapshot(), metadata.view);
            model.documents.appendAssumeCapacity(.{ .runtime = id, .id = metadata.id });
            continue;
        }
        var editor = try editing.Editor.init(self.allocator);
        errdefer editor.deinit();
        self.configureEditor(&editor, metadata.language_path orelse metadata.path orelse "");
        restoreView(&editor, (try restored.workspace.getConst(id)).doc.snapshot(), metadata.view);
        const language_path = if (metadata.language_path) |path| try self.allocator.dupe(u8, path) else null;
        errdefer if (language_path) |path| self.allocator.free(path);
        const language_name = if (metadata.language_name) |name| try self.allocator.dupe(u8, name) else null;
        errdefer if (language_name) |name| self.allocator.free(name);
        var secondary: ?editing.Editor = null;
        errdefer if (secondary) |*value| value.deinit();
        if (metadata.secondary_view) |secondary_view| {
            secondary = try editing.Editor.init(self.allocator);
            self.configureEditor(&secondary.?, metadata.language_path orelse metadata.path orelse "");
            restoreView(&secondary.?, (try restored.workspace.getConst(id)).doc.snapshot(), secondary_view);
        }
        restored.tabs.appendAssumeCapacity(.{ .document = id, .editor = editor, .primary = metadata.primary, .secondary = metadata.secondary, .secondary_state = secondary, .language_path = language_path, .language_name = language_name });
        model.documents.appendAssumeCapacity(.{ .runtime = id, .id = metadata.id });
        if (loaded.index.active == metadata.id) restored.active = restored.tabs.items.len - 1;
    }
    if (loaded.index.secondary_active) |active| for (model.documents.items) |doc| {
        if (doc.id == active) {
            for (restored.tabs.items, 0..) |tab, tab_index| if (std.meta.eql(tab.document, doc.runtime)) {
                try panes.selectSecondary(&restored, tab_index);
                break;
            };
            break;
        }
    };
    panes.normalizePrimary(&restored);
    restored.active_pane = if (loaded.index.focus_secondary and restored.secondary != null) .secondary else .primary;
    std.mem.swap(@TypeOf(self.git.editing), &self.git.editing, &restored.git.editing);
    std.mem.swap(ws.Workspace, &self.workspace, &restored.workspace);
    std.mem.swap(std.ArrayList(shell.Tab), &self.tabs, &restored.tabs);
    std.mem.swap(?shell.Pane, &self.secondary, &restored.secondary);
    self.active = restored.active;
    self.active_pane = restored.active_pane;
    self.split_vertical = loaded.index.split_vertical;
    self.split_reverse = loaded.index.split_reverse;
    self.split_ratio = loaded.index.split_ratio;
    if (warnings > 0) try self.setStatus(try std.fmt.allocPrint(self.allocator, "Recovered available documents; {d} recovery records or files need attention. Original recovery files are retained.", .{warnings}));
    if (requested) |path| try self.openPath(path);
}

fn restoreView(editor: *editing.Editor, value: text.Snapshot, saved: storage.View) void {
    var snapshot = value;
    defer snapshot.deinit();
    editor.selections.single(.{ .anchor = saved.anchor, .head = saved.head });
    editor.synchronize(snapshot);
    editor.scroll.offset = saved.scroll;
    editor.horizontal = saved.horizontal;
}

fn view(editor: *const editing.Editor) storage.View {
    const selection = editor.primary();
    return .{ .anchor = selection.anchor, .head = selection.head, .scroll = editor.scroll.offset, .horizontal = editor.horizontal };
}

fn hashString(hash: *std.hash.Wyhash, value: ?[]const u8) void {
    std.hash.autoHash(hash, value != null);
    if (value) |bytes| {
        std.hash.autoHash(hash, bytes.len);
        hash.update(bytes);
    }
}

fn hashView(hash: *std.hash.Wyhash, value: storage.View) void {
    std.hash.autoHash(hash, value.anchor);
    std.hash.autoHash(hash, value.head);
    std.hash.autoHash(hash, @as(u32, @bitCast(value.scroll)));
    std.hash.autoHash(hash, @as(u32, @bitCast(value.horizontal)));
}

pub fn fingerprint(self: *const Shell) !u64 {
    var hash = std.hash.Wyhash.init(0);
    inline for (.{ self.active, self.active_pane, self.split_vertical, self.split_reverse, @as(u32, @bitCast(self.split_ratio)), self.tabs.items.len }) |value| std.hash.autoHash(&hash, value);
    if (self.secondary) |pane| std.hash.autoHash(&hash, pane.document);
    for (self.tabs.items) |*tab| {
        const record = try self.workspace.getConst(tab.document);
        inline for (.{ tab.document, record.doc.stateId(), record.saved_state, record.disk, tab.primary, tab.secondary }) |value| std.hash.autoHash(&hash, value);
        hashView(&hash, view(&tab.editor));
        hashString(&hash, record.path);
        hashString(&hash, record.untitled_name);
        hashString(&hash, tab.language_path);
        hashString(&hash, tab.language_name);
        if (self.secondary) |*pane| if (std.meta.eql(pane.document, tab.document)) hashView(&hash, view(&pane.editor));
        if (tab.secondary_state) |*editor| hashView(&hash, view(editor));
    }
    for (self.git.editing.views.items) |*source| {
        var tabbed = false;
        for (self.tabs.items) |tab| if (std.meta.eql(tab.document, source.document)) {
            tabbed = true;
            break;
        };
        if (tabbed) continue;
        const record = try self.workspace.getConst(source.document);
        if (!record.dirty()) continue;
        inline for (.{ source.document, record.doc.stateId(), record.saved_state, record.disk }) |value| std.hash.autoHash(&hash, value);
        hashView(&hash, view(&source.editor));
        hashString(&hash, record.path);
    }
    return hash.final();
}

fn capture(self: *Shell, stamp: u64) !Capture {
    const model = &self.recovery.?;
    var arena = std.heap.ArenaAllocator.init(a);
    errdefer arena.deinit();
    const allocator = arena.allocator();
    var metadata: std.ArrayList(storage.Document) = .empty;
    var documents: std.ArrayList(Captured) = .empty;
    errdefer for (documents.items) |*doc| if (doc.snapshot) |*snapshot| snapshot.deinit();
    var index: storage.Index = .{ .root = try allocator.dupe(u8, self.workspace.root_path), .documents = &.{}, .focus_secondary = self.active_pane == .secondary, .split_vertical = self.split_vertical, .split_reverse = self.split_reverse, .split_ratio = self.split_ratio };
    for (self.tabs.items, 0..) |*tab, position| {
        const tracked = try model.track(self.allocator, tab.document);
        const record = try self.workspace.getConst(tab.document);
        const unchanged = tracked.state == record.doc.stateId() and tracked.content != null;
        var secondary_view: ?storage.View = if (tab.secondary_state) |*editor| view(editor) else null;
        if (self.secondary) |*pane| if (std.meta.eql(pane.document, tab.document)) {
            secondary_view = view(&pane.editor);
            index.secondary_active = tracked.id;
        };
        if (position == self.active) index.active = tracked.id;
        try metadata.append(allocator, .{ .id = tracked.id, .path = if (record.path) |path| try allocator.dupe(u8, path) else null, .untitled_name = try allocator.dupe(u8, record.untitled_name), .dirty = record.dirty(), .disk = record.disk, .primary = tab.primary, .secondary = tab.secondary, .view = view(&tab.editor), .secondary_view = secondary_view, .language_path = if (tab.language_path) |path| try allocator.dupe(u8, path) else null, .language_name = if (tab.language_name) |name| try allocator.dupe(u8, name) else null, .content = if (unchanged) tracked.content else null });
        try documents.ensureUnusedCapacity(allocator, 1);
        documents.appendAssumeCapacity(.{ .id = tracked.id, .state = record.doc.stateId(), .snapshot = if (unchanged) null else record.doc.snapshot(), .content = if (unchanged) tracked.content else null });
    }
    for (self.git.editing.views.items) |*source| {
        var tabbed = false;
        for (self.tabs.items) |tab| if (std.meta.eql(tab.document, source.document)) {
            tabbed = true;
            break;
        };
        if (tabbed) continue;
        const record = try self.workspace.getConst(source.document);
        if (!record.dirty()) continue;
        const tracked = try model.track(self.allocator, source.document);
        const unchanged = tracked.state == record.doc.stateId() and tracked.content != null;
        try metadata.append(allocator, .{ .id = tracked.id, .path = if (record.path) |path| try allocator.dupe(u8, path) else null, .untitled_name = "", .dirty = true, .disk = record.disk, .primary = false, .secondary = false, .view = view(&source.editor), .content = if (unchanged) tracked.content else null });
        try documents.ensureUnusedCapacity(allocator, 1);
        documents.appendAssumeCapacity(.{ .id = tracked.id, .state = record.doc.stateId(), .snapshot = if (unchanged) null else record.doc.snapshot(), .content = if (unchanged) tracked.content else null });
    }
    index.documents = metadata.items;
    index.next_document_id = model.next_id;
    return .{ .arena = arena, .index = index, .documents = documents.items, .fingerprint = stamp };
}

pub fn poll(self: *Shell, cx: *ui.Context(Shell)) !void {
    const model = if (self.recovery) |*value| value else return;
    if (model.approval != null) return;
    if (!model.busy and model.store == null) return;
    const now = try cx.app.currentTime();
    const stamp = try fingerprint(self);
    if (model.observed != stamp) {
        if (model.due == null) model.first_changed = now;
        model.observed = stamp;
        model.due = @min(now + debounce, model.first_changed + max_delay);
        cx.notify();
    }
    if (model.busy) return;
    if (model.close) |closing| switch (closing) {
        .document => |target| {
            const tracked = try model.track(self.allocator, target.id);
            try start(self, cx, .{ .exclude = .{ .id = target.id, .persistent = tracked.id, .state = target.state } }, null);
            return;
        },
        .window_discard => |requested| {
            if (requested != stamp) {
                model.close = null;
                try self.reportError(error.DocumentChangedWhileClosing);
                cx.notify();
                return;
            }
            try start(self, cx, .{ .discard = requested }, null);
            return;
        },
        .window_save => {},
    } else {
        if (model.committed == stamp) {
            model.due = null;
            return;
        }
        if (model.due == null or now < model.due.?) return;
    }
    var captured = try capture(self, stamp);
    errdefer captured.deinit();
    try start(self, cx, .checkpoint, captured);
}

fn start(self: *Shell, cx: *ui.Context(Shell), operation: Operation, captured: ?Capture) !void {
    const model = &self.recovery.?;
    const box = try Box.create(a, .{ .store = model.store.?, .operation = operation });
    model.store = null;
    errdefer {
        const result = box.take();
        model.store = result.store;
        box.destroy();
    }
    _ = try cx.spawn(Job, .{ .box = box, .capture = captured }, complete);
    model.busy = true;
    model.due = null;
    cx.notify();
}

pub fn requestClose(self: *Shell, cx: *ui.Context(Shell), closing: Close) !void {
    const model = &self.recovery.?;
    if (model.store == null and !model.busy) return error.RecoveryUnavailable;
    if (model.close != null) return error.RecoveryClosePending;
    model.close = closing;
    errdefer model.close = null;
    try poll(self, cx);
    cx.notify();
}

pub fn enabled(self: *const Shell) bool {
    const model = self.recovery orelse return false;
    return model.store != null or model.busy;
}

fn freshSession(self: *Shell) !void {
    const model = &self.recovery.?;
    model.store.?.deinit();
    model.store = null;
    model.committed = null;
    model.last_checkpoint = null;
    model.observed = null;
    for (model.documents.items) |*doc| {
        doc.state = null;
        doc.content = null;
    }
    model.store = storage.Store.initFresh(self.allocator, self.workspace.io, model.home, self.workspace.root_path) catch |err| {
        model.last_error = err;
        return err;
    };
}

/// Completion approves one exact session state. Validate it again at the close
/// event because another task completion may have edited text in the meantime.
pub fn validateClose(self: *Shell, cx: *ui.Context(Shell)) !void {
    const model = if (self.recovery) |*value| value else return;
    const approval = model.approval orelse return;
    if (approval.fingerprint == try fingerprint(self)) return;
    self.allow_close = false;
    model.approval = null;
    model.close = null;
    if (approval.discarded) freshSession(self) catch |err| {
        try self.reportError(err);
        cx.notify();
        return;
    };
    model.due = try cx.app.currentTime();
    try self.reportError(error.DocumentChangedWhileClosing);
    cx.notify();
}

pub fn checkpoint(self: *Shell, _: *ui.Event(ui.Click), cx: *ui.Context(Shell)) !void {
    const model = &self.recovery.?;
    if (model.store == null and !model.busy) {
        try self.reportError(model.last_error orelse error.RecoveryUnavailable);
        cx.notify();
        return;
    }
    if (!model.busy) {
        model.committed = null;
        model.due = try cx.app.currentTime();
        try poll(self, cx);
    }
}

fn complete(self: *Shell, cx: *ui.Context(Shell), output: anyerror!*Box) !void {
    const box = try output;
    const result = box.take();
    const model = &self.recovery.?;
    model.store = result.store;
    model.busy = false;
    if (result.failure) |err| {
        model.close = null;
        model.due = (try cx.app.currentTime()) + 2;
        if (model.last_error == null or model.last_error.? != err) try self.reportError(err);
        model.last_error = err;
        cx.notify();
        return;
    }
    model.last_error = null;
    switch (result.operation) {
        .checkpoint => {
            for (result.documents) |doc| for (model.documents.items) |*tracked| if (tracked.id == doc.id) {
                tracked.state = doc.state;
                tracked.content = doc.content;
            };
            model.committed = result.fingerprint;
            model.last_checkpoint = try cx.app.currentTime();
            if (model.close != null and model.close.? == .window_save and result.fingerprint == try fingerprint(self)) {
                model.approval = .{ .fingerprint = result.fingerprint, .discarded = false };
                self.allow_close = true;
                try cx.app.requestCloseWindow(self.window.?);
                cx.notify();
                return;
            }
            if (model.close != null and model.close.? == .window_save and actions.firstDirtyDocument(self) != null) {
                model.close = null;
                try cx.app.requestCloseWindow(self.window.?);
            }
        },
        .exclude => |target| {
            model.close = null;
            const record = self.workspace.getConst(target.id) catch return;
            if (record.doc.stateId() != target.state) {
                const tracked = try model.track(self.allocator, target.id);
                if (model.next_id == std.math.maxInt(u64)) return error.RecoveryCapacityExceeded;
                tracked.id = model.next_id;
                model.next_id += 1;
                tracked.content = null;
                tracked.state = null;
                model.committed = null;
                model.due = try cx.app.currentTime();
                try self.reportError(error.DocumentChangedWhileClosing);
            } else for (self.tabs.items, 0..) |tab, index| if (std.meta.eql(tab.document, target.id)) {
                try actions.finishCloseTab(self, index);
                for (model.documents.items, 0..) |doc, tracked_index| if (std.meta.eql(doc.runtime, target.id)) {
                    _ = model.documents.orderedRemove(tracked_index);
                    break;
                };
                break;
            };
        },
        .discard => |stamp| {
            model.close = null;
            if (stamp == try fingerprint(self)) {
                model.approval = .{ .fingerprint = stamp, .discarded = true };
                self.allow_close = true;
                try cx.app.requestCloseWindow(self.window.?);
                cx.notify();
                return;
            } else {
                freshSession(self) catch |err| {
                    try self.reportError(err);
                    cx.notify();
                    return;
                };
                model.due = try cx.app.currentTime();
                try self.reportError(error.DocumentChangedWhileClosing);
            }
        },
    }
    try poll(self, cx);
    cx.notify();
}

pub fn schedule(self: *const Shell, b: *ui.Ui) !void {
    const model = if (self.recovery) |*value| value else return;
    if (!model.busy) if (model.due) |due| try b.requestFrameAfter(@max(0.001, due - b.frame.time));
}
