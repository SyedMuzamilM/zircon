//! A native application driven by the subprocess crash-recovery check.
const std = @import("std");
const ui = @import("zircon_ui");
const zircon = @import("zircon");
const Shell = zircon.Shell;
const saved = "dirty 日本語 disk\n";
const untitled = "unsaved 👩‍💻\n";
var marker: []const u8 = undefined;
var marker_written = false;
var discard_after_checkpoint = false;
var close_after_checkpoint = false;
var discard_window = false;

const Ops = struct {
    fn configure(self: *Shell, cx: *ui.Context(Shell), settings: []const u8) !void {
        try self.loadSettings(cx, settings);
    }
    fn command(self: *Shell, cx: *ui.Context(Shell), action: zircon.Command) !void {
        var click: ui.Event(ui.Click) = .{ .data = .{} };
        try self.onCommand(&click, cx, action);
    }
    fn place(self: *Shell, cx: *ui.Context(Shell)) !void {
        self.split_ratio = 0.6;
        self.tabs.items[0].editor.selections.single(.{ .anchor = 0, .head = 6 });
        self.secondary.?.editor.selections.single(.{ .anchor = 1, .head = 4 });
        self.editor_focus_request +%= 1;
        cx.notify();
    }
    fn acknowledge(self: *Shell, cx: *ui.Context(Shell)) !void {
        if (marker_written) return;
        const recovery = self.recovery orelse return error.RecoveryNotEnabled;
        if (self.status_is_error) return error.RecoveryDriverFailed;
        // External recipients run before task completions. Keep one wake queued
        // while the writer runs so this observer sees its completion as well.
        // Before the writer starts, only the committed frame deadline wakes us.
        if (recovery.busy) {
            ui.App.wake();
            return;
        }
        if (recovery.busy or recovery.committed == null or recovery.committed != recovery.observed or recovery.due != null) return;
        if (close_after_checkpoint) {
            marker_written = true;
            if (discard_window) {
                var close: ui.Event(ui.Input) = .{ .data = .close };
                try self.onRoot(&close, cx);
                try command(self, cx, .discard_dirty);
            } else try cx.app.requestCloseWindow(self.window.?);
            return;
        }
        if (discard_after_checkpoint and self.tabs.items.len > 1) {
            self.active_pane = .primary;
            if (self.secondary != null) try command(self, cx, .close_split);
            self.active = 1;
            try command(self, cx, .close_tab);
            try command(self, cx, .discard_dirty);
            return;
        }
        try std.Io.Dir.cwd().writeFile(self.workspace.io, .{ .sub_path = marker, .data = "checkpoint committed\n" });
        marker_written = true;
    }
    fn verify(self: *const Shell, external: bool, discarded: bool) !void {
        if (self.recovery == null) return error.RecoveryNotEnabled;
        if (self.tabs.items.len != @as(usize, if (discarded) 1 else 2)) return error.WrongRestoredDocumentCount;
        for (self.tabs.items) |tab| {
            const record = try self.workspace.getConst(tab.document);
            var snapshot = record.doc.snapshot();
            defer snapshot.deinit();
            const bytes = try snapshot.copy(self.allocator, .{ .start = 0, .end = snapshot.byteLen() });
            defer self.allocator.free(bytes);
            if (!std.mem.eql(u8, bytes, if (record.path != null) saved else untitled)) return error.RecoveredBytesDiffer;
            if (!record.dirty()) return error.RecoveredWorkIsNotDirty;
        }
        if (!discarded) {
            if (self.secondary == null or !self.split_vertical or self.split_reverse or @abs(self.split_ratio - 0.6) > 0.001) return error.PaneLayoutNotRestored;
            if (self.tabs.items[0].editor.primary().head != 6 or self.secondary.?.editor.primary().head != 4) return error.SelectionNotRestored;
            if (self.active_pane != .secondary) return error.FocusNotRestored;
        }
        if (external) {
            // Read callbacks cannot save. The separate update below proves the
            // recovery stamp refuses an intervening write.
            if ((try self.workspace.getConst(self.tabs.items[0].document)).disk == null) return error.OriginalDiskStampMissing;
        }
    }
    fn verifyConflict(self: *Shell, _: *ui.Context(Shell)) !void {
        self.workspace.save(self.tabs.items[0].document, null) catch |err| {
            if (err == error.DiskConflict) return;
            return err;
        };
        return error.RecoveredSaveOverwroteExternalEdit;
    }
    fn verifyClean(self: *const Shell, empty: bool) !void {
        if (self.recovery == null or self.tabs.items.len != 1) return error.WrongCleanSession;
        const record = try self.workspace.getConst(self.tabs.items[0].document);
        var snapshot = record.doc.snapshot();
        defer snapshot.deinit();
        const bytes = try snapshot.copy(self.allocator, .{ .start = 0, .end = snapshot.byteLen() });
        defer self.allocator.free(bytes);
        if (!std.mem.eql(u8, bytes, if (empty) "" else "disk\n") or record.dirty()) return error.WrongCleanContent;
    }
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 4) return error.ExpectedModeRootHome;
    const mode = args[1];
    const root = args[2];
    const home = args[3];
    close_after_checkpoint = std.mem.eql(u8, mode, "close-clean") or std.mem.eql(u8, mode, "close-discard");
    discard_window = std.mem.eql(u8, mode, "close-discard");
    const seed = std.mem.eql(u8, mode, "seed") or std.mem.eql(u8, mode, "discard") or discard_window;
    discard_after_checkpoint = std.mem.eql(u8, mode, "discard");
    marker = try std.fs.path.join(init.arena.allocator(), &.{ root, "checkpoint.ready" });
    const settings = try std.fs.path.join(init.arena.allocator(), &.{ root, "settings.json" });
    var app = try ui.App.init(.{ .allocator = init.gpa });
    defer app.deinit();
    var shell = try Shell.init(init.gpa, init.io, root, if (seed or close_after_checkpoint) "file.txt" else null);
    const handle = app.openWindow(Shell, .{ .visible = false, .width = 1000, .height = 700 }, shell) catch |err| {
        shell.deinit(init.gpa);
        return err;
    };
    const owner = try app.windowEntity(Shell, handle);
    try app.update(owner, Ops.configure, .{settings});
    try app.update(owner, Shell.initRecovery, .{home});
    try app.update(owner, Shell.bootstrap, .{handle});
    if (std.mem.eql(u8, mode, "verify-clean") or std.mem.eql(u8, mode, "verify-empty")) {
        try app.read(owner, Ops.verifyClean, .{std.mem.eql(u8, mode, "verify-empty")});
        return;
    }
    if (close_after_checkpoint and !discard_window) {
        try app.update(owner, Ops.command, .{.toggle_vim});
        try app.watchExternal(owner, Ops.acknowledge);
        try app.run();
        return;
    }
    if (!seed) {
        const external = std.mem.eql(u8, mode, "verify-conflict");
        try app.read(owner, Ops.verify, .{ external, std.mem.eql(u8, mode, "verify-discard") });
        if (external) try app.update(owner, Ops.verifyConflict, .{});
        std.debug.print("recovery verification passed: {s}\n", .{mode});
        return;
    }
    _ = try app.step(ui.testing.native.now());
    try app.dispatch(handle, .{ .text = "dirty 日本語 " });
    try app.update(owner, Ops.command, .{.new_file});
    _ = try app.step(ui.testing.native.now());
    try app.dispatch(handle, .{ .text = untitled });
    try app.update(owner, Ops.command, .{.split_down});
    try app.update(owner, Ops.command, .{.toggle_vim});
    try app.update(owner, Ops.place, .{});
    try app.watchExternal(owner, Ops.acknowledge);
    // Native run must wake for the checkpoint deadline after the final input.
    // The parent waits for acknowledgment, then kills us without destructors.
    try app.run();
}
