//! Source-pane placement, per-pane editor state and drag/drop sessions.
//! Moving a tab transfers presentation state while retaining document identity.
const std = @import("std");
const zircon_editor = @import("zircon_editor");
const ui = @import("zircon_ui");
const ws = @import("zircon_workspace");
const shell = @import("shell.zig");
const components = @import("views/components.zig");
const Shell = shell.Shell;
pub const DragTarget = struct { document: ws.DocumentId, pane: u8 };
pub const Session = struct {
    source: union(enum) { tab: ws.DocumentId, file: []u8 },
    pane: u8 = 0,
    origin: ui.Point,
    position: ui.Point = .{},
    moved: bool = false,
    pub fn deinit(self: *Session, a: std.mem.Allocator) void {
        if (self.source == .file) a.free(self.source.file);
    }
};
pub fn key(id: ws.DocumentId) u64 {
    return (@as(u64, id.generation) << 32) | id.slot;
}

pub fn selectSecondary(self: *Shell, index: usize) !void {
    if (index >= self.tabs.items.len) return;
    const id = self.tabs.items[index].document;
    self.secondary_tool = null;
    if (self.secondary) |pane| if (std.meta.eql(pane.document, id)) {
        self.tabs.items[index].secondary = true;
        self.active_pane = .secondary;
        self.editor_focus_request +%= 1;
        try self.installDiagnostics();
        return;
    };
    {
        var next = if (self.tabs.items[index].secondary_state) |state| state else try zircon_editor.Editor.init(self.allocator);
        self.tabs.items[index].secondary_state = null;
        errdefer next.deinit();
        const record = try self.workspace.getConst(id);
        self.configureEditor(&next, self.languagePath(id, record.path orelse ""));
        var snapshot = record.doc.snapshot();
        defer snapshot.deinit();
        next.synchronize(snapshot);
        if (self.secondary) |pane| {
            var stored = false;
            for (self.tabs.items) |*tab| if (std.meta.eql(tab.document, pane.document)) {
                if (tab.secondary_state) |*old| old.deinit();
                tab.secondary_state = pane.editor;
                stored = true;
                break;
            };
            if (!stored) {
                var editor = pane.editor;
                editor.deinit();
            }
        }
        self.tabs.items[index].secondary = true;
        self.secondary = .{ .document = id, .editor = next };
        self.active_pane = .secondary;
        self.editor_focus_request +%= 1;
    }
    try self.installDiagnostics();
}

pub fn normalizePrimary(self: *Shell) void {
    if (self.tabs.items.len == 0) {
        self.active = 0;
        return;
    }
    if (self.active < self.tabs.items.len and self.tabs.items[self.active].primary) return;
    for (self.tabs.items, 0..) |tab, i| if (tab.primary) {
        self.active = i;
        return;
    };
    self.active = @min(self.active, self.tabs.items.len - 1);
    self.tabs.items[self.active].primary = true;
}

pub fn closePrimaryTab(self: *Shell, index: usize) void {
    self.tabs.items[index].primary = false;
    for (self.tabs.items, 0..) |tab, i| if (tab.primary) {
        self.active = i;
        self.active_pane = .primary;
        self.editor_focus_request +%= 1;
        return;
    };
    if (self.secondary) |pane| {
        const active_id = pane.document;
        for (self.tabs.items, 0..) |*tab, i| {
            tab.primary = tab.secondary;
            tab.secondary = false;
            if (std.meta.eql(tab.document, active_id)) {
                tab.editor.deinit();
                tab.editor = pane.editor;
                self.active = i;
            } else if (tab.secondary_state) |state| {
                tab.editor.deinit();
                tab.editor = state;
                tab.secondary_state = null;
            }
        }
        self.secondary = null;
        if (self.secondary_tool) |tool| {
            self.active_pane = .primary;
            self.showTool(tool);
        }
        self.secondary_tool = null;
        self.secondary_tools = .{};
    }
    self.active_pane = .primary;
    self.editor_focus_request +%= 1;
    normalizePrimary(self);
}

pub fn closeSplit(self: *Shell) void {
    inline for (std.meta.tags(Shell.Tool)) |tool| if (self.secondary_tools.contains(tool)) self.tool_tabs.set(tool, true);
    self.secondary_tools = .{};
    self.secondary_tool = null;
    if (self.secondary) |*pane| pane.editor.deinit();
    self.secondary = null;
    for (self.tabs.items) |*tab| {
        if (tab.secondary) tab.primary = true;
        tab.secondary = false;
        if (tab.secondary_state) |*state| state.deinit();
        tab.secondary_state = null;
    }
    self.active_pane = .primary;
    self.editor_focus_request +%= 1;
    normalizePrimary(self);
}

pub fn closeSecondaryTab(self: *Shell, index: usize) void {
    if (index >= self.tabs.items.len) return;
    const id = self.tabs.items[index].document;
    self.tabs.items[index].secondary = false;
    if (self.tabs.items[index].secondary_state) |*state| state.deinit();
    self.tabs.items[index].secondary_state = null;
    if (self.secondary) |pane| if (std.meta.eql(pane.document, id)) {
        for (self.tabs.items, 0..) |tab, i| if (tab.secondary) {
            selectSecondary(self, i) catch {
                closeSplit(self);
                return;
            };
            if (self.tabs.items[index].secondary_state) |*state| state.deinit();
            self.tabs.items[index].secondary_state = null;
            return;
        };
        closeSplit(self);
    };
}

pub fn tabInput(self: *Shell, e: *ui.Event(ui.Input), cx: *ui.Context(Shell), target: DragTarget) !void {
    if (e.data == .pointer_down and e.data.pointer_down.button == .primary) {
        cancel(self);
        const point = e.data.pointer_down.position;
        self.tab_drag = .{ .source = .{ .tab = target.document }, .pane = target.pane, .origin = point, .position = point };
        e.capturePointer();
        return;
    }
    try advance(self, e, cx);
}

pub fn treeInput(self: *Shell, e: *ui.Event(ui.Input), cx: *ui.Context(Shell), index: u32) !void {
    if (e.data == .pointer_down and e.data.pointer_down.button == .primary) {
        if (index >= self.tree.items.len or self.tree.items[index].directory) return;
        cancel(self);
        const point = e.data.pointer_down.position;
        self.tab_drag = .{ .source = .{ .file = try self.allocator.dupe(u8, self.tree.items[index].path) }, .origin = point, .position = point };
        e.capturePointer();
        return;
    }
    try advance(self, e, cx);
}

pub fn cancel(self: *Shell) void {
    if (self.tab_drag) |*drag| drag.deinit(self.allocator);
    self.tab_drag = null;
}
pub const Drop = struct { pane: u8 = 0, edge: enum { center, left, right, top, bottom } = .center, bounds: ui.Rect = .{}, strip: bool = false };
pub fn destination(self: *const Shell, frame: anytype, point: ui.Point) ?Drop {
    _ = self;
    var result: ?Drop = null;
    for (frame.nodes.items, 0..) |node, i| if (node.key) |k| if (k == .string) {
        const primary = std.mem.eql(u8, k.string, "primary-pane");
        const secondary = std.mem.eql(u8, k.string, "secondary-pane");
        if (!primary and !secondary) continue;
        const bounds = frame.bounds[i];
        if ((point.x < bounds.x or point.y < bounds.y or point.x >= bounds.x + bounds.width or point.y >= bounds.y + bounds.height)) continue;
        const x = (point.x - bounds.x) / @max(1, bounds.width);
        const y = (point.y - bounds.y) / @max(1, bounds.height);
        const strip = point.y < bounds.y + components.metrics.tabs;
        var edge: Drop = .{ .pane = if (secondary) 1 else 0, .bounds = bounds, .strip = strip };
        if (!strip) {
            const horizontal = @min(x, 1 - x);
            const vertical = @min(y, 1 - y);
            if (@min(horizontal, vertical) < 0.25) edge.edge = if (horizontal < vertical) (if (x < 0.5) .left else .right) else (if (y < 0.5) .top else .bottom);
        }
        result = edge;
    };
    return result;
}

fn advance(self: *Shell, e: *ui.Event(ui.Input), cx: *ui.Context(Shell)) !void {
    const session = if (self.tab_drag) |*drag| drag else return;
    switch (e.data) {
        .pointer_move => |pointer| {
            const dx = pointer.position.x - session.origin.x;
            const dy = pointer.position.y - session.origin.y;
            session.moved = session.moved or dx * dx + dy * dy >= 25;
            session.position = pointer.position;
            if (session.moved) {
                e.preventDefault();
                cx.notify();
            }
        },
        .pointer_up => |pointer| {
            defer cancel(self);
            e.releasePointer();
            if (!session.moved) return;
            e.preventDefault();
            const w = try cx.app.window(self.window.?);
            const drop = destination(self, &w.frames.committed, pointer.position) orelse {
                cx.notify();
                return;
            };
            const from = session.pane;
            if (session.source == .file) {
                self.active_pane = if (drop.pane == 1) .secondary else .primary;
                try self.openPath(session.source.file);
                if (self.panel == .image) {
                    cx.notify();
                    return;
                }
            }
            const id = if (session.source == .tab) session.source.tab else if (drop.pane == 1 and self.secondary != null) self.secondary.?.document else self.tabs.items[self.active].document;
            var found: ?usize = null;
            for (self.tabs.items, 0..) |tab, i| if (std.meta.eql(tab.document, id)) {
                found = i;
                break;
            };
            const index = found orelse return;
            const new_split = drop.edge != .center;
            const to: u8 = if (new_split) 1 else drop.pane;
            if (to == 1) {
                try selectSecondary(self, index);
                var others: usize = 0;
                for (self.tabs.items, 0..) |tab, i| if (i != index and tab.primary) {
                    others += 1;
                };
                if (others > 0) self.tabs.items[index].primary = false;
                normalizePrimary(self);
                if (new_split) {
                    self.split_vertical = drop.edge == .top or drop.edge == .bottom;
                    self.split_reverse = drop.edge == .left or drop.edge == .top;
                    self.split_ratio = 0.5;
                }
            } else {
                self.tabs.items[index].primary = true;
                self.active = index;
                if (from == 1) closeSecondaryTab(self, index);
                self.active_pane = .primary;
                self.panel = .editor;
            }
            if (drop.strip) {
                const strip_key: []const u8 = if (to == 1) "secondary-tabs" else "tabs";
                var target = self.tabs.items.len - 1;
                for (w.frames.committed.nodes.items, 0..) |node, ni| {
                    const parent = node.parent orelse continue;
                    const parent_key = w.frames.committed.nodes.items[parent].key orelse continue;
                    const node_key = node.key orelse continue;
                    if (parent_key != .string or !std.mem.eql(u8, parent_key.string, strip_key) or node_key != .number) continue;
                    const bounds = w.frames.committed.bounds[ni];
                    if (pointer.position.x >= bounds.x + bounds.width) continue;
                    for (self.tabs.items, 0..) |tab, ti| if (key(tab.document) == node_key.number) {
                        target = ti;
                        break;
                    };
                    break;
                }
                const active_id = self.tabs.items[self.active].document;
                const tab = self.tabs.orderedRemove(index);
                self.tabs.insertAssumeCapacity(@min(target, self.tabs.items.len), tab);
                for (self.tabs.items, 0..) |current, ti| if (std.meta.eql(current.document, active_id)) {
                    self.active = ti;
                    break;
                };
            }
            self.editor_focus_request +%= 1;
            cx.notify();
        },
        .focus => |focused| if (!focused) {
            cancel(self);
            e.releasePointer();
            cx.notify();
        },
        else => {},
    }
}
