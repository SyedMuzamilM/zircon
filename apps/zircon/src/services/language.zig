//! UI-thread owner of persistent language servers. Transport threads publish
//! owned messages and wake AppKit; no transport thread borrows editor state.
const std = @import("std");
const zircon_editor = @import("zircon_editor");
const zircon_extensions = @import("zircon_extensions");
const lsp = @import("zircon_language");
const text = @import("zircon_text");
const ui = @import("zircon_ui");
const ws = @import("zircon_workspace");
const actions = @import("../actions.zig");
const model = @import("../settings/model.zig");
const shell = @import("../shell.zig");
const host = @import("extension_host.zig");
const symbol_hover = @import("symbol_hover.zig");
const workspace_edits = @import("workspace_edits.zig");
const Shell = shell.Shell;
const Session = struct { id: []u8, client: ?*lsp.Client, resolving: bool = false, scope: ?ws.DocumentId = null, retired: bool = false, epoch: u64 = 0 };
const SyntaxDocument = struct {
    id: ws.DocumentId,
    /// Last revision installed in the editors, never merely requested.
    revision: ?u64 = null,
    observed: ?u64 = null,
    changed_at: f64 = 0,
    pending: bool = false,
    epoch: u64 = 0,
    scoped: bool = false,
    attempts: u8 = 0,
    retry_at: f64 = 0,
    status_sequence: u64 = 0,
};
const Document = struct {
    id: ws.DocumentId,
    uri: []u8,
    path: []u8,
    session: usize,
    version: ?u64 = null,
    diagnostics: ?lsp.Message = null,
};
pub const Pending = struct { document: ws.DocumentId, session: usize, request: u64, revision: u64, cursor: usize };
const PendingDefinition = struct { document: ws.DocumentId, session: usize, request: u64, revision: u64 };
const PendingReferences = PendingDefinition;
const PendingRename = workspace_edits.Pending;
const PendingFormatting = PendingDefinition;
const PendingSignature = PendingDefinition;
const PendingCodeActions = workspace_edits.Pending;
pub const Model = struct {
    syntax_jobs: u64 = 0,
    generation: u64 = 0,
    diagnostics_generation: u64 = 0,
    syntax_documents: std.ArrayList(SyntaxDocument) = .empty,
    syntax_waiting: bool = false,
    sessions: std.ArrayList(Session) = .empty,
    documents: std.ArrayList(Document) = .empty,
    completions: ?lsp.Message = null,
    completion_index: usize = 0,
    pending: ?Pending = null,
    definitions: ?lsp.Message = null,
    definition_pending: ?PendingDefinition = null,
    references: ?lsp.Message = null,
    references_pending: ?PendingReferences = null,
    rename_pending: ?PendingRename = null,
    formatting_pending: ?PendingFormatting = null,
    signature: ?lsp.Message = null,
    signature_pending: ?PendingSignature = null,
    code_actions: ?lsp.Message = null,
    code_actions_pending: ?PendingCodeActions = null,
    results_kind: enum { references, code_actions } = .references,
    results_scroll: [2]ui.controls.Scroll = @splat(.{}),
    results_viewport: [2]?f32 = @splat(null),
    pub fn activeSessions(self: *const Model) usize {
        var count: usize = 0;
        for (self.sessions.items) |session| if (!session.retired) {
            count += 1;
        };
        return count;
    }
    /// Request IDs are local to a server. Both its session and document URI
    /// participate in identity before a response can reach an editor.
    pub fn expects(self: *const Model, session: usize, uri: []const u8, request_id: u64, revision: u64) bool {
        const pending = self.pending orelse return false;
        if (pending.session != session or pending.request != request_id or pending.revision != revision) return false;
        for (self.documents.items) |doc| if (std.meta.eql(doc.id, pending.document)) return doc.session == session and std.mem.eql(u8, doc.uri, uri);
        return false;
    }
    pub fn clearCompletion(self: *Model) void {
        if (self.completions) |*value| value.deinit();
        self.completions = null;
        self.completion_index = 0;
        self.pending = null;
    }
    pub fn clearDefinition(self: *Model) void {
        if (self.definitions) |*value| value.deinit();
        self.definitions = null;
        self.definition_pending = null;
    }
    pub fn clearReferences(self: *Model) void {
        if (self.references) |*value| value.deinit();
        self.references = null;
        self.references_pending = null;
    }
    pub fn clearRename(self: *Model) void {
        if (self.rename_pending) |*pending| pending.deinit();
        self.rename_pending = null;
    }
    pub fn clearFormatting(self: *Model) void {
        self.formatting_pending = null;
    }
    pub fn clearSignature(self: *Model) void {
        if (self.signature) |*value| value.deinit();
        self.signature = null;
        self.signature_pending = null;
    }
    pub fn clearCodeActions(self: *Model) void {
        if (self.code_actions) |*value| value.deinit();
        self.code_actions = null;
        if (self.code_actions_pending) |*pending| pending.deinit();
        self.code_actions_pending = null;
    }
    pub fn deinit(self: *Model, a: std.mem.Allocator) void {
        self.clearCompletion();
        self.clearDefinition();
        self.clearReferences();
        self.clearRename();
        self.clearFormatting();
        self.clearSignature();
        self.clearCodeActions();
        for (self.documents.items) |*doc| {
            if (doc.diagnostics) |*value| value.deinit();
            a.free(doc.uri);
            a.free(doc.path);
        }
        self.documents.deinit(a);
        for (self.sessions.items) |session| {
            if (session.client) |client| client.deinit();
            a.free(session.id);
        }
        self.sessions.deinit(a);
        self.syntax_documents.deinit(a);
        self.* = .{ .generation = self.generation +% 1 };
    }
};
fn syntaxDocument(self: *Shell, id: ws.DocumentId) !usize {
    for (self.language.syntax_documents.items, 0..) |doc, i| if (std.meta.eql(doc.id, id)) return i;
    try self.language.syntax_documents.append(self.allocator, .{ .id = id });
    return self.language.syntax_documents.items.len - 1;
}

fn completionWordRange(snapshot: text.Snapshot, cursor: usize) !text.Range {
    var start = cursor;
    while (start > 0) {
        const previous = try snapshot.previousBoundary(start);
        if (!identifierByte(try snapshot.byteAt(previous))) break;
        start = previous;
    }
    var end = cursor;
    while (end < snapshot.byteLen()) {
        const next = try snapshot.nextBoundary(end);
        if (!identifierByte(try snapshot.byteAt(end))) break;
        end = next;
    }
    return .{ .start = start, .end = end };
}

fn identifierByte(byte: u8) bool {
    return byte >= 0x80 or std.ascii.isAlphanumeric(byte) or byte == '_';
}

fn retireUnused(self: *Shell, index: usize) void {
    for (self.language.documents.items) |doc| if (doc.session == index) return;
    const session = &self.language.sessions.items[index];
    if (session.client) |client| client.deinit();
    session.client = null;
    session.resolving = false;
    session.retired = true;
}

fn cancelCompletion(self: *Shell, id: ws.DocumentId) void {
    if (self.language.pending) |pending| if (std.meta.eql(pending.document, id)) {
        if (pending.session < self.language.sessions.items.len) if (self.language.sessions.items[pending.session].client) |client| client.cancel(pending.request) catch {};
        self.language.clearCompletion();
    };
}

fn closeDocument(self: *Shell, index: usize) !void {
    const doc = &self.language.documents.items[index];
    cancelCompletion(self, doc.id);
    const session_index = doc.session;
    if (self.language.sessions.items[session_index].client) |client| if (client.ready() and doc.version != null) try client.didClose(doc.uri);
    if (doc.diagnostics) |*value| value.deinit();
    self.allocator.free(doc.uri);
    self.allocator.free(doc.path);
    _ = self.language.documents.orderedRemove(index);
    retireUnused(self, session_index);
}
/// A language rebind gets its own server session because late unversioned
/// diagnostics cannot distinguish two languages opened at the same URI/version.
/// Other documents retain their clients and diagnostics; retired slots keep
/// resolver indices stable and are reused only with a new epoch.
pub fn invalidateDocument(self: *Shell, id: ws.DocumentId) !void {
    if (self.symbol_hover.target) |target| if (std.meta.eql(target.document, id)) self.symbol_hover.deinit();
    cancelCompletion(self, id);
    const i = try syntaxDocument(self, id);
    const tracked = &self.language.syntax_documents.items[i];
    tracked.epoch = std.math.add(u64, tracked.epoch, 1) catch return error.LanguageEpochExhausted;
    tracked.scoped = true;
    tracked.revision = null;
    tracked.observed = null;
    tracked.pending = false;
    tracked.attempts = 0;
    tracked.retry_at = 0;
    clearSyntaxError(self, id);
    var index: usize = 0;
    while (index < self.language.documents.items.len) {
        if (std.meta.eql(self.language.documents.items[index].id, id)) try closeDocument(self, index) else index += 1;
    }
}

fn wake(_: ?*anyopaque) void {
    ui.App.wake();
}

fn sessionFor(self: *Shell, cx: *ui.Context(Shell), server: *const zircon_extensions.Server, scope: ?ws.DocumentId) !usize {
    for (self.language.sessions.items, 0..) |session, index| if (!session.retired and std.meta.eql(session.scope, scope) and std.mem.eql(u8, session.id, server.id)) return index;
    const id = try self.allocator.dupe(u8, server.id);
    errdefer self.allocator.free(id);
    var slot: ?usize = null;
    for (self.language.sessions.items, 0..) |session, index| if (session.retired) {
        slot = index;
        break;
    };
    if (slot == null) try self.language.sessions.ensureUnusedCapacity(self.allocator, 1);
    const index = slot orelse self.language.sessions.items.len;
    const epoch = if (slot) |i| std.math.add(u64, self.language.sessions.items[i].epoch, 1) catch return error.LanguageEpochExhausted else 0;
    var next: Session = .{ .id = id, .client = null, .scope = scope, .epoch = epoch };
    if (server.zed_wasm != null or std.mem.eql(u8, server.command, "@zircon-builtin")) {
        const root = self.extensions.?.home;
        const work = try std.fs.path.join(self.allocator, &.{ root, ".work", server.id });
        defer self.allocator.free(work);
        var settings_path: ?[]u8 = null;
        if (self.settings) |settings| try cx.read(settings, model.Settings.copyPath, .{ self.allocator, &settings_path });
        defer if (settings_path) |path| self.allocator.free(path);
        const argv: []const []const u8 = if (server.zed_wasm) |wasm| &.{ "resolve", wasm, server.zed_server.?, self.workspace.root_path, work, settings_path orelse "" } else &.{ "resolve-builtin", server.zed_server.?, self.workspace.root_path, work, settings_path orelse "" };
        try host.start(self, cx, argv, null, .{ .generation = self.language.generation, .epoch = epoch, .index = index }, resolved);
        next.resolving = true;
    } else next.client = lsp.Client.start(self.allocator, self.workspace.io, .{ .command = server.command, .args = server.args, .cwd = self.workspace.root_path, .wake = .{ .notify = wake } }) catch |err| blk: {
        try self.reportError(err);
        break :blk null;
    };
    if (slot) |i| {
        self.allocator.free(self.language.sessions.items[i].id);
        self.language.sessions.items[i] = next;
    } else self.language.sessions.appendAssumeCapacity(next);
    return index;
}
/// Reconciles the real open-document set before draining protocol messages.
/// Full text is serialized only for didOpen or a newer document revision.
pub fn poll(self: *Shell, cx: *ui.Context(Shell)) !void {
    const snapshot = self.extension_snapshot orelse return;
    try pollSyntax(self, cx);
    if (self.language_stopped) return;
    var changed = false;
    var i: usize = 0;
    while (i < self.language.documents.items.len) {
        const doc = &self.language.documents.items[i];
        const record = self.workspace.getConst(doc.id) catch null;
        if (record == null or record.?.path == null or !std.mem.eql(u8, doc.path, record.?.path.?)) {
            try closeDocument(self, i);
            changed = true;
            continue;
        }
        i += 1;
    }
    for (self.tabs.items) |tab| {
        const record = try self.workspace.getConst(tab.document);
        const path = record.path orelse continue;
        const language_id = if (snapshot.languageForPath(self.languagePath(tab.document, path))) |language| language.id else switch (tab.editor.language) {
            .zig => "zig",
            .rust => "rust",
            .json => "json",
            .markdown => "markdown",
            else => continue,
        };
        const server = snapshot.serverForLanguage(language_id) orelse continue;
        var found: ?usize = null;
        for (self.language.documents.items, 0..) |doc, index| if (std.meta.eql(doc.id, tab.document)) {
            found = index;
            break;
        };
        const index = found orelse blk: {
            const tracking = try syntaxDocument(self, tab.document);
            const session = try sessionFor(self, cx, server, if (self.language.syntax_documents.items[tracking].scoped) tab.document else null);
            errdefer retireUnused(self, session);
            const uri = try lsp.fileUri(self.allocator, path);
            errdefer self.allocator.free(uri);
            const owned_path = try self.allocator.dupe(u8, path);
            errdefer self.allocator.free(owned_path);
            try self.language.documents.append(self.allocator, .{ .id = tab.document, .uri = uri, .path = owned_path, .session = session });
            changed = true;
            break :blk self.language.documents.items.len - 1;
        };
        const doc = &self.language.documents.items[index];
        const client = self.language.sessions.items[doc.session].client orelse continue;
        if (!client.ready()) continue;
        var source = record.doc.snapshot();
        defer source.deinit();
        if (source.byteLen() > 8 * 1024 * 1024) continue;
        if (doc.version) |version| {
            if (version == source.revision()) continue;
            if (self.documentChangeSince(doc.id, version, source.revision())) |change| {
                try client.didChangeEdits(doc.uri, change.before, source, change.mappings);
            } else try client.didChange(doc.uri, source);
            if (doc.diagnostics) |*value| value.deinit();
            doc.diagnostics = null;
        } else try client.didOpen(doc.uri, if (snapshot.languageForPath(self.languagePath(tab.document, path))) |language| language.lsp_id orelse language.id else language_id, source);
        doc.version = source.revision();
    }
    for (self.language.sessions.items, 0..) |session, session_index| if (!session.retired) if (session.client) |client| {
        const messages = try client.drain(self.allocator);
        defer lsp.deinitMessages(self.allocator, messages);
        for (messages) |*raw| {
            var message = raw.*;
            var moved = false;
            defer if (moved) {
                raw.arena = .init(std.heap.page_allocator);
            };
            switch (message.data) {
                .initialized => changed = true,
                .exited => {
                    try self.setStatus(try std.fmt.allocPrint(self.allocator, "Language server {s} stopped. Run Language: restart servers to retry.", .{session.id}));
                    self.status_is_error = true;
                    changed = true;
                },
                .failure => |failure| {
                    if (self.symbol_hover.pending) |pending| if (pending.session == session_index and failure.request_id == pending.request) {
                        symbol_hover.clear(self, cx);
                        continue;
                    };
                    if (self.language.rename_pending) |pending| if (pending.session == session_index and failure.request_id == pending.request) self.language.clearRename();
                    if (self.language.formatting_pending) |pending| if (pending.session == session_index and failure.request_id == pending.request) self.language.clearFormatting();
                    if (self.language.code_actions_pending) |pending| if (pending.session == session_index and failure.request_id == pending.request) self.language.clearCodeActions();
                    try self.setStatus(try self.allocator.dupe(u8, failure.message));
                    self.status_is_error = true;
                    changed = true;
                },
                .diagnostics => if (try acceptDiagnostics(self, session_index, &message)) {
                    self.language.diagnostics_generation +%= 1;
                    moved = true;
                    changed = true;
                },
                .completion => |value| if (self.language.pending) |pending| {
                    const record = self.workspace.getConst(pending.document) catch continue;
                    if (!self.language.expects(session_index, value.uri, value.id, value.version) or record.doc.revision() != value.version) continue;
                    const current = actions.active(self) catch continue;
                    if (!std.meta.eql(current.id, pending.document) or current.editor.primary().head != pending.cursor) continue;
                    try filterCompletions(&message, record.doc.snapshot(), pending.cursor);
                    if (message.data.completion.items.len == 0) {
                        self.language.clearCompletion();
                        changed = true;
                        continue;
                    }
                    if (self.language.completions) |*old| old.deinit();
                    self.language.completions = message;
                    self.language.completion_index = 0;
                    moved = true;
                    changed = true;
                },
                .hover => try symbol_hover.accept(self, cx, session_index, message.data),
                .locations => |value| {
                    if (value.kind == .definition) {
                        const pending = self.language.definition_pending orelse continue;
                        if (pending.session != session_index or pending.request != value.id or pending.revision != value.version) continue;
                        if (self.language.definitions) |*old| old.deinit();
                        self.language.definitions = message;
                        moved = true;
                        changed = true;
                        try acceptDefinition(self, cx, session_index, self.language.definitions.?.data);
                    } else {
                        const pending = self.language.references_pending orelse continue;
                        if (pending.session != session_index or pending.request != value.id or pending.revision != value.version) continue;
                        if (self.language.references) |*old| old.deinit();
                        self.language.references = message;
                        moved = true;
                        changed = true;
                        self.language.results_scroll = @splat(.{});
                        self.language.results_kind = .references;
                        self.showTool(.language_results);
                    }
                },
                .workspace_edit => |value| if (self.language.rename_pending) |pending| {
                    if (pending.session != session_index or pending.request != value.id or pending.revision != value.version) continue;
                    defer self.language.clearRename();
                    workspace_edits.apply(self, cx, pending, value.files, .project_edit) catch |err| try self.reportError(err);
                    changed = true;
                },
                .edits => |value| if (self.language.formatting_pending) |pending| {
                    if (pending.session != session_index or pending.request != value.id or pending.revision != value.version) continue;
                    defer self.language.clearFormatting();
                    acceptFormatting(self, cx, value.items) catch |err| try self.reportError(err);
                    changed = true;
                },
                .signature_help => |value| if (self.language.signature_pending) |pending| {
                    if (pending.session != session_index or pending.request != value.id or pending.revision != value.version) continue;
                    if (self.language.signature) |*old| old.deinit();
                    self.language.signature = message;
                    self.language.signature_pending = null;
                    moved = true;
                    changed = true;
                    if (value.contents.len > 0) try self.setStatus(try self.allocator.dupe(u8, value.contents));
                },
                .code_actions => |value| if (self.language.code_actions_pending) |pending| {
                    if (pending.session != session_index or pending.request != value.id or pending.revision != value.version) continue;
                    if (self.language.code_actions) |*old| old.deinit();
                    self.language.code_actions = message;
                    moved = true;
                    changed = true;
                    self.language.results_scroll = @splat(.{});
                    self.language.results_kind = .code_actions;
                    self.showTool(.language_results);
                },
                else => {},
            }
        }
    };
    if (changed) cx.notify();
}

fn matchRank(candidate: []const u8, prefix: []const u8) ?usize {
    if (prefix.len == 0) return 0;
    if (candidate.len >= prefix.len and std.ascii.eqlIgnoreCase(candidate[0..prefix.len], prefix)) return 0;
    var matched: usize = 0;
    var gaps: usize = 0;
    for (candidate) |byte| {
        if (std.ascii.toLower(byte) == std.ascii.toLower(prefix[matched])) {
            matched += 1;
            if (matched == prefix.len) return 1 + gaps;
        } else gaps += 1;
    }
    return null;
}

fn filterCompletions(message: *lsp.Message, snapshot_value: text.Snapshot, cursor: usize) !void {
    var snapshot = snapshot_value;
    defer snapshot.deinit();
    const a = message.arena.allocator();
    const word = try completionWordRange(snapshot, cursor);
    const prefix = try snapshot.copy(a, .{ .start = word.start, .end = cursor });
    const candidates = message.data.completion.items;
    const items = try a.alloc(lsp.Completion, candidates.len);
    var count: usize = 0;
    for (candidates) |candidate| {
        if (candidate.snippet or matchRank(candidate.filter_text orelse candidate.label, prefix) == null) continue;
        items[count] = candidate;
        count += 1;
    }
    std.mem.sort(lsp.Completion, items[0..count], prefix, struct {
        fn less(typed: []const u8, left: lsp.Completion, right: lsp.Completion) bool {
            const left_rank = matchRank(left.filter_text orelse left.label, typed).?;
            const right_rank = matchRank(right.filter_text orelse right.label, typed).?;
            if (left_rank != right_rank) return left_rank < right_rank;
            return std.mem.lessThan(u8, left.sort_text orelse left.label, right.sort_text orelse right.label);
        }
    }.less);
    message.data.completion.items = items[0..count];
}

fn acceptDiagnostics(self: *Shell, session: usize, message: *lsp.Message) !bool {
    const value = message.data.diagnostics;
    var found: ?usize = null;
    for (self.language.documents.items, 0..) |doc, index| if (std.mem.eql(u8, doc.uri, value.uri)) {
        if (doc.session != session) return false;
        found = index;
        break;
    };
    const index = found orelse blk: {
        if (value.version != null or value.items.len == 0) return false;
        const path = lsp.filePath(self.allocator, value.uri) catch return false;
        defer self.allocator.free(path);
        const root = self.workspace.root_path;
        if (!std.mem.startsWith(u8, path, root) or path.len <= root.len or path[root.len] != '/') return false;
        const id = self.workspace.open(path) catch return false;
        const record = try self.workspace.getConst(id);
        if (record.dirty()) return false;
        const uri = try self.allocator.dupe(u8, value.uri);
        errdefer self.allocator.free(uri);
        const owned_path = try self.allocator.dupe(u8, record.path.?);
        errdefer self.allocator.free(owned_path);
        try self.language.documents.append(self.allocator, .{ .id = id, .uri = uri, .path = owned_path, .session = session });
        break :blk self.language.documents.items.len - 1;
    };
    const doc = &self.language.documents.items[index];
    const record = self.workspace.getConst(doc.id) catch return false;
    if (doc.version == null and (value.version != null or record.dirty())) return false;
    const revision = doc.version orelse record.doc.revision();
    if (record.doc.revision() != revision or (value.version != null and value.version.? != revision)) return false;
    message.data.diagnostics.version = revision;
    if (doc.diagnostics) |*old| old.deinit();
    doc.diagnostics = message.*;
    return true;
}

pub fn completionTrigger(input: ui.Input) bool {
    const bytes = switch (input) {
        .text => |value| value,
        .edit => |edit| if (edit.composing) "" else edit.text,
        else => "",
    };
    if (bytes.len == 0) return false;
    for (bytes) |byte| if (!identifierByte(byte) and byte != '.' and byte != '@' and byte != ':' and byte != '"' and byte != '/' and byte != ']') return false;
    return true;
}

pub fn definitionPointer(self: *Shell, cx: *ui.Context(Shell), state: *zircon_editor.Editor, document: *const text.Document, event: *ui.Event(ui.Input)) !bool {
    if (event.data != .pointer_down) return false;
    const pointer = event.data.pointer_down;
    if (pointer.button != .primary or (!pointer.modifiers.command and !pointer.modifiers.control) or pointer.modifiers.shift or pointer.modifiers.alt) return false;
    var snapshot = document.snapshot();
    defer snapshot.deinit();
    const gutter = if (state.show_line_numbers) zircon_editor.gutterWidth(snapshot.lineCount(), state.font_size) else 20;
    if (pointer.position.x < event.bounds.x + gutter) return false;
    const at = try state.offsetAtPoint(snapshot, event, pointer.position);
    if (at >= snapshot.byteLen() or std.ascii.isWhitespace(try snapshot.byteAt(at))) return false;
    state.selections.single(.{ .anchor = at, .head = at });
    state.dragging = false;
    state.typing_group = 0;
    self.language.clearCompletion();
    symbol_hover.clear(self, cx);
    requestDefinition(self, cx) catch |err| switch (err) {
        error.NoLanguageServer, error.ServerNotReady, error.DefinitionNotSupported => return false,
        else => return err,
    };
    event.focus();
    event.preventDefault();
    event.stopPropagation();
    cx.notify();
    return true;
}

pub fn request(self: *Shell, cx: *ui.Context(Shell)) !void {
    try poll(self, cx);
    const current = try actions.active(self);
    for (self.language.documents.items) |doc| if (std.meta.eql(doc.id, current.id)) {
        const client = self.language.sessions.items[doc.session].client orelse return error.ServerNotReady;
        if (self.language.pending) |old| if (old.session < self.language.sessions.items.len) if (self.language.sessions.items[old.session].client) |previous| previous.cancel(old.request) catch {};
        var snapshot = try self.workspace.snapshot(current.id);
        defer snapshot.deinit();
        const cursor = current.editor.primary().head;
        const id = try client.completion(doc.uri, snapshot.revision(), try lsp.positionAt(snapshot, cursor));
        self.language.clearCompletion();
        self.language.pending = .{ .document = current.id, .session = doc.session, .request = id, .revision = snapshot.revision(), .cursor = cursor };
        cx.notify();
        return;
    };
    return error.NoLanguageServer;
}

pub fn requestDefinition(self: *Shell, cx: *ui.Context(Shell)) !void {
    try poll(self, cx);
    const current = try actions.active(self);
    for (self.language.documents.items) |doc| if (std.meta.eql(doc.id, current.id)) {
        const client = self.language.sessions.items[doc.session].client orelse return error.ServerNotReady;
        var snapshot = try self.workspace.snapshot(current.id);
        defer snapshot.deinit();
        const request_id = try client.definition(doc.uri, snapshot.revision(), try lsp.positionAt(snapshot, current.editor.primary().head));
        self.language.clearDefinition();
        self.language.definition_pending = .{ .document = current.id, .session = doc.session, .request = request_id, .revision = snapshot.revision() };
        cx.notify();
        return;
    };
    return error.NoLanguageServer;
}

pub fn requestReferences(self: *Shell, cx: *ui.Context(Shell)) !void {
    try poll(self, cx);
    const current = try actions.active(self);
    for (self.language.documents.items) |doc| if (std.meta.eql(doc.id, current.id)) {
        const client = self.language.sessions.items[doc.session].client orelse return error.ServerNotReady;
        var snapshot = try self.workspace.snapshot(current.id);
        defer snapshot.deinit();
        const request_id = try client.references(doc.uri, snapshot.revision(), try lsp.positionAt(snapshot, current.editor.primary().head));
        self.language.clearReferences();
        self.language.references_pending = .{ .document = current.id, .session = doc.session, .request = request_id, .revision = snapshot.revision() };
        cx.notify();
        return;
    };
    return error.NoLanguageServer;
}

pub fn requestRename(self: *Shell, cx: *ui.Context(Shell), new_name: []const u8) !void {
    try poll(self, cx);
    if (new_name.len == 0) return error.InvalidRename;
    const current = try actions.active(self);
    for (self.language.documents.items) |doc| if (std.meta.eql(doc.id, current.id)) {
        const client = self.language.sessions.items[doc.session].client orelse return error.ServerNotReady;
        var snapshot = try self.workspace.snapshot(current.id);
        defer snapshot.deinit();
        var pending: PendingRename = .{ .document = current.id, .session = doc.session, .request = 0, .revision = snapshot.revision() };
        try pending.capture(&self.workspace, self.allocator);
        errdefer pending.deinit();
        pending.request = try client.rename(doc.uri, snapshot.revision(), try lsp.positionAt(snapshot, current.editor.primary().head), new_name);
        self.language.clearRename();
        self.language.rename_pending = pending;
        cx.notify();
        return;
    };
    return error.NoLanguageServer;
}

pub fn requestFormatting(self: *Shell, cx: *ui.Context(Shell)) !void {
    try poll(self, cx);
    const current = try actions.active(self);
    for (self.language.documents.items) |doc| if (std.meta.eql(doc.id, current.id)) {
        const client = self.language.sessions.items[doc.session].client orelse return error.ServerNotReady;
        var snapshot = try self.workspace.snapshot(current.id);
        defer snapshot.deinit();
        const request_id = try client.formatting(doc.uri, snapshot.revision());
        self.language.clearFormatting();
        self.language.formatting_pending = .{ .document = current.id, .session = doc.session, .request = request_id, .revision = snapshot.revision() };
        cx.notify();
        return;
    };
    return error.NoLanguageServer;
}

pub fn requestSignature(self: *Shell, cx: *ui.Context(Shell)) !void {
    try poll(self, cx);
    const current = try actions.active(self);
    for (self.language.documents.items) |doc| if (std.meta.eql(doc.id, current.id)) {
        const client = self.language.sessions.items[doc.session].client orelse return error.ServerNotReady;
        var snapshot = try self.workspace.snapshot(current.id);
        defer snapshot.deinit();
        const request_id = try client.signature(doc.uri, snapshot.revision(), try lsp.positionAt(snapshot, current.editor.primary().head));
        self.language.clearSignature();
        self.language.signature_pending = .{ .document = current.id, .session = doc.session, .request = request_id, .revision = snapshot.revision() };
        cx.notify();
        return;
    };
    return error.NoLanguageServer;
}

pub fn requestCodeActions(self: *Shell, cx: *ui.Context(Shell)) !void {
    try poll(self, cx);
    const current = try actions.active(self);
    for (self.language.documents.items) |doc| if (std.meta.eql(doc.id, current.id)) {
        const client = self.language.sessions.items[doc.session].client orelse return error.ServerNotReady;
        var snapshot = try self.workspace.snapshot(current.id);
        defer snapshot.deinit();
        const selected = current.editor.primary().range();
        var pending: PendingCodeActions = .{ .document = current.id, .session = doc.session, .request = 0, .revision = snapshot.revision() };
        try pending.capture(&self.workspace, self.allocator);
        errdefer pending.deinit();
        pending.request = try client.codeActions(doc.uri, snapshot.revision(), .{ .start = try lsp.positionAt(snapshot, selected.start), .end = try lsp.positionAt(snapshot, selected.end) });
        self.language.clearCodeActions();
        self.language.code_actions_pending = pending;
        cx.notify();
        return;
    };
    return error.NoLanguageServer;
}

pub fn applyCodeAction(self: *Shell, cx: *ui.Context(Shell), index: usize) !void {
    const message = self.language.code_actions orelse return error.StaleCodeActions;
    if (index >= message.data.code_actions.items.len) return error.StaleCodeActions;
    if (message.data.code_actions.items[index].disabled_reason) |reason| {
        try self.setStatus(try self.allocator.dupe(u8, reason));
        self.status_is_error = true;
        cx.notify();
        return;
    }
    const pending = self.language.code_actions_pending orelse return error.StaleCodeActions;
    defer self.language.clearCodeActions();
    try workspace_edits.apply(self, cx, pending, message.data.code_actions.items[index].files, .project_edit);
}

fn acceptFormatting(self: *Shell, cx: *ui.Context(Shell), items: []const lsp.TextEdit) !void {
    const pending = self.language.formatting_pending orelse return;
    const record = try self.workspace.getConst(pending.document);
    if (record.doc.revision() != pending.revision) return error.StaleFormatting;
    const uri = try lsp.fileUri(self.allocator, record.path orelse return error.NoDocument);
    defer self.allocator.free(uri);
    try workspace_edits.apply(self, cx, .{ .document = pending.document, .session = pending.session, .request = pending.request, .revision = pending.revision }, &.{.{ .uri = uri, .edits = items, .version = pending.revision }}, .formatting);
}

pub fn acceptDefinition(self: *Shell, cx: *ui.Context(Shell), session: usize, message: @FieldType(lsp.Message, "data")) !void {
    const pending = self.language.definition_pending orelse return;
    const value = message.locations;
    if (pending.session != session or pending.request != value.id or value.version != pending.revision) return;
    const record = self.workspace.getConst(pending.document) catch return;
    if (record.doc.revision() != pending.revision) return self.language.clearDefinition();
    const origin = actions.active(self) catch return self.language.clearDefinition();
    if (!std.meta.eql(origin.id, pending.document)) return self.language.clearDefinition();
    if (value.items.len == 0) return self.language.clearDefinition();
    const location = value.items[0];
    const path = try lsp.filePath(self.allocator, location.uri);
    defer self.allocator.free(path);
    try actions.openPath(self, path);
    if (self.active_pane == .secondary) self.secondary_tool = null else self.panel = .editor;
    const current = try actions.active(self);
    var snapshot = try self.workspace.snapshot(current.id);
    defer snapshot.deinit();
    const selected_range: text.Range = .{ .start = try lsp.offsetAt(snapshot, location.range.start), .end = try lsp.offsetAt(snapshot, location.range.end) };
    try current.editor.setSelection(snapshot, selected_range);
    current.editor.reveal(snapshot);
    self.editor_focus_request +%= 1;
    self.language.clearDefinition();
    cx.notify();
}

pub fn acceptReference(self: *Shell, cx: *ui.Context(Shell), index: usize) !void {
    const pending = self.language.references_pending orelse return error.StaleReferences;
    const message = self.language.references orelse return error.StaleReferences;
    if (message.data.locations.kind != .references or index >= message.data.locations.items.len) return error.StaleReferences;
    const record = self.workspace.getConst(pending.document) catch return error.StaleReferences;
    if (record.doc.revision() != pending.revision) return error.StaleReferences;
    const location = message.data.locations.items[index];
    const path = try lsp.filePath(self.allocator, location.uri);
    defer self.allocator.free(path);
    try actions.openPath(self, path);
    if (self.active_pane == .secondary) self.secondary_tool = null else self.panel = .editor;
    const current = try actions.active(self);
    var snapshot = try self.workspace.snapshot(current.id);
    defer snapshot.deinit();
    const selected_range: text.Range = .{ .start = try lsp.offsetAt(snapshot, location.range.start), .end = try lsp.offsetAt(snapshot, location.range.end) };
    try current.editor.setSelection(snapshot, selected_range);
    current.editor.reveal(snapshot);
    self.editor_focus_request +%= 1;
    cx.notify();
}

pub fn accept(self: *Shell, cx: *ui.Context(Shell), index: usize) !void {
    const pending = self.language.pending orelse return error.NoCompletion;
    const message = self.language.completions orelse return error.NoCompletion;
    if (index >= message.data.completion.items.len) return error.NoCompletion;
    const item = message.data.completion.items[index];
    if (item.snippet) return error.SnippetNotSupported;
    const current = try actions.active(self);
    if (!std.meta.eql(current.id, pending.document) or current.editor.primary().head != pending.cursor) {
        self.language.clearCompletion();
        return error.StaleCompletion;
    }
    const record = try self.workspace.get(current.id);
    var snapshot = record.doc.snapshot();
    defer snapshot.deinit();
    if (snapshot.revision() != pending.revision) {
        self.language.clearCompletion();
        return error.StaleCompletion;
    }
    var edits: std.ArrayList(text.Edit) = .empty;
    defer edits.deinit(self.allocator);
    const primary_edit = if (item.text_edit) |edit| text.Edit{ .range = .{ .start = try lsp.offsetAt(snapshot, edit.range.start), .end = try lsp.offsetAt(snapshot, edit.range.end) }, .text = edit.new_text } else text.Edit{ .range = try completionWordRange(snapshot, pending.cursor), .text = item.insert_text };
    try edits.append(self.allocator, primary_edit);
    for (item.additional_edits) |edit| try edits.append(self.allocator, .{ .range = .{ .start = try lsp.offsetAt(snapshot, edit.range.start), .end = try lsp.offsetAt(snapshot, edit.range.end) }, .text = edit.new_text });
    std.mem.sort(text.Edit, edits.items, {}, struct {
        fn less(_: void, a: text.Edit, b: text.Edit) bool {
            return a.range.start < b.range.start;
        }
    }.less);
    var outcome = try current.editor.applyEditsWithSelection(&record.doc, edits.items, try zircon_editor.Editor.freshGroup(), primary_edit.range);
    try actions.applyOutcome(self, cx, current.id, actions.activeOrigin(self), &outcome, .completion);
    self.language.clearCompletion();
    self.editor_focus_request +%= 1;
    cx.notify();
}

fn resolved(self: *Shell, cx: *ui.Context(Shell), raw: anyerror!*host.Box) !void {
    const box = raw catch |err| {
        syntaxTransportFailed(self, cx, err);
        cx.notify();
        return;
    };
    var result = box.take();
    defer result.deinit();
    if (result.stamp.generation != self.language.generation or result.stamp.index >= self.language.sessions.items.len) return;
    const session = &self.language.sessions.items[result.stamp.index];
    if (session.retired or session.epoch != result.stamp.epoch) return;
    session.resolving = false;
    if (!result.success) {
        try self.setStatus(try self.allocator.dupe(u8, result.stderr));
        self.status_is_error = true;
        cx.notify();
        return;
    }
    const Resolved = struct { command: []const u8, args: []const []const u8, cwd: []const u8, env: []const [2][]const u8 = &.{}, initialization_options: std.json.Value = .null, workspace_configuration: std.json.Value = .null };
    var parsed = try std.json.parseFromSlice(Resolved, self.allocator, result.stdout, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    session.client = lsp.Client.start(self.allocator, self.workspace.io, .{ .command = parsed.value.command, .args = parsed.value.args, .cwd = parsed.value.cwd, .root_path = self.workspace.root_path, .environment = parsed.value.env, .initialization_options = parsed.value.initialization_options, .workspace_configuration = parsed.value.workspace_configuration, .wake = .{ .notify = wake } }) catch |err| {
        try self.reportError(err);
        cx.notify();
        return;
    };
    cx.notify();
}

fn pollSyntax(self: *Shell, cx: *ui.Context(Shell)) !void {
    const was_waiting = self.language.syntax_waiting;
    defer if (was_waiting != self.language.syntax_waiting) cx.notify();
    self.language.syntax_waiting = false;
    const now = if (self.window) |handle| (try cx.app.window(handle)).time else 0;
    const snapshot = self.extension_snapshot orelse return;
    for (self.workspace.slots.items, 0..) |slot, slot_index| {
        const record = slot.record orelse continue;
        const id: ws.DocumentId = .{ .workspace = self.workspace.identity, .slot = @intCast(slot_index), .generation = slot.generation };
        var visible = self.tabs.items.len > 0 and std.meta.eql(self.tabs.items[self.active].document, id);
        if (self.secondary) |pane| if (std.meta.eql(pane.document, id)) {
            visible = true;
        };
        for (self.search.editing.panes) |pane| if (pane.active) |active_id| if (std.meta.eql(active_id, id)) {
            visible = true;
        };
        if (self.git.editing.active) |active_id| if (std.meta.eql(active_id, id)) {
            visible = true;
        };
        if (self.currentTool(0) == .git_diff or self.currentTool(1) == .git_diff) if (self.git.editable) |projection| {
            for (projection.sources.items) |source| if (std.meta.eql(source.id, id)) {
                visible = true;
                break;
            };
        };
        if (!visible) continue;
        const language = snapshot.languageForPath(self.languagePath(id, record.path orelse "")) orelse continue;
        const grammar = language.grammar orelse continue;
        const i = try syntaxDocument(self, id);
        const tracked = &self.language.syntax_documents.items[i];
        if (tracked.revision == record.doc.revision()) continue;
        if (tracked.observed != record.doc.revision()) {
            tracked.observed = record.doc.revision();
            tracked.changed_at = now;
            tracked.attempts = 0;
            tracked.retry_at = 0;
        }
        if (tracked.pending or tracked.attempts >= 3) continue;
        if (now < tracked.retry_at) {
            self.language.syntax_waiting = true;
            continue;
        }
        if (tracked.revision != null and now - tracked.changed_at < 0.08) {
            self.language.syntax_waiting = true;
            continue;
        }
        var source = record.doc.snapshot();
        defer source.deinit();
        if (source.byteLen() > 8 * 1024 * 1024) continue;
        const bytes = try source.copy(self.allocator, .{ .start = 0, .end = source.byteLen() });
        defer self.allocator.free(bytes);
        if (tracked.attempts == 0) tracked.status_sequence = self.status_sequence;
        try host.start(self, cx, &.{ "highlight", grammar.wasm, grammar.name, grammar.highlights }, bytes, .{ .generation = self.language.generation, .epoch = tracked.epoch, .document = id, .revision = source.revision(), .index = i }, highlighted);
        self.language.syntax_jobs +%= 1;
        tracked.pending = true;
        tracked.attempts += 1;
    }
}

fn highlighted(self: *Shell, cx: *ui.Context(Shell), raw: anyerror!*host.Box) !void {
    const box = raw catch |err| {
        try self.reportError(err);
        cx.notify();
        return;
    };
    var result = box.take();
    defer result.deinit();
    if (result.stamp.generation != self.language.generation or result.stamp.index >= self.language.syntax_documents.items.len) return;
    const tracked = &self.language.syntax_documents.items[result.stamp.index];
    const document = result.stamp.document orelse return;
    if (!std.meta.eql(tracked.id, document) or tracked.epoch != result.stamp.epoch) return;
    tracked.pending = false;
    const record = self.workspace.getConst(document) catch {
        tracked.pending = false;
        tracked.retry_at = 0;
        return;
    };
    if (record.doc.revision() != result.stamp.revision) {
        try pollSyntax(self, cx);
        return;
    }
    if (!result.success) return syntaxFailed(self, cx, tracked, result.stderr);
    const parsed = result.highlights orelse return syntaxFailed(self, cx, tracked, "Invalid grammar response");
    var source = record.doc.snapshot();
    defer source.deinit();
    if (parsed.value.bytes != source.byteLen()) return syntaxFailed(self, cx, tracked, "Invalid grammar response length");
    for (self.tabs.items) |*tab| if (std.meta.eql(tab.document, document)) {
        tab.editor.setHighlights(source, parsed.value.spans) catch |err| return syntaxFailed(self, cx, tracked, @errorName(err));
    };
    if (self.secondary) |*pane| if (std.meta.eql(pane.document, document)) {
        pane.editor.setHighlights(source, parsed.value.spans) catch |err| return syntaxFailed(self, cx, tracked, @errorName(err));
    };
    for (self.git.editing.views.items) |*view| if (std.meta.eql(view.document, document)) {
        view.editor.setHighlights(source, parsed.value.spans) catch |err| return syntaxFailed(self, cx, tracked, @errorName(err));
    };
    for (&self.search.editing.panes) |*pane| for (pane.views.items) |*view| if (std.meta.eql(view.document, document)) {
        view.editor.setHighlights(source, parsed.value.spans) catch |err| return syntaxFailed(self, cx, tracked, @errorName(err));
    };
    tracked.revision = result.stamp.revision;
    clearSyntaxError(self, document);
    cx.notify();
}

/// Retry only the current source/configuration. The ordinary syntax wake keeps
/// the UI asleep between attempts and stops after the third failure.
fn syntaxFailed(self: *Shell, cx: *ui.Context(Shell), tracked: *SyntaxDocument, message: []const u8) !void {
    const now = if (self.window) |handle| (try cx.app.window(handle)).time else 0;
    tracked.retry_at = now + if (tracked.attempts <= 1) @as(f64, 0.25) else @as(f64, 0.5);
    if (self.status_sequence == tracked.status_sequence and !(self.status_is_error and self.status_origin == .general)) {
        try self.setStatus(try self.allocator.dupe(u8, message));
        self.status_is_error = true;
        self.status_origin = .{ .syntax = tracked.id };
    }
    try pollSyntax(self, cx);
    cx.notify();
}

fn syntaxTransportFailed(self: *Shell, cx: *ui.Context(Shell), err: anyerror) void {
    const now = if (self.window) |handle| blk: {
        const window = cx.app.window(handle) catch break :blk 0;
        break :blk window.time;
    } else 0;
    for (self.language.syntax_documents.items) |*tracked| if (tracked.pending) {
        tracked.pending = false;
        if (tracked.attempts < 3) tracked.retry_at = now;
    };
    if (!(self.status_is_error and self.status_origin == .general)) self.reportError(err) catch {};
}

fn clearSyntaxError(self: *Shell, document: ws.DocumentId) void {
    switch (self.status_origin) {
        .general => {},
        .syntax => |id| if (std.meta.eql(id, document)) {
            self.allocator.free(self.status);
            self.status = &.{};
            self.status_is_error = false;
            self.status_origin = .general;
        },
    }
}

const SyntaxWake = struct {
    pub const LayoutState = void;
    pub const PrepaintState = void;
    pub fn requestLayout(_: *SyntaxWake, _: *ui.LayoutCx) !ui.LayoutResult(void) {
        return .{ .size = .{ .width = 0, .height = 0 }, .state = {} };
    }
    pub fn prepaint(_: *SyntaxWake, cx: *ui.PrepaintCx, _: ui.Rect, _: *void) !void {
        try cx.requestFrameAfter(0.08);
    }
    pub fn paint(_: *SyntaxWake, _: *ui.PaintCx, _: ui.Rect, _: *void, _: *void) !void {}
};
pub fn syntaxWake(b: *ui.Ui) !ui.Element {
    return b.custom(SyntaxWake, .{}, .{ .width = .{ .px = 0 }, .height = .{ .px = 0 } });
}
