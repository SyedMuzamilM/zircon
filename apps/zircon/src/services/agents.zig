//! Native agent workspace. Provider CLIs retain their own credentials and tools.
const std = @import("std");
const ui = @import("zircon_ui");
const agent = @import("zircon_agent");
const text = @import("zircon_text");
const editor = @import("zircon_editor");
const Shell = @import("../shell.zig").Shell;
const md = @import("../views/markdown.zig");
pub const Provider = struct { name: []const u8, protocol: agent.Protocol, command: []const u8, args: []const []const u8 = &.{}, env: std.json.Value = .null, env_from: std.json.Value = .null, secret_env: std.json.Value = .null };
const Config = struct { providers: []const Provider };
pub const defaults =
    \\{"providers":[{"name":"Codex","protocol":"codex","command":"codex","args":["app-server"]},{"name":"OpenCode","protocol":"acp","command":"opencode","args":["acp"]},{"name":"Gemini","protocol":"acp","command":"gemini","args":["--experimental-acp"]}]}
;
pub const Composer = struct {
    document: text.Document,
    editor: editor.Editor,
    fn deinit(self: *Composer) void {
        self.editor.deinit();
        self.document.deinit();
    }
};
pub const Session = struct {
    provider: []u8,
    title: []u8,
    draft: []u8 = &.{},
    path: ?[]u8 = null,
    conversation: agent.Conversation,
    document: text.Document,
    preview: md.Preview,
    rendered: u64 = 0,
    saved: u64 = 0,
    last_render: i96 = 0,
    follow: bool = true,
    fn deinit(self: *Session, a: std.mem.Allocator) void {
        self.conversation.deinit();
        self.preview.deinit();
        self.document.deinit();
        a.free(self.provider);
        a.free(self.title);
        a.free(self.draft);
        if (self.path) |p| a.free(p);
        a.destroy(self);
    }
};
pub const Picker = enum { none, providers, models, modes, efforts };
pub const Model = struct {
    config: ?std.json.Parsed(Config) = null,
    home: ?[]u8 = null,
    config_path: ?[]u8 = null,
    environment: ?*const std.process.Environ.Map = null,
    sessions: std.ArrayList(*Session) = .empty,
    active: usize = 0,
    provider: usize = 0,
    history_loaded: bool = false,
    composer: ?Composer = null,
    focus: u64 = 0,
    picker: Picker = .none,
    picker_index: usize = 0,
    session_scroll: ui.controls.Scroll = .{},
    pub fn deinit(self: *Model, a: std.mem.Allocator) void {
        for (self.sessions.items) |session| session.deinit(a);
        self.sessions.deinit(a);
        if (self.composer) |*composer| composer.deinit();
        if (self.config) |*config| config.deinit();
        if (self.home) |home| a.free(home);
        if (self.config_path) |path| a.free(path);
    }
    pub fn current(self: *const Model) ?*Session {
        return if (self.sessions.items.len > 0) self.sessions.items[@min(self.active, self.sessions.items.len - 1)] else null;
    }
};
pub fn configure(self: *Shell, _: *ui.Context(Shell), home: []const u8, environment: ?*const std.process.Environ.Map) !void {
    const owned = try self.allocator.dupe(u8, home);
    errdefer self.allocator.free(owned);
    const path = try std.fs.path.join(self.allocator, &.{ home, "agents.json" });
    if (self.agents.home) |old| self.allocator.free(old);
    if (self.agents.config_path) |old| self.allocator.free(old);
    self.agents.home = owned;
    self.agents.config_path = path;
    self.agents.environment = environment;
}
pub fn ensure(self: *Shell) !void {
    if (self.agents.config == null) try reload(self);
    if (self.agents.composer == null) {
        var state = try editor.Editor.init(self.allocator);
        errdefer state.deinit();
        state.show_line_numbers = false;
        state.soft_wrap = .editor_width;
        state.theme = self.editor_options.theme;
        self.agents.composer = .{ .editor = state, .document = try text.Document.init(self.allocator, "") };
    }
    if (!self.agents.history_loaded) {
        self.agents.history_loaded = true;
        try loadHistory(self);
    }
}
pub fn reload(self: *Shell) !void {
    const bytes = if (self.agents.config_path) |path| std.Io.Dir.cwd().readFileAlloc(self.workspace.io, path, self.allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    } else null;
    defer if (bytes) |b| self.allocator.free(b);
    var next = try std.json.parseFromSlice(Config, self.allocator, bytes orelse defaults, .{ .allocate = .alloc_always, .ignore_unknown_fields = false });
    errdefer next.deinit();
    if (next.value.providers.len == 0 or next.value.providers.len > 64) return error.InvalidAgentProviders;
    for (next.value.providers, 0..) |provider, i| {
        if (provider.name.len == 0 or provider.command.len == 0 or provider.args.len > 128) return error.InvalidAgentProviders;
        for (next.value.providers[0..i]) |old| if (std.mem.eql(u8, old.name, provider.name)) return error.DuplicateAgentProvider;
    }
    if (self.agents.config) |*old| old.deinit();
    self.agents.config = next;
    self.agents.provider = @min(self.agents.provider, next.value.providers.len - 1);
}
pub fn newSession(self: *Shell) !void {
    try ensure(self);
    try createSession(self);
}
fn createSession(self: *Shell) !void {
    try storeDraft(self);
    if (self.agents.sessions.items.len >= 100) return error.TooManyAgentSessions;
    const a = self.allocator;
    const record = try a.create(Session);
    errdefer a.destroy(record);
    const provider = try a.dupe(u8, self.agents.config.?.value.providers[self.agents.provider].name);
    errdefer a.free(provider);
    const title = try a.dupe(u8, "New conversation");
    errdefer a.free(title);
    var doc = try text.Document.init(a, "");
    errdefer doc.deinit();
    doc.setHistoryLimit(0);
    var snapshot = doc.snapshot();
    defer snapshot.deinit();
    var preview = try md.Preview.init(a, self.workspace.io, null, snapshot);
    preview.colors = self.previewColors();
    errdefer preview.deinit();
    record.* = .{ .provider = provider, .title = title, .conversation = agent.Conversation.init(a), .document = doc, .preview = preview };
    try self.agents.sessions.append(a, record);
    self.agents.active = self.agents.sessions.items.len - 1;
    try resetComposer(self, "");
    self.agents.focus +%= 1;
}
fn wake(_: ?*anyopaque) void {
    ui.App.wake();
}
pub fn connect(self: *Shell) !void {
    try ensure(self);
    if (self.agents.current() == null) try newSession(self);
    const session = self.agents.current().?;
    if (session.conversation.state == .running or session.conversation.state == .permission) return error.AgentBusy;
    for (self.agents.config.?.value.providers) |provider| if (std.mem.eql(u8, provider.name, session.provider)) {
        var environment = if (self.agents.environment) |base| try base.clone(self.allocator) else std.process.Environ.Map.init(self.allocator);
        defer environment.deinit();
        if (provider.env != .null) {
            if (provider.env != .object) return error.InvalidAgentEnvironment;
            var entries = provider.env.object.iterator();
            while (entries.next()) |entry| {
                if (entry.value_ptr.* != .string) return error.InvalidAgentEnvironment;
                try environment.put(entry.key_ptr.*, entry.value_ptr.string);
            }
        }
        if (provider.env_from != .null) {
            if (provider.env_from != .object) return error.InvalidAgentEnvironment;
            var entries = provider.env_from.object.iterator();
            while (entries.next()) |entry| {
                if (entry.value_ptr.* != .string) return error.InvalidAgentEnvironment;
                const source = self.agents.environment orelse return error.AgentEnvironmentUnavailable;
                const value = source.get(entry.value_ptr.string) orelse return error.AgentEnvironmentVariableMissing;
                try environment.put(entry.key_ptr.*, value);
            }
        }
        if (provider.secret_env != .null) {
            if (provider.secret_env != .object) return error.InvalidAgentEnvironment;
            var entries = provider.secret_env.object.iterator();
            while (entries.next()) |entry| {
                if (entry.value_ptr.* != .string) return error.InvalidAgentEnvironment;
                const bytes = try std.Io.Dir.cwd().readFileAlloc(self.workspace.io, entry.value_ptr.string, self.allocator, .limited(64 * 1024));
                defer {
                    @memset(bytes, 0);
                    self.allocator.free(bytes);
                }
                const value = std.mem.trim(u8, bytes, "\r\n");
                if (value.len == 0) return error.AgentCredentialFileEmpty;
                try environment.put(entry.key_ptr.*, value);
            }
        }
        const has_environment = self.agents.environment != null or provider.env != .null or provider.env_from != .null or provider.secret_env != .null;
        const config: agent.transport.Config = .{ .command = provider.command, .args = provider.args, .cwd = self.workspace.root_path, .wake = .{ .notify = wake }, .environ_map = if (has_environment) &environment else null };
        if (session.conversation.session.len > 0) try session.conversation.reconnect(self.workspace.io, config, provider.protocol) else try session.conversation.connect(self.workspace.io, config, provider.protocol);
        return;
    };
    return error.AgentProviderRemoved;
}
pub fn send(self: *Shell, cx: *ui.Context(Shell)) !void {
    try ensure(self);
    const session = self.agents.current() orelse return error.ConnectAgentFirst;
    const compose = &self.agents.composer.?;
    var snapshot = compose.document.snapshot();
    defer snapshot.deinit();
    const bytes = try snapshot.copy(self.allocator, .{ .start = 0, .end = snapshot.byteLen() });
    defer self.allocator.free(bytes);
    try session.conversation.prompt(bytes);
    session.follow = true;
    if (std.mem.eql(u8, session.title, "New conversation")) {
        var end = @min(bytes.len, 48);
        while (end > 0 and end < bytes.len and bytes[end] & 0xc0 == 0x80) end -= 1;
        const title = try self.allocator.dupe(u8, bytes[0..end]);
        for (title) |*ch| if (ch.* == '\n' or ch.* == '\r' or ch.* == '\t') {
            ch.* = ' ';
        };
        self.allocator.free(session.title);
        session.title = title;
    }
    var result = try compose.editor.replaceAll(&compose.document, bytes, "");
    if (result.change) |*change| change.deinit();
    try refresh(self, session, true);
    try persist(self, session);
    self.agents.focus +%= 1;
    cx.notify();
}
pub fn refresh(self: *Shell, session: *Session, force: bool) !void {
    session.preview.colors = self.previewColors();
    if (session.rendered == session.conversation.revision) return;
    const now = std.Io.Clock.awake.now(self.workspace.io).toNanoseconds();
    if (!force and session.conversation.state == .running and now - session.last_render < 80 * std.time.ns_per_ms) return;
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(self.allocator);
    const display_limit = 256 * 1024;
    var first = session.conversation.entries.items.len;
    var visible_bytes: usize = 0;
    while (first > 0) {
        const length = session.conversation.entries.items[first - 1].text.items.len;
        if (visible_bytes > 0 and visible_bytes + length > display_limit) break;
        visible_bytes += length;
        first -= 1;
        if (visible_bytes >= display_limit) break;
    }
    if (first > 0) try bytes.appendSlice(self.allocator, "Earlier messages are saved in the conversation transcript.\n\n");
    for (session.conversation.entries.items[first..]) |entry| {
        const title = switch (entry.role) {
            .user => "You",
            .assistant => session.provider,
            .activity => "Activity",
            .error_value => "Agent error",
        };
        try bytes.appendSlice(self.allocator, "### ");
        try bytes.appendSlice(self.allocator, title);
        try bytes.appendSlice(self.allocator, "\n\n");
        var start = entry.text.items.len -| display_limit;
        while (start < entry.text.items.len and entry.text.items[start] & 0xc0 == 0x80) start += 1;
        try bytes.appendSlice(self.allocator, entry.text.items[start..]);
        try bytes.appendSlice(self.allocator, "\n\n");
    }
    var before = session.document.snapshot();
    defer before.deinit();
    var change = try session.document.apply(session.document.revision(), &.{.{ .range = .{ .start = 0, .end = before.byteLen() }, .text = bytes.items }}, 0);
    defer change.deinit();
    var source = session.document.snapshot();
    defer source.deinit();
    try session.preview.refresh(source);
    session.preview.follow_end = session.follow;
    session.rendered = session.conversation.revision;
    session.last_render = now;
}
pub fn poll(self: *Shell, cx: *ui.Context(Shell)) !void {
    for (self.agents.sessions.items) |session| {
        const old = session.conversation.state;
        const changed = try session.conversation.poll();
        const pending = session.rendered != session.conversation.revision;
        if (changed or pending) {
            try refresh(self, session, false);
            cx.notify();
        }
        if ((changed or pending) and session.conversation.state != .running and session.conversation.state != .permission) try persist(self, session);
        if ((old == .running or old == .permission) and session.conversation.state == .ready) {
            if (self.git.repository) try @import("git.zig").start(self, cx, .refresh);
            try @import("../actions.zig").refreshTree(self);
            for (self.tabs.items) |*tab| if (try self.workspace.reloadClean(tab.document)) {
                var source = try self.workspace.snapshot(tab.document);
                defer source.deinit();
                tab.editor.synchronize(source);
                if (self.secondary) |*pane| if (std.meta.eql(pane.document, tab.document)) pane.editor.synchronize(source);
                if (self.preview) |*preview| if (std.meta.eql(preview.document, tab.document)) try preview.view.refresh(source);
            };
        }
    }
}
fn persist(self: *Shell, session: *Session) !void {
    if (session.saved == session.conversation.revision) return;
    const home = self.agents.home orelse return;
    const a = self.allocator;
    const folder = try std.fmt.allocPrint(a, "{s}/agent-history/{x}", .{ home, std.hash.Wyhash.hash(0, self.workspace.root_path) });
    defer a.free(folder);
    try std.Io.Dir.cwd().createDirPath(self.workspace.io, folder);
    if (session.path == null) session.path = try std.fmt.allocPrint(a, "{s}/{d}.json", .{ folder, std.Io.Clock.real.now(self.workspace.io).toNanoseconds() });
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const Entry = struct { role: @TypeOf(session.conversation.entries.items[0].role), text: []const u8 };
    const entries = try arena.allocator().alloc(Entry, session.conversation.entries.items.len);
    for (entries, session.conversation.entries.items) |*out, entry| out.* = .{ .role = entry.role, .text = entry.text.items };
    const bytes = try std.json.Stringify.valueAlloc(arena.allocator(), .{ .project = self.workspace.root_path, .provider = session.provider, .title = session.title, .session_id = session.conversation.session, .model = session.conversation.model, .entries = entries }, .{ .whitespace = .indent_2 });
    const temp = try std.mem.concat(arena.allocator(), u8, &.{ session.path.?, ".tmp" });
    try std.Io.Dir.cwd().writeFile(self.workspace.io, .{ .sub_path = temp, .data = bytes, .flags = .{ .permissions = .fromMode(0o600) } });
    try std.Io.Dir.cwd().rename(temp, std.Io.Dir.cwd(), session.path.?, self.workspace.io);
    session.saved = session.conversation.revision;
}
pub fn editConfig(self: *Shell) !void {
    const path = self.agents.config_path orelse return error.AgentConfigPathUnavailable;
    if (std.Io.Dir.cwd().statFile(self.workspace.io, path, .{})) |_| {} else |err| switch (err) {
        error.FileNotFound => {
            if (std.fs.path.dirname(path)) |parent| try std.Io.Dir.cwd().createDirPath(self.workspace.io, parent);
            try std.Io.Dir.cwd().writeFile(self.workspace.io, .{ .sub_path = path, .data = defaults });
        },
        else => return err,
    }
    self.agent_mode = false;
    try self.openPath(path);
}

fn resetComposer(self: *Shell, bytes: []const u8) !void {
    var state = try editor.Editor.init(self.allocator);
    errdefer state.deinit();
    state.show_line_numbers = false;
    state.soft_wrap = .editor_width;
    state.theme = self.editor_options.theme;
    const document = try text.Document.init(self.allocator, bytes);
    if (self.agents.composer) |*old| old.deinit();
    self.agents.composer = .{ .document = document, .editor = state };
}
fn storeDraft(self: *Shell) !void {
    const session = self.agents.current() orelse return;
    const compose = &(self.agents.composer orelse return);
    var snapshot = compose.document.snapshot();
    defer snapshot.deinit();
    const bytes = try snapshot.copy(self.allocator, .{ .start = 0, .end = snapshot.byteLen() });
    self.allocator.free(session.draft);
    session.draft = bytes;
}
pub fn selectSession(self: *Shell, index: usize) !void {
    if (index >= self.agents.sessions.items.len) return;
    try storeDraft(self);
    try resetComposer(self, self.agents.sessions.items[index].draft);
    self.agents.active = index;
    self.agents.picker = .none;
    self.agents.focus +%= 1;
}
fn loadHistory(self: *Shell) !void {
    const home = self.agents.home orelse return;
    const a = self.allocator;
    const folder = try std.fmt.allocPrint(a, "{s}/agent-history/{x}", .{ home, std.hash.Wyhash.hash(0, self.workspace.root_path) });
    defer a.free(folder);
    var dir = std.Io.Dir.cwd().openDir(self.workspace.io, folder, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(self.workspace.io);
    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |name| a.free(name);
        names.deinit(a);
    }
    var it = dir.iterate();
    while (try it.next(self.workspace.io)) |entry| {
        if (names.items.len >= 100) break;
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".json")) continue;
        const name = try a.dupe(u8, entry.name);
        errdefer a.free(name);
        try names.append(a, name);
    }
    const Order = struct {
        fn less(_: void, left: []u8, right: []u8) bool {
            return std.mem.order(u8, left, right) == .gt;
        }
    };
    std.mem.sort([]u8, names.items, {}, Order.less);
    const Saved = struct { project: []const u8, provider: []const u8, title: []const u8, session_id: []const u8, model: []const u8, entries: []const struct { role: @import("zircon_agent").conversation_role, text: []const u8 } };
    for (names.items[0..@min(20, names.items.len)]) |name| {
        const bytes = dir.readFileAlloc(self.workspace.io, name, a, .limited(8 * 1024 * 1024)) catch continue;
        defer a.free(bytes);
        var saved = std.json.parseFromSlice(Saved, a, bytes, .{ .allocate = .alloc_always }) catch continue;
        defer saved.deinit();
        if (!std.mem.eql(u8, saved.value.project, self.workspace.root_path) or saved.value.entries.len > 10000) continue;
        try createSession(self);
        const record = self.agents.current().?;
        const provider = try a.dupe(u8, saved.value.provider);
        a.free(record.provider);
        record.provider = provider;
        const title = try a.dupe(u8, saved.value.title);
        a.free(record.title);
        record.title = title;
        record.path = try std.fs.path.join(a, &.{ folder, name });
        record.conversation.session = try a.dupe(u8, saved.value.session_id);
        record.conversation.model = try a.dupe(u8, saved.value.model);
        for (saved.value.entries) |entry| try record.conversation.append(entry.role, entry.text, false);
        record.saved = record.conversation.revision;
        try refresh(self, record, true);
    }
    if (self.agents.sessions.items.len > 0) try selectSession(self, 0);
}
