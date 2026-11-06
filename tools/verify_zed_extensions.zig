//! Opt-in native journey using previously downloaded official extension bundles.
const std = @import("std");
const ui = @import("zircon_ui");
const appmod = @import("zircon");
const ext = @import("zircon_extensions");
const Shell = appmod.Shell;
const Ops = struct {
    fn healthy(self: *const Shell) bool {
        const tab = self.tabs.items[self.active];
        if (tab.editor.grammar_revision != (self.workspace.getConst(tab.document) catch return false).doc.revision() or tab.editor.grammar_spans.len == 0) return false;
        for (self.language.documents.items) |document| if (std.meta.eql(document.id, tab.document)) {
            if (self.language.sessions.items[document.session].client) |client| return client.ready() and document.version != null;
        };
        return false;
    }
    fn python(self: *Shell, cx: *ui.Context(Shell)) !void {
        self.language.clearCompletion();
        try self.openPath("sample.py");
        cx.notify();
    }
    fn cursor(self: *Shell, cx: *ui.Context(Shell), at: usize) !void {
        var snapshot = try self.workspace.snapshot(self.tabs.items[self.active].document);
        defer snapshot.deinit();
        try self.tabs.items[self.active].editor.setSelection(snapshot, .{ .start = at, .end = at });
        cx.notify();
    }
    fn complete(self: *Shell, cx: *ui.Context(Shell)) !void {
        var e: ui.Event(ui.Click) = .{ .data = .{} };
        try self.onCommand(&e, cx, .complete);
    }
    fn completion(self: *const Shell) bool {
        return self.language.completions != null and self.language.completions.?.data.completion.items.len > 0;
    }
    fn command(self: *Shell, cx: *ui.Context(Shell), which: appmod.Command) !void {
        var event: ui.Event(ui.Click) = .{ .data = .{} };
        try self.onCommand(&event, cx, which);
    }
    fn browse(self: *Shell, cx: *ui.Context(Shell)) !void {
        self.language.clearCompletion();
        self.catalog.show_available = true;
        self.panel = .extensions;
        const Set = struct {
            fn call(field: *ui.controls.TextInput, context: *ui.Context(ui.controls.TextInput)) !void {
                const value = "catppuccin";
                try field.bytes.ensureTotalCapacity(field.allocator, value.len);
                field.bytes.clearRetainingCapacity();
                field.bytes.appendSliceAssumeCapacity(value);
                field.cursor = value.len;
                field.anchor = value.len;
                field.revision +%= 1;
                context.notify();
            }
        };
        try cx.update(self.fields.?.extension_query, Set.call, .{});
        try command(self, cx, .extension_search);
    }
    fn remotelyInstalled(self: *const Shell) bool {
        return self.catalog.installing == null and self.extension_snapshot != null and self.extension_snapshot.?.extension("zed.catppuccin-black-theme") != null;
    }
    fn accepted(self: *const Shell) bool {
        const record = self.workspace.getConst(self.tabs.items[self.active].document) catch return false;
        var source = record.doc.snapshot();
        defer source.deinit();
        return (source.find(".AutoHashMap", 0, .forward, true) catch return false) != null;
    }
    fn catalogReady(self: *const Shell) bool {
        return !self.catalog.busy and self.catalog.parsed != null and self.catalog.parsed.?.value.total > 1000 and self.catalog.parsed.?.value.entries.len > 0;
    }
    fn light(self: *Shell, cx: *ui.Context(Shell)) !void {
        try cx.update(self.settings.?, appmod.Settings.apply, .{appmod.SettingsPatch{ .theme = "zed.catppuccin.theme.catppuccin-latte" }});
        try cx.update(self.settings.?, appmod.Settings.apply, .{appmod.SettingsPatch{ .icon_theme = "zed.catppuccin-icons.icons.catppuccin-latte" }});
    }
    fn stop(self: *Shell, cx: *ui.Context(Shell)) !void {
        try self.extensions.?.setEnabled("zed.zig", false);
        try @import("zircon").refreshExtensions(self, cx);
    }
    fn stopped(self: *const Shell) bool {
        return self.language.sessions.items.len == 0 and self.tabs.items[0].editor.language == .zig;
    }
    fn failed(self: *const Shell) bool {
        for (self.language.sessions.items) |session| if (session.client) |client| {
            if (client.status() == .failed or client.status() == .exited) return true;
        };
        return false;
    }
    fn status(self: *const Shell) void {
        const state = self.tabs.items[0].editor;
        std.debug.print("Native extension journey: {s}; language={s} highlights={d} revision={?d}; sessions={d} documents={d} syntax={d}\n", .{ self.status, @tagName(state.language), state.grammar_spans.len, state.grammar_revision, self.language.sessions.items.len, self.language.documents.items.len, self.language.syntax_documents.items.len });
        for (self.language.sessions.items) |session| std.debug.print("server {s} resolving={} state={s}\n", .{ session.id, session.resolving, if (session.client) |client| @tagName(client.status()) else "none" });
        for (self.language.sessions.items) |session| if (session.client) |client| {
            client.lock.lockUncancelable(client.io);
            defer client.lock.unlock(client.io);
            std.debug.print("server stderr: {s}\n", .{client.stderr_bytes.items});
        };
        for (self.language.syntax_documents.items) |entry| std.debug.print("syntax revision={?d} pending={}\n", .{ entry.revision, entry.pending });
    }
};
fn click(app: *ui.App, io: std.Io, h: ui.WindowHandle, label: []const u8) !void {
    try step(app, io);
    const frame = &(try app.window(h)).frames.committed;
    for (frame.nodes.items, 0..) |node, i| if (node.kind == .button and node.kind.button.on_click != null and std.mem.eql(u8, node.kind.button.label, label)) {
        const r = frame.bounds[i];
        const point: ui.Point = .{ .x = r.x + r.width / 2, .y = r.y + r.height / 2 };
        try app.dispatch(h, .{ .pointer_down = .{ .position = point } });
        try app.dispatch(h, .{ .pointer_up = .{ .position = point } });
        return;
    };
    return error.MissingNativeControl;
}
fn step(app: *ui.App, io: std.Io) !void {
    _ = try app.step(@as(f64, @floatFromInt(std.Io.Clock.awake.now(io).nanoseconds)) / 1_000_000_000);
}
fn wait(app: *ui.App, owner: ui.Entity(Shell), io: std.Io, comptime check: anytype) !void {
    const end = std.Io.Clock.awake.now(io).addDuration(.fromSeconds(60));
    while (!try app.read(owner, check, .{})) {
        try step(app, io);
        if (try app.read(owner, Ops.failed, .{})) {
            try app.read(owner, Ops.status, .{});
            return error.LanguageServerExited;
        }
        if (std.Io.Clock.awake.now(io).compare(.gte, end)) {
            try app.read(owner, Ops.status, .{});
            return error.ExtensionJourneyTimeout;
        }
        std.Io.sleep(io, .fromMilliseconds(2), .awake) catch {};
    }
    try step(app, io);
}
pub fn main(init: std.process.Init) !void {
    const a = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3) return error.ExpectedFixtureAndNewOutputDirectory;
    try std.Io.Dir.cwd().createDir(io, args[2], .default_dir);
    const root = try std.fs.path.join(a, &.{ args[2], "project" });
    defer a.free(root);
    const home = try std.fs.path.join(a, &.{ args[2], "extensions" });
    defer a.free(home);
    try std.Io.Dir.cwd().createDirPath(io, root);
    const file = try std.fs.path.join(a, &.{ root, "main.zig" });
    defer a.free(file);
    const source = "const std = @import(\"std\");\npub fn main() void {\n    std.debug.print(\"A long source string that should wrap across a narrow editor viewport without changing the file.\\n\", .{});\n    std.\n}\n";
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = file, .data = source });
    {
        var registry = try ext.Registry.init(a, io, home);
        defer registry.deinit();
        for ([_][]const u8{ "zig", "catppuccin", "catppuccin-icons", "python" }) |id| {
            const bundle = try std.fs.path.join(a, &.{ args[1], id });
            defer a.free(bundle);
            _ = try registry.install(bundle);
        }
    }
    const settings = try std.fs.path.join(a, &.{ args[2], "settings.json" });
    defer a.free(settings);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = settings, .data = "{\"theme\":\"zed.catppuccin.theme.catppuccin-mocha\",\"icon_theme\":\"zed.catppuccin-icons.icons.catppuccin-mocha\",\"soft_wrap\":\"editor_width\"}" });
    const pyfile = try std.fs.path.join(a, &.{ root, "sample.py" });
    defer a.free(pyfile);
    const python = "message = \"Hello from Python\"\nmessage.\n";
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = pyfile, .data = python });
    var app = try ui.App.init(.{ .allocator = a });
    defer app.deinit();
    const worker = try std.Io.Dir.cwd().realPathFileAlloc(io, "tools/zed-extension-host/target/release/zircon-extension-host", a);
    defer a.free(worker);
    var shell = try Shell.init(a, io, root, "main.zig");
    shell.extension_host_path = worker;
    const h = try app.openWindow(Shell, .{ .title = "Zed extensions journey", .chrome = .integrated, .visible = false, .width = 1000, .height = 650 }, shell);
    const owner = try app.windowEntity(Shell, h);
    try app.update(owner, Shell.loadSettings, .{@as(?[]const u8, settings)});
    try app.update(owner, Shell.bootstrap, .{h});
    try app.update(owner, Shell.loadExtensions, .{home});
    try wait(&app, owner, io, Ops.healthy);
    const image = try std.fs.path.join(a, &.{ args[2], "official-zig-theme-icons-wrap.png" });
    defer a.free(image);
    try (try app.window(h)).snapshot(image);
    const at = (std.mem.indexOf(u8, source, "    std.\n") orelse return error.FixtureCursorMissing) + 8;
    try app.update(owner, Ops.cursor, .{at});
    try step(&app, io);
    try app.dispatch(h, .{ .key_down = .{ .key = .backspace } });
    try app.dispatch(h, .{ .text = "." });
    try wait(&app, owner, io, Ops.completion);
    const completed = try std.fs.path.join(a, &.{ args[2], "official-zls-completion.png" });
    defer a.free(completed);
    try (try app.window(h)).snapshot(completed);
    try app.dispatch(h, .{ .key_down = .{ .key = .enter } });
    if (!try app.read(owner, Ops.accepted, .{})) return error.RealCompletionNotAccepted;
    try app.update(owner, Ops.command, .{.undo});
    try wait(&app, owner, io, Ops.healthy);
    try app.update(owner, Ops.python, .{});
    try wait(&app, owner, io, Ops.healthy);
    try app.update(owner, Ops.cursor, .{python.len - 1});
    try step(&app, io);
    try app.update(owner, Ops.complete, .{});
    try wait(&app, owner, io, Ops.completion);
    const pycapture = try std.fs.path.join(a, &.{ args[2], "python-pyright-completion.png" });
    defer a.free(pycapture);
    try (try app.window(h)).snapshot(pycapture);
    try app.update(owner, Ops.command, .{.extensions});
    try step(&app, io);
    const installed_capture = try std.fs.path.join(a, &.{ args[2], "extensions-installed.png" });
    defer a.free(installed_capture);
    try (try app.window(h)).snapshot(installed_capture);
    try app.update(owner, Ops.browse, .{});
    try wait(&app, owner, io, Ops.catalogReady);
    const catalog_capture = try std.fs.path.join(a, &.{ args[2], "extensions-catalog.png" });
    defer a.free(catalog_capture);
    try (try app.window(h)).snapshot(catalog_capture);
    try click(&app, io, h, "Install");
    try wait(&app, owner, io, Ops.remotelyInstalled);
    try app.update(owner, Ops.command, .{.back_to_editor});
    try app.update(owner, Ops.light, .{});
    try step(&app, io);
    const light_capture = try std.fs.path.join(a, &.{ args[2], "python-light-theme.png" });
    defer a.free(light_capture);
    try (try app.window(h)).snapshot(light_capture);
    try app.update(owner, Ops.stop, .{});
    if (!try app.read(owner, Ops.stopped, .{})) return error.ExtensionDidNotDeactivate;
    std.debug.print("Official Zig/ZLS + bundled Python/Pyright + Catppuccin themes/icons + wrapping + deactivate passed.\n", .{});
}
