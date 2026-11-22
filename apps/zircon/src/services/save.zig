//! Save hooks and autosave share the same document and settings resolution.
const std = @import("std");
const editing = @import("zircon_editor");
const text = @import("zircon_text");
const ui = @import("zircon_ui");
const ws = @import("zircon_workspace");
const actions = @import("../actions.zig");
const settings = @import("../settings/model.zig");
const shell = @import("../shell.zig");
const git = @import("git.zig");
const language = @import("language.zig");
const Shell = shell.Shell;

pub const Options = struct {
    finish_pending: bool = false,
    automatic: bool = false,
    refresh_git: bool = false,
    quiet: bool = false,

    pub fn merge(existing: ?Options, requested: ?Options) ?Options {
        const first = existing orelse return requested;
        const second = requested orelse return first;
        return .{
            .automatic = first.automatic and second.automatic,
            .quiet = first.quiet and second.quiet,
            .finish_pending = first.finish_pending or second.finish_pending,
            .refresh_git = first.refresh_git or second.refresh_git,
        };
    }
};
pub const Deadline = struct { document: ws.DocumentId, due: f64 };

pub fn saveDocument(self: *Shell, cx: *ui.Context(Shell), id: ws.DocumentId, options: Options) !void {
    const resolved = self.bufferSettings(self.documentLanguage(id));
    if (resolved.format_on_save == .on) {
        const started = language.requestFormattingForSave(self, cx, id, options) catch false;
        if (started) return;
    }
    try saveNow(self, cx, id, null, options);
}

pub fn saveNow(self: *Shell, cx: *ui.Context(Shell), id: ws.DocumentId, destination: ?[]const u8, options: Options) !void {
    _ = language.cancelFormatting(self, id);
    const record = try self.workspace.getConst(id);
    if (options.automatic and (record.path == null or !record.dirty() or record.disk_conflict)) return;
    const identity = if (destination) |path| self.languageFor(self.languagePath(id, path), self.languageName(id)) else self.documentLanguage(id);
    {
        self.saving_document = id;
        defer self.saving_document = null;
        try applyHygiene(self, cx, id, self.bufferSettings(identity));
    }
    try self.workspace.save(id, destination);
    cancelDelay(self, id);
    actions.historyBoundary(self, id);
    defer cx.notify();
    const path = (try self.workspace.getConst(id)).path.?;
    const reloaded = if (self.settings) |entity| cx.update(entity, settings.Settings.reloadSavedPath, .{path}) else false;
    if (reloaded) |matched| {
        if (matched) {
            const ignored = try cx.read(self.settings.?, settings.Settings.ignoredProjectKeys, .{self.workspace.root_path});
            if (ignored > 0) {
                try reportIgnored(self, ignored);
            } else if (!options.quiet) try savedStatus(self);
        } else if (!options.quiet) try savedStatus(self);
    } else |err| try self.reportError(err);
    if (options.refresh_git) try git.edited(self, cx);
    if (options.finish_pending and self.pending != null) {
        const still_target = switch (self.pending.?) {
            .window => true,
            .tab => |index| index < self.tabs.items.len and std.meta.eql(self.tabs.items[index].document, id),
        };
        if (still_target) try actions.finishPending(self, cx);
    }
}

fn savedStatus(self: *Shell) !void {
    try self.setStatus(try self.allocator.dupe(u8, "Saved"));
}

pub fn reportIgnored(self: *Shell, count: usize) !void {
    try self.setStatus(try std.fmt.allocPrint(self.allocator, "Ignored {d} restricted setting(s) in .zircon/settings.json", .{count}));
}

fn applyHygiene(self: *Shell, cx: *ui.Context(Shell), id: ws.DocumentId, resolved: settings.BufferSettings) !void {
    if (!resolved.remove_trailing_whitespace_on_save and !resolved.ensure_final_newline_on_save) return;
    const record = try self.workspace.get(id);
    var snapshot = record.doc.snapshot();
    defer snapshot.deinit();
    const total = snapshot.byteLen();
    if (total == 0) return;

    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var edits: std.ArrayList(text.Edit) = .empty;
    if (resolved.remove_trailing_whitespace_on_save) {
        var lines = try snapshot.linesFrom(0);
        while (lines.next()) |line| {
            if (line.range.start == line.range.end) continue;
            const bytes = line.bytes orelse try snapshot.copy(a, line.range);
            const trimmed = std.mem.trimEnd(u8, bytes, " \t").len;
            if (trimmed < bytes.len) try edits.append(a, .{
                .range = .{ .start = line.range.start + trimmed, .end = line.range.end },
                .text = "",
            });
        }
    }
    if (resolved.ensure_final_newline_on_save and try snapshot.byteAt(total - 1) != '\n') {
        const ending = if (snapshot.lineCount() > 1 and
            (try snapshot.lineRangeIncludingEnding(0)).end - (try snapshot.lineRange(0)).end == 2)
            "\r\n"
        else
            "\n";
        if (edits.items.len > 0 and edits.items[edits.items.len - 1].range.end == total) {
            const last = &edits.items[edits.items.len - 1];
            if (last.range.start != 0) last.text = ending;
        } else {
            try edits.append(a, .{ .range = .{ .start = total, .end = total }, .text = ending });
        }
    }
    if (edits.items.len == 0) return;

    for (self.tabs.items) |*tab| if (std.meta.eql(tab.document, id)) {
        var prepared = try tab.editor.prepareEdits(&record.doc, edits.items, try editing.Editor.freshGroup(), .preserve);
        defer prepared.deinit();
        var outcome = try prepared.commit();
        return actions.applyOutcome(self, cx, id, 0, &outcome, .formatting);
    };
    var outcome: editing.Outcome = .{ .handled = true, .change = try record.doc.apply(snapshot.revision(), edits.items, 0) };
    try actions.applyOutcome(self, cx, id, 255, &outcome, .formatting);
}

pub fn changed(self: *Shell, cx: *ui.Context(Shell), id: ws.DocumentId) !void {
    const record = self.workspace.getConst(id) catch return;
    const resolved = self.bufferSettings(self.documentLanguage(id));
    if (record.path == null or !record.dirty() or record.disk_conflict or resolved.autosave != .after_delay) {
        cancelDelay(self, id);
        return;
    }
    const due = try cx.app.currentTime() + @as(f64, @floatFromInt(resolved.autosave_delay_ms)) / 1000;
    for (self.autosave_deadlines.items) |*deadline| if (std.meta.eql(deadline.document, id)) {
        deadline.due = due;
        return;
    };
    try self.autosave_deadlines.append(self.allocator, .{ .document = id, .due = due });
}

pub fn cancelDelay(self: *Shell, id: ws.DocumentId) void {
    for (self.autosave_deadlines.items, 0..) |deadline, i| if (std.meta.eql(deadline.document, id)) {
        _ = self.autosave_deadlines.swapRemove(i);
        return;
    };
}

pub fn nextDeadline(self: *const Shell) ?f64 {
    var next: ?f64 = null;
    for (self.autosave_deadlines.items) |deadline| next = @min(next orelse deadline.due, deadline.due);
    return next;
}

pub fn poll(self: *Shell, cx: *ui.Context(Shell)) !void {
    if (self.autosave_deadlines.items.len == 0) return;
    const now = try cx.app.currentTime();
    var i: usize = 0;
    while (i < self.autosave_deadlines.items.len) {
        const deadline = self.autosave_deadlines.items[i];
        if (deadline.due > now) {
            i += 1;
            continue;
        }
        _ = self.autosave_deadlines.swapRemove(i);
        try autosave(self, cx, deadline.document, .delay);
    }
}

const Trigger = enum { focus, window, delay };

fn autosave(self: *Shell, cx: *ui.Context(Shell), id: ws.DocumentId, trigger: Trigger) !void {
    const record = self.workspace.getConst(id) catch return;
    if (record.path == null or !record.dirty() or record.disk_conflict) return;
    const mode = self.bufferSettings(self.documentLanguage(id)).autosave;
    const matches = switch (trigger) {
        .focus => mode == .on_focus_change,
        .window => mode == .on_window_change or mode == .on_focus_change,
        .delay => mode == .after_delay,
    };
    if (!matches) return;
    saveDocument(self, cx, id, .{ .automatic = true, .quiet = true, .refresh_git = true }) catch |err| {
        try self.reportError(err);
        cx.notify();
    };
}

pub fn focusChanged(self: *Shell, cx: *ui.Context(Shell), previous: ?ws.DocumentId) !void {
    const id = previous orelse return;
    const current = (actions.active(self) catch return autosave(self, cx, id, .focus)).id;
    if (!std.meta.eql(id, current)) try autosave(self, cx, id, .focus);
}

pub fn windowBlurred(self: *Shell, cx: *ui.Context(Shell)) !void {
    for (self.workspace.slots.items, 0..) |slot, index| {
        if (slot.record != null) try autosave(self, cx, .{ .workspace = self.workspace.identity, .slot = @intCast(index), .generation = slot.generation }, .window);
    }
}
