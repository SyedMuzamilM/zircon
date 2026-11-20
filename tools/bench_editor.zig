//! Release baseline of real Shell dispatch through native frame submission.
//! It does not measure physical input or display scanout. Fixtures are caller-owned.
const std = @import("std");
const zircon = @import("zircon");
const git = @import("zircon_git");
const ui = @import("zircon_ui");
const Shell = zircon.Shell;
const Counts = struct {
    git_commands: u64 = 0,
    git_status: u64 = 0,
    git_history: u64 = 0,
    git_errors: u64 = 0,
    lsp_messages: u64 = 0,
    lsp_bytes: u64 = 0,
    lsp_changes: u64 = 0,
    syntax_jobs: u64 = 0,
    wrap_builds: usize = 0,
    shaped_lines: usize = 0,
    fold_scanned_bytes: u64 = 0,
};
const Ops = struct {
    fn explainWait(self: *const Shell) void {
        std.debug.print("Wait state: status={s}; error={}; git_busy={}; syntax_waiting={}\n", .{ self.status, self.status_is_error, self.git.busy, self.language.syntax_waiting });
        for (self.language.syntax_documents.items) |doc| std.debug.print("syntax pending={} revision={?}\n", .{ doc.pending, doc.revision });
        for (self.language.documents.items) |doc| std.debug.print("LSP version={?} diagnostics={}\n", .{ doc.version, doc.diagnostics != null });
        for (self.language.sessions.items) |session| if (session.client) |client| {
            std.debug.print("LSP state={s} stats={any}\n", .{ @tagName(client.status()), client.stats() });
        };
        for (self.tabs.items) |tab| std.debug.print("editor grammar revision={?}\n", .{tab.editor.grammar_revision});
    }
    fn configure(self: *Shell, cx: *ui.Context(Shell), root: []const u8, services: bool) !void {
        const settings = try std.fs.path.join(self.allocator, &.{ root, "settings.json" });
        defer self.allocator.free(settings);
        try self.loadSettings(cx, settings);
        if (services) {
            const home = try std.fs.path.join(self.allocator, &.{ root, "extensions" });
            defer self.allocator.free(home);
            try self.loadExtensions(cx, home);
        }
        self.inline_blame_enabled = false;
    }
    fn place(self: *Shell, cx: *ui.Context(Shell)) !void {
        const tab = &self.tabs.items[self.active];
        var source = try self.workspace.snapshot(tab.document);
        defer source.deinit();
        const at = try source.lineStart(source.lineCount() / 2);
        try tab.editor.setSelection(source, .{ .start = at, .end = at });
        tab.editor.reveal(source);
        self.editor_focus_request +%= 1;
        cx.notify();
    }
    fn ready(self: *const Shell, services: bool) bool {
        if (self.git.busy or self.language.syntax_waiting) return false;
        for (self.language.syntax_documents.items) |doc| if (doc.pending) return false;
        if (services) {
            if (!self.git.repository or self.git.needs_refresh) return false;
            if (self.language.documents.items.len == 0) return false;
            for (self.language.sessions.items) |session| if (session.client == null or !session.client.?.ready()) return false;
            for (self.language.documents.items) |doc| {
                const record = self.workspace.getConst(doc.id) catch return false;
                if (doc.version == null or doc.version.? != record.doc.revision() or doc.diagnostics == null or doc.diagnostics.?.data.diagnostics.version != doc.version) return false;
            }
            for (self.tabs.items) |tab| {
                const record = self.workspace.getConst(tab.document) catch return false;
                if (tab.editor.git_revision != record.doc.revision()) return false;
                if (tab.editor.grammar_revision == null or tab.editor.grammar_revision.? != record.doc.revision()) return false;
            }
        }
        return true;
    }
    fn verifyWrap(self: *const Shell, wrap: bool) !void {
        const tab = self.tabs.items[self.active];
        const record = try self.workspace.getConst(tab.document);
        var source = record.doc.snapshot();
        defer source.deinit();
        if ((tab.editor.soft_wrap != .none) != wrap) return error.WrongWrapConfiguration;
        if (wrap and (tab.editor.wrap_cache.builds == 0 or tab.editor.wrap_cache.rowCount() <= source.lineCount())) return error.WrapWorkDidNotHappen;
    }
    fn counts(self: *const Shell) Counts {
        const g = git.processStats();
        var result: Counts = .{ .git_commands = g.commands, .git_status = g.status, .git_history = g.history, .git_errors = g.run_errors, .syntax_jobs = self.language.syntax_jobs };
        for (self.language.sessions.items) |session| if (session.client) |client| {
            const s = client.stats();
            result.lsp_messages += s.queued_messages;
            result.lsp_bytes += s.queued_bytes;
            result.lsp_changes += s.document_changes;
        };
        for (self.tabs.items) |tab| {
            result.wrap_builds += tab.editor.wrap_cache.builds;
            result.shaped_lines += tab.editor.wrap_cache.shaped_lines;
            result.fold_scanned_bytes += tab.editor.wrap_cache.folding.scanned_bytes;
        }
        return result;
    }
    fn verify(self: *const Shell, expected: []const u8, edits: usize) !u64 {
        if (self.status_is_error or self.git.error_text.len > 0) return error.BackgroundServiceFailed;
        var source = try self.workspace.snapshot(self.tabs.items[self.active].document);
        defer source.deinit();
        if (source.revision() != edits or source.byteLen() != expected.len) return error.IncorrectEditWork;
        const bytes = try source.copy(self.allocator, .{ .start = 0, .end = source.byteLen() });
        defer self.allocator.free(bytes);
        if (!std.mem.eql(u8, expected, bytes)) return error.SourceBytesChanged;
        if (!(try self.workspace.dirty(self.tabs.items[self.active].document))) return error.EditsDidNotReachDocument;
        return source.revision();
    }
    fn checkServices(self: *const Shell) !void {
        if (!self.status_is_error) return;
        explainWait(self);
        return error.BackgroundServiceFailed;
    }
};
fn settle(app: *ui.App, owner: ui.Entity(Shell), io: std.Io, services: bool) !void {
    const deadline = ui.testing.native.now() + 60;
    var idle: usize = 0;
    while (idle < 3) {
        _ = try app.step(ui.testing.native.now());
        idle = if (!(try app.tasksPending()) and try app.read(owner, Ops.ready, .{services})) idle + 1 else 0;
        if (ui.testing.native.now() > deadline) {
            try app.read(owner, Ops.explainWait, .{});
            return error.BackgroundTimeout;
        }
        try std.Io.sleep(io, .fromMilliseconds(5), .awake);
    }
}
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 5) return error.ExpectedRootWrapServicesAndResultPath;
    const root = args[1];
    const wrap = std.mem.eql(u8, args[2], "wrap");
    const services = std.mem.eql(u8, args[3], "services");
    const a = init.gpa;
    const source_path = try std.fs.path.join(init.arena.allocator(), &.{ root, "main.py" });
    const expected = try std.Io.Dir.cwd().readFileAlloc(init.io, source_path, a, .limited(64 * 1024 * 1024));
    defer a.free(expected);
    var app = try ui.App.init(.{ .allocator = a });
    defer app.deinit();
    const started = ui.testing.native.now();
    const h = try app.openWindow(Shell, .{ .visible = false, .chrome = .integrated, .width = 1240, .height = 820 }, try Shell.init(a, init.io, root, source_path));
    const owner = try app.windowEntity(Shell, h);
    try app.update(owner, Ops.configure, .{ root, services });
    try app.update(owner, Shell.bootstrap, .{h});
    try settle(&app, owner, init.io, services);
    try app.read(owner, Ops.verifyWrap, .{wrap});
    const ready_ms = (ui.testing.native.now() - started) * 1000;
    try app.update(owner, Ops.place, .{});
    try settle(&app, owner, init.io, services);
    const before = try app.read(owner, Ops.counts, .{});
    const frames_before = (try app.window(h)).frame_count;
    const ready_path = try std.fmt.allocPrint(init.arena.allocator(), "{s}.ready", .{args[4]});
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = ready_path, .data = "input workload begins\n" });
    var samples: [20]f64 = undefined;
    var dispatch_samples: [20]f64 = undefined;
    var pump_samples: [20]f64 = undefined;
    for (&samples, &dispatch_samples, &pump_samples, 0..) |*sample, *dispatch_sample, *pump_sample, i| {
        const start = ui.testing.native.now();
        try app.dispatch(h, if (i % 2 == 0) .{ .text = "x" } else .{ .key_down = .{ .key = .backspace } });
        const dispatched = ui.testing.native.now();
        const painted = try app.step(dispatched);
        const submitted = ui.testing.native.now();
        if (painted == 0) return error.EditFrameNotSubmitted;
        dispatch_sample.* = (dispatched - start) * 1000;
        pump_sample.* = (submitted - dispatched) * 1000;
        sample.* = (submitted - start) * 1000;
        if (services) try app.read(owner, Ops.checkServices, .{});
        // Leave a 50 ms idle gap between inputs for actual owned workers.
        try std.Io.sleep(init.io, .fromMilliseconds(50), .awake);
    }
    const settling = ui.testing.native.now();
    try settle(&app, owner, init.io, services);
    const settle_ms = (ui.testing.native.now() - settling) * 1000;
    const revision = try app.read(owner, Ops.verify, .{ expected, samples.len });
    const after = try app.read(owner, Ops.counts, .{});
    var delta: Counts = undefined;
    inline for (@typeInfo(Counts).@"struct".field_names) |name| @field(delta, name) = @field(after, name) - @field(before, name);
    if (delta.git_errors > 0 or (services and (delta.git_status == 0 or delta.lsp_changes != samples.len or delta.syntax_jobs == 0)) or (wrap and delta.wrap_builds != samples.len)) {
        std.debug.print("Work counters: {any}\n", .{delta});
        try app.read(owner, Ops.explainWait, .{});
        return error.ServicesDidNotRun;
    }
    const output = try std.json.Stringify.valueAlloc(a, .{ .source_bytes = expected.len, .wrap = wrap, .services = services, .ready_ms = ready_ms, .input_to_submit_ms = samples, .dispatch_ms = dispatch_samples, .step_ms = pump_samples, .settle_ms = settle_ms, .counts = delta, .frames = (try app.window(h)).frame_count - frames_before, .revision = revision, .errors = @as(u8, 0) }, .{});
    defer a.free(output);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = args[4], .data = output });
}
