//! Window-owned cross-source edits share history with ordinary source tabs.
const zircon_editor = @import("zircon_editor");
const multi = @import("zircon_multibuffer");
const text = @import("zircon_text");
const ui = @import("zircon_ui");
const ws = @import("zircon_workspace");
const actions = @import("actions.zig");
const git = @import("services/git.zig");
const shell = @import("shell.zig");
const Shell = shell.Shell;

pub fn apply(self: *Shell, cx: *ui.Context(Shell), edits: []const multi.SourceEdit) !void {
    for (edits) |edit| if (self.git.editing.find(edit.source) == null) {
        _ = try actions.ensureTab(self, edit.source);
    };
    var batch = try self.multibuffer_history.apply(&self.workspace, edits);
    defer batch.deinit();
    try publish(self, cx, &batch, .project_edit);
}

pub fn travel(self: *Shell, cx: *ui.Context(Shell), source: ws.DocumentId, direction: text.Document.HistoryDirection) !bool {
    var batch = (try self.multibuffer_history.travel(&self.workspace, source, direction)) orelse return false;
    defer batch.deinit();
    try publish(self, cx, &batch, if (direction == .undo) .undo else .redo);
    return true;
}

fn publish(self: *Shell, cx: *ui.Context(Shell), batch: *multi.Batch, origin: ws.ChangeOrigin) !void {
    // Text is already committed across all sources. Publish every change even
    // if updating one presentation fails, so subscribers retain exact mappings.
    var failure: ?anyerror = null;
    for (batch.items) |*item| {
        var outcome: zircon_editor.Outcome = .{ .handled = true, .change = item.change };
        // applyOutcome transfers mapping ownership into the workspace log.
        item.change.mappings = &.{};
        actions.applyOutcome(self, cx, item.source, 255, &outcome, origin) catch |err| {
            if (failure == null) failure = err;
        };
    }
    if (self.git.repository) git.bufferChanged(self, cx) catch |err| {
        if (failure == null) failure = err;
    };
    cx.notify();
    if (failure) |err| return err;
}
