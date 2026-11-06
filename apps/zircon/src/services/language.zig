//! UI-thread owner of persistent language servers. Transport threads publish
//! owned messages and wake AppKit; no transport thread borrows editor state.
const std = @import("std");
const ui = @import("zircon_ui");
const lsp = @import("zircon_language");
const text = @import("zircon_text");
const ws = @import("zircon_workspace");
const Shell = @import("../shell.zig").Shell;
const Session = struct { id: []u8, client: ?*lsp.Client };
const Document = struct {
    id: ws.DocumentId,
    uri: []u8,
    path: []u8,
    session: usize,
    version: ?u64 = null,
    diagnostics: ?lsp.Message = null,
};
pub const Pending = struct { document: ws.DocumentId, session: usize, request: u64, revision: u64, cursor: usize };
pub const Model = struct {
    sessions: std.ArrayList(Session) = .empty,
    documents: std.ArrayList(Document) = .empty,
    completions: ?lsp.Message = null,
    completion_index: usize = 0,
    pending: ?Pending = null,
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
    pub fn deinit(self: *Model, a: std.mem.Allocator) void {
        self.clearCompletion();
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
        self.* = .{};
    }
};
fn wake(_: ?*anyopaque) void {
    ui.App.wake();
}
fn sessionFor(self: *Shell, server: *const @import("zircon_extensions").Server) !usize {
    for (self.language.sessions.items, 0..) |session, index| if (std.mem.eql(u8, session.id, server.id)) return index;
    const id = try self.allocator.dupe(u8, server.id);
    errdefer self.allocator.free(id);
    try self.language.sessions.ensureUnusedCapacity(self.allocator, 1);
    const client = lsp.Client.start(self.allocator, self.workspace.io, .{ .command = server.command, .args = server.args, .cwd = self.workspace.root_path, .wake = .{ .notify = wake } }) catch |err| blk: {
        try self.reportError(err);
        break :blk null;
    };
    self.language.sessions.appendAssumeCapacity(.{ .id = id, .client = client });
    return self.language.sessions.items.len - 1;
}
/// Reconciles the real open-document set before draining protocol messages.
/// Full text is serialized only for didOpen or a newer document revision.
pub fn poll(self: *Shell, cx: *ui.Context(Shell)) !void {
    const snapshot = self.extension_snapshot orelse return;
    var changed = false;
    var i: usize = 0;
    while (i < self.language.documents.items.len) {
        const doc = &self.language.documents.items[i];
        const record = self.workspace.getConst(doc.id) catch null;
        if (record == null or record.?.path == null or !std.mem.eql(u8, doc.path, record.?.path.?)) {
            const session = self.language.sessions.items[doc.session];
            if (session.client) |client| if (client.ready() and doc.version != null) client.didClose(doc.uri) catch {};
            if (doc.diagnostics) |*value| value.deinit();
            self.allocator.free(doc.uri);
            self.allocator.free(doc.path);
            _ = self.language.documents.orderedRemove(i);
            changed = true;
            continue;
        }
        i += 1;
    }
    for (self.tabs.items) |tab| {
        const record = try self.workspace.getConst(tab.document);
        const path = record.path orelse continue;
        const language_id = if (snapshot.languageForPath(path)) |language| language.id else switch (tab.editor.language) {
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
            const session = try sessionFor(self, server);
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
            try client.didChange(doc.uri, source);
            if (doc.diagnostics) |*value| value.deinit();
            doc.diagnostics = null;
        } else try client.didOpen(doc.uri, language_id, source);
        doc.version = source.revision();
    }
    for (self.language.sessions.items, 0..) |session, session_index| if (session.client) |client| {
        const messages = try client.drain(self.allocator);
        defer lsp.deinitMessages(self.allocator, messages);
        for (messages) |*raw| {
            const message = raw.*;
            var moved = false;
            defer if (moved) {
                raw.arena = .init(std.heap.page_allocator);
            };
            switch (message.data) {
                .initialized, .exited => changed = true,
                .failure => |failure| {
                    try self.setStatus(try self.allocator.dupe(u8, failure.message));
                    self.status_is_error = true;
                    changed = true;
                },
                .diagnostics => |value| for (self.language.documents.items) |*doc| {
                    if (doc.session != session_index or !std.mem.eql(u8, doc.uri, value.uri)) continue;
                    if (doc.version == null or value.version == null or value.version.? != doc.version.?) break;
                    if (doc.diagnostics) |*old| old.deinit();
                    doc.diagnostics = message;
                    moved = true;
                    changed = true;
                    break;
                },
                .completion => |value| if (self.language.pending) |pending| {
                    const record = self.workspace.getConst(pending.document) catch continue;
                    if (!self.language.expects(session_index, value.uri, value.id, value.version) or record.doc.revision() != value.version) continue;
                    if (self.language.completions) |*old| old.deinit();
                    self.language.completions = message;
                    self.language.completion_index = 0;
                    moved = true;
                    changed = true;
                },
                else => {},
            }
        }
    };
    if (changed) cx.notify();
}
pub fn request(self: *Shell, cx: *ui.Context(Shell)) !void {
    try poll(self, cx);
    const current = try @import("../actions.zig").active(self);
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
pub fn selectDiagnostic(self: *Shell, cx: *ui.Context(Shell), index: usize) !void {
    const current = try @import("../actions.zig").active(self);
    for (self.language.documents.items) |doc| if (std.meta.eql(doc.id, current.id)) {
        const message = doc.diagnostics orelse return;
        if (index >= message.data.diagnostics.items.len) return;
        var snapshot = try self.workspace.snapshot(current.id);
        defer snapshot.deinit();
        if (message.data.diagnostics.version != snapshot.revision()) return error.StaleDiagnostics;
        const range = message.data.diagnostics.items[index].range;
        try current.editor.setSelection(snapshot, .{ .start = try lsp.offsetAt(snapshot, range.start), .end = try lsp.offsetAt(snapshot, range.end) });
        current.editor.reveal(snapshot);
        self.editor_focus_request +%= 1;
        cx.notify();
        return;
    };
}
pub fn accept(self: *Shell, cx: *ui.Context(Shell), index: usize) !void {
    const pending = self.language.pending orelse return error.NoCompletion;
    const message = self.language.completions orelse return error.NoCompletion;
    if (index >= message.data.completion.items.len) return error.NoCompletion;
    const item = message.data.completion.items[index];
    if (item.snippet) return error.SnippetNotSupported;
    const current = try @import("../actions.zig").active(self);
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
    try edits.append(self.allocator, if (item.text_edit) |edit| .{ .range = .{ .start = try lsp.offsetAt(snapshot, edit.range.start), .end = try lsp.offsetAt(snapshot, edit.range.end) }, .text = edit.new_text } else .{ .range = .{ .start = pending.cursor, .end = pending.cursor }, .text = item.insert_text });
    for (item.additional_edits) |edit| try edits.append(self.allocator, .{ .range = .{ .start = try lsp.offsetAt(snapshot, edit.range.start), .end = try lsp.offsetAt(snapshot, edit.range.end) }, .text = edit.new_text });
    std.mem.sort(text.Edit, edits.items, {}, struct {
        fn less(_: void, a: text.Edit, b: text.Edit) bool {
            return a.range.start < b.range.start;
        }
    }.less);
    var outcome = try current.editor.applyEdits(&record.doc, edits.items, try @import("zircon_editor").Editor.freshGroup());
    try @import("../actions.zig").applyOutcome(self, current.id, if (self.active_pane == .primary) 0 else 1, &outcome);
    self.language.clearCompletion();
    self.editor_focus_request +%= 1;
    cx.notify();
}
