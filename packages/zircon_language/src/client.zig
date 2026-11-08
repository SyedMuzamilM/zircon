//! A stable client owns its process and three transport threads. Only its owner
//! calls document/request methods. Readers publish owned messages; wake carries
//! a host-owned thread-safe signal target, never an entity pointer.
const std = @import("std");
const builtin = @import("builtin");
const text = @import("zircon_text");
const frame = @import("framing.zig");
const hover_content = @import("hover.zig");
const model = @import("model.zig");
const synchronization = @import("synchronization.zig");
const DocumentState = struct { snapshot: text.Snapshot };
const transport_allocator = std.heap.page_allocator;
pub const Wake = struct { context: ?*anyopaque = null, notify: *const fn (?*anyopaque) void };
pub const Config = struct { outgoing_limit_bytes: usize = 16 * 1024 * 1024, environment: []const [2][]const u8 = &.{}, initialization_options: std.json.Value = .null, workspace_configuration: std.json.Value = .null, root_path: ?[]const u8 = null, command: []const u8, args: []const []const u8 = &.{}, cwd: []const u8, wake: ?Wake = null };
pub const Status = enum(u8) { starting, ready, closing, failed, exited };
const Pending = struct { kind: enum { initialize, completion, hover, definition, references, rename, formatting, shutdown }, uri: []u8 = &.{}, version: u64 = 0 };
pub const Client = struct {
    pub const Stats = struct { queued_messages: u64 = 0, queued_bytes: u64 = 0, document_changes: u64 = 0, change_text_bytes: u64 = 0, incremental_changes: u64 = 0, resync_changes: u64 = 0 };
    counters: Stats = .{},
    allocator: std.mem.Allocator,
    io: std.Io,
    owner: std.Thread.Id,
    child: std.process.Child,
    wake: ?Wake,
    configuration: ?std.json.Parsed(std.json.Value) = null,
    output_thread: ?std.Thread = null,
    error_thread: ?std.Thread = null,
    writer_thread: ?std.Thread = null,
    stopping: std.atomic.Value(bool) = .init(false),
    state: std.atomic.Value(Status) = .init(.starting),
    stdout_ended: std.atomic.Value(bool) = .init(false),
    shutdown_answer: std.atomic.Value(bool) = .init(false),
    completion_supported: std.atomic.Value(bool) = .init(false),
    hover_supported: std.atomic.Value(bool) = .init(false),
    definition_supported: std.atomic.Value(bool) = .init(false),
    references_supported: std.atomic.Value(bool) = .init(false),
    rename_supported: std.atomic.Value(bool) = .init(false),
    formatting_supported: std.atomic.Value(bool) = .init(false),
    sync_options: synchronization.Options = .{},
    lock: std.Io.Mutex = .init,
    changed: std.Io.Condition = .init,
    outgoing: std.ArrayList([]u8) = .empty,
    outgoing_bytes: usize = 0,
    outgoing_limit_bytes: usize = 16 * 1024 * 1024,
    incoming: std.ArrayList(model.Message) = .empty,
    incoming_bytes: usize = 0,
    pending: std.AutoHashMapUnmanaged(u64, Pending) = .empty,
    documents: std.StringHashMapUnmanaged(DocumentState) = .empty,
    next_id: u64 = 2,
    stderr_bytes: std.ArrayList(u8) = .empty,
    pub fn start(a: std.mem.Allocator, io: std.Io, config: Config) !*Client {
        if (config.outgoing_limit_bytes == 0 or config.outgoing_limit_bytes > 16 * 1024 * 1024) return error.InvalidOutgoingLimit;
        if (config.command.len == 0 or std.mem.indexOfScalar(u8, config.command, 0) != null) return error.InvalidServerCommand;
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(a);
        try argv.append(a, config.command);
        try argv.appendSlice(a, config.args);
        var environment = std.process.Environ.Map.init(a);
        defer environment.deinit();
        for (config.environment) |pair| try environment.put(pair[0], pair[1]);
        var child = try std.process.spawn(io, .{ .environ_map = if (config.environment.len > 0) &environment else null, .argv = argv.items, .cwd = .{ .path = config.cwd }, .stdin = .pipe, .stdout = .pipe, .stderr = .pipe });
        var transferred = false;
        errdefer if (!transferred) forceKill(&child, io);
        const self = try a.create(Client);
        self.* = .{ .allocator = a, .io = io, .owner = std.Thread.getCurrentId(), .child = child, .wake = config.wake, .outgoing_limit_bytes = config.outgoing_limit_bytes };
        transferred = true;
        errdefer {
            self.stopWriter();
            signalKill(&self.child);
            if (self.writer_thread) |thread| thread.join();
            if (self.output_thread) |thread| thread.join();
            if (self.error_thread) |thread| thread.join();
            forceKill(&self.child, io);
            self.cleanupData();
            a.destroy(self);
        }
        if (config.workspace_configuration != .null) {
            const bytes = try std.json.Stringify.valueAlloc(a, config.workspace_configuration, .{});
            defer a.free(bytes);
            self.configuration = try std.json.parseFromSlice(std.json.Value, transport_allocator, bytes, .{ .allocate = .alloc_always });
        }
        try self.pending.put(transport_allocator, 1, .{ .kind = .initialize });
        const root_uri = try model.fileUri(a, config.root_path orelse config.cwd);
        defer a.free(root_uri);
        try self.enqueue(.{ .jsonrpc = "2.0", .id = @as(u64, 1), .method = "initialize", .params = .{ .processId = @as(?u32, null), .rootUri = root_uri, .initializationOptions = config.initialization_options, .capabilities = .{ .general = .{ .positionEncodings = [_][]const u8{"utf-16"} }, .textDocument = .{ .hover = .{ .contentFormat = [_][]const u8{ "markdown", "plaintext" } }, .synchronization = .{ .didSave = false }, .completion = .{ .completionItem = .{ .snippetSupport = false, .insertReplaceSupport = false } }, .publishDiagnostics = .{ .versionSupport = true } } }, .clientInfo = .{ .name = "Zircon", .version = "0.1.0" } } });
        self.writer_thread = try std.Thread.spawn(.{}, writerMain, .{self});
        self.output_thread = try std.Thread.spawn(.{}, readMain, .{self});
        self.error_thread = try std.Thread.spawn(.{}, stderrMain, .{self});
        return self;
    }
    fn check(self: *Client) !void {
        if (self.owner != std.Thread.getCurrentId()) return error.WrongThread;
        if (self.status() != .ready) return error.ServerNotReady;
    }
    pub fn status(self: *const Client) Status {
        return self.state.load(.acquire);
    }
    pub fn ready(self: *const Client) bool {
        return self.status() == .ready;
    }
    pub fn didOpen(self: *Client, uri: []const u8, language: []const u8, snapshot: text.Snapshot) !void {
        try self.check();
        if (self.documents.contains(uri)) return error.DocumentAlreadyOpen;
        const owned = try self.allocator.dupe(u8, uri);
        errdefer self.allocator.free(owned);
        try self.documents.ensureUnusedCapacity(self.allocator, 1);
        if (self.sync_options.open_close) {
            const bytes = try snapshot.copy(self.allocator, .{ .start = 0, .end = snapshot.byteLen() });
            defer self.allocator.free(bytes);
            try self.enqueue(.{ .jsonrpc = "2.0", .method = "textDocument/didOpen", .params = .{ .textDocument = .{ .uri = uri, .languageId = language, .version = snapshot.revision(), .text = bytes } } });
        }
        self.documents.putAssumeCapacity(owned, .{ .snapshot = snapshot.clone() });
    }
    pub fn didChange(self: *Client, uri: []const u8, snapshot: text.Snapshot) !void {
        return self.change(uri, snapshot, null, &.{});
    }
    /// Ranges are validated against the exact last enqueued snapshot. Missing
    /// retained events use a ranged whole-document replacement for incremental
    /// servers. Queue failures leave both the snapshot and version unchanged.
    pub fn didChangeEdits(self: *Client, uri: []const u8, before: u64, snapshot: text.Snapshot, mappings: []const text.Mapping) !void {
        return self.change(uri, snapshot, before, mappings);
    }
    fn change(self: *Client, uri: []const u8, snapshot: text.Snapshot, before: ?u64, mappings: []const text.Mapping) !void {
        try self.check();
        const current = self.documents.getPtr(uri) orelse return error.DocumentNotOpen;
        if (snapshot.revision() <= current.snapshot.revision()) return error.StaleDocumentVersion;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var text_bytes: usize = 0;
        var incremental = false;
        var resync = false;
        switch (self.sync_options.kind) {
            .none => {},
            .full => {
                const bytes = try snapshot.copy(a, .{ .start = 0, .end = snapshot.byteLen() });
                try self.enqueue(.{ .jsonrpc = "2.0", .method = "textDocument/didChange", .params = .{ .textDocument = .{ .uri = uri, .version = snapshot.revision() }, .contentChanges = [_]struct { text: []const u8 }{.{ .text = bytes }} } });
                text_bytes = bytes.len;
            },
            .incremental => {
                const changes = if (before == current.snapshot.revision())
                    try synchronization.edits(a, current.snapshot, snapshot, mappings)
                else
                    try synchronization.replacement(a, current.snapshot, snapshot);
                try self.enqueue(.{ .jsonrpc = "2.0", .method = "textDocument/didChange", .params = .{ .textDocument = .{ .uri = uri, .version = snapshot.revision() }, .contentChanges = changes } });
                for (changes) |content_change| text_bytes += content_change.text.len;
                incremental = true;
                resync = before != current.snapshot.revision() or mappings.len == 0;
            },
        }
        self.lock.lockUncancelable(self.io);
        self.counters.change_text_bytes +%= text_bytes;
        if (incremental) self.counters.incremental_changes +%= 1;
        if (resync) self.counters.resync_changes +%= 1;
        self.lock.unlock(self.io);
        var previous = current.snapshot;
        current.snapshot = snapshot.clone();
        previous.deinit();
    }
    pub fn didClose(self: *Client, uri: []const u8) !void {
        try self.check();
        if (!self.documents.contains(uri)) return error.DocumentNotOpen;
        if (self.sync_options.open_close) try self.enqueue(.{ .jsonrpc = "2.0", .method = "textDocument/didClose", .params = .{ .textDocument = .{ .uri = uri } } });
        var old = self.documents.fetchRemove(uri).?;
        old.value.snapshot.deinit();
        self.allocator.free(old.key);
    }
    pub fn completion(self: *Client, uri: []const u8, version: u64, cursor_position: model.Position) !u64 {
        try self.check();
        if (!self.completion_supported.load(.acquire)) return error.CompletionNotSupported;
        if ((self.documents.get(uri) orelse return error.DocumentNotOpen).snapshot.revision() != version) return error.StaleDocumentVersion;
        const id = try self.requestId();
        const owned = try transport_allocator.dupe(u8, uri);
        errdefer transport_allocator.free(owned);
        self.lock.lockUncancelable(self.io);
        const inserted = self.pending.put(transport_allocator, id, .{ .kind = .completion, .uri = owned, .version = version });
        self.lock.unlock(self.io);
        try inserted;
        errdefer {
            self.lock.lockUncancelable(self.io);
            _ = self.pending.remove(id);
            self.lock.unlock(self.io);
        }
        try self.enqueue(.{ .jsonrpc = "2.0", .id = id, .method = "textDocument/completion", .params = .{ .textDocument = .{ .uri = uri }, .position = cursor_position, .context = .{ .triggerKind = @as(u8, 1) } } });
        return id;
    }
    pub fn cancel(self: *Client, id: u64) !void {
        try self.check();
        self.lock.lockUncancelable(self.io);
        const removed = self.pending.fetchRemove(id);
        self.lock.unlock(self.io);
        if (removed) |entry| transport_allocator.free(entry.value.uri) else return error.RequestNotFound;
        try self.enqueue(.{ .jsonrpc = "2.0", .method = "$/cancelRequest", .params = .{ .id = id } });
    }
    pub fn supportsHover(self: *const Client) bool {
        return self.hover_supported.load(.acquire);
    }
    pub fn hover(self: *Client, uri: []const u8, version: u64, hover_position: model.Position) !u64 {
        try self.check();
        if (!self.supportsHover()) return error.HoverNotSupported;
        if ((self.documents.get(uri) orelse return error.DocumentNotOpen).snapshot.revision() != version) return error.StaleDocumentVersion;
        const id = try self.requestId();
        const owned = try transport_allocator.dupe(u8, uri);
        errdefer transport_allocator.free(owned);
        self.lock.lockUncancelable(self.io);
        const inserted = self.pending.put(transport_allocator, id, .{ .kind = .hover, .uri = owned, .version = version });
        self.lock.unlock(self.io);
        try inserted;
        errdefer {
            self.lock.lockUncancelable(self.io);
            _ = self.pending.remove(id);
            self.lock.unlock(self.io);
        }
        try self.enqueue(.{ .jsonrpc = "2.0", .id = id, .method = "textDocument/hover", .params = .{ .textDocument = .{ .uri = uri }, .position = hover_position } });
        return id;
    }
    pub fn supportsDefinition(self: *const Client) bool {
        return self.definition_supported.load(.acquire);
    }
    pub fn definition(self: *Client, uri: []const u8, version: u64, cursor_position: model.Position) !u64 {
        try self.check();
        if (!self.supportsDefinition()) return error.DefinitionNotSupported;
        if ((self.documents.get(uri) orelse return error.DocumentNotOpen).snapshot.revision() != version) return error.StaleDocumentVersion;
        const id = try self.requestId();
        const owned = try transport_allocator.dupe(u8, uri);
        errdefer transport_allocator.free(owned);
        self.lock.lockUncancelable(self.io);
        const inserted = self.pending.put(transport_allocator, id, .{ .kind = .definition, .uri = owned, .version = version });
        self.lock.unlock(self.io);
        try inserted;
        errdefer {
            self.lock.lockUncancelable(self.io);
            _ = self.pending.remove(id);
            self.lock.unlock(self.io);
        }
        try self.enqueue(.{ .jsonrpc = "2.0", .id = id, .method = "textDocument/definition", .params = .{ .textDocument = .{ .uri = uri }, .position = cursor_position } });
        return id;
    }
    pub fn supportsReferences(self: *const Client) bool {
        return self.references_supported.load(.acquire);
    }
    pub fn references(self: *Client, uri: []const u8, version: u64, cursor_position: model.Position) !u64 {
        try self.check();
        if (!self.supportsReferences()) return error.ReferencesNotSupported;
        if ((self.documents.get(uri) orelse return error.DocumentNotOpen).snapshot.revision() != version) return error.StaleDocumentVersion;
        const id = try self.requestId();
        const owned = try transport_allocator.dupe(u8, uri);
        errdefer transport_allocator.free(owned);
        self.lock.lockUncancelable(self.io);
        const inserted = self.pending.put(transport_allocator, id, .{ .kind = .references, .uri = owned, .version = version });
        self.lock.unlock(self.io);
        try inserted;
        errdefer {
            self.lock.lockUncancelable(self.io);
            _ = self.pending.remove(id);
            self.lock.unlock(self.io);
        }
        try self.enqueue(.{ .jsonrpc = "2.0", .id = id, .method = "textDocument/references", .params = .{ .textDocument = .{ .uri = uri }, .position = cursor_position, .context = .{ .includeDeclaration = true } } });
        return id;
    }
    pub fn supportsRename(self: *const Client) bool {
        return self.rename_supported.load(.acquire);
    }
    pub fn rename(self: *Client, uri: []const u8, version: u64, cursor_position: model.Position, new_name: []const u8) !u64 {
        try self.check();
        if (!self.supportsRename()) return error.RenameNotSupported;
        if ((self.documents.get(uri) orelse return error.DocumentNotOpen).snapshot.revision() != version) return error.StaleDocumentVersion;
        const id = try self.requestId();
        const owned = try transport_allocator.dupe(u8, uri);
        errdefer transport_allocator.free(owned);
        self.lock.lockUncancelable(self.io);
        const inserted = self.pending.put(transport_allocator, id, .{ .kind = .rename, .uri = owned, .version = version });
        self.lock.unlock(self.io);
        try inserted;
        errdefer {
            self.lock.lockUncancelable(self.io);
            _ = self.pending.remove(id);
            self.lock.unlock(self.io);
        }
        try self.enqueue(.{ .jsonrpc = "2.0", .id = id, .method = "textDocument/rename", .params = .{ .textDocument = .{ .uri = uri }, .position = cursor_position, .newName = new_name } });
        return id;
    }
    pub fn supportsFormatting(self: *const Client) bool {
        return self.formatting_supported.load(.acquire);
    }
    pub fn formatting(self: *Client, uri: []const u8, version: u64) !u64 {
        try self.check();
        if (!self.supportsFormatting()) return error.FormattingNotSupported;
        if ((self.documents.get(uri) orelse return error.DocumentNotOpen).snapshot.revision() != version) return error.StaleDocumentVersion;
        const id = try self.requestId();
        const owned = try transport_allocator.dupe(u8, uri);
        errdefer transport_allocator.free(owned);
        self.lock.lockUncancelable(self.io);
        const inserted = self.pending.put(transport_allocator, id, .{ .kind = .formatting, .uri = owned, .version = version });
        self.lock.unlock(self.io);
        try inserted;
        errdefer {
            self.lock.lockUncancelable(self.io);
            _ = self.pending.remove(id);
            self.lock.unlock(self.io);
        }
        try self.enqueue(.{ .jsonrpc = "2.0", .id = id, .method = "textDocument/formatting", .params = .{ .textDocument = .{ .uri = uri }, .options = .{ .tabSize = 4, .insertSpaces = true } } });
        return id;
    }
    fn requestId(self: *Client) !u64 {
        if (self.next_id == std.math.maxInt(u64)) return error.RequestIdExhausted;
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }
    pub fn drain(self: *Client, a: std.mem.Allocator) ![]model.Message {
        if (self.owner != std.Thread.getCurrentId()) return error.WrongThread;
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        const result = try a.dupe(model.Message, self.incoming.items);
        self.incoming.clearRetainingCapacity();
        self.incoming_bytes = 0;
        return result;
    }
    pub fn stderrCopy(self: *Client, a: std.mem.Allocator) ![]u8 {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        return a.dupe(u8, self.stderr_bytes.items);
    }
    pub fn deinit(self: *Client) void {
        std.debug.assert(self.owner == std.Thread.getCurrentId());
        const was_ready = self.status() == .ready;
        if (was_ready and self.sync_options.open_close) {
            var documents = self.documents.keyIterator();
            while (documents.next()) |uri| self.enqueue(.{ .jsonrpc = "2.0", .method = "textDocument/didClose", .params = .{ .textDocument = .{ .uri = uri.* } } }) catch {};
        }
        self.state.store(.closing, .release);
        if (was_ready) {
            const id = self.requestId() catch 0;
            self.lock.lockUncancelable(self.io);
            self.pending.put(transport_allocator, id, .{ .kind = .shutdown }) catch {};
            self.lock.unlock(self.io);
            self.enqueue(.{ .jsonrpc = "2.0", .id = id, .method = "shutdown", .params = @as(?u8, null) }) catch {};
            self.waitFlag(&self.shutdown_answer, 200);
            if (self.shutdown_answer.load(.acquire)) {
                self.enqueue(.{ .jsonrpc = "2.0", .method = "exit" }) catch {};
                self.waitFlag(&self.stdout_ended, 200);
            }
        }
        self.stopWriter();
        // Kill only this owned server, before joining blocked transport threads.
        // Their bounded I/O checks stop even if a descendant inherited a pipe.
        if (!self.stdout_ended.load(.acquire)) signalKill(&self.child);
        if (self.writer_thread) |thread| thread.join();
        if (self.output_thread) |thread| thread.join();
        if (self.error_thread) |thread| thread.join();
        if (self.child.id != null) {
            if (!self.stdout_ended.load(.acquire)) signalKill(&self.child);
            _ = self.child.wait(self.io) catch {
                self.child.kill(self.io);
            };
        }
        const a = self.allocator;
        self.cleanupData();
        a.destroy(self);
    }
    fn stopWriter(self: *Client) void {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        self.stopping.store(true, .release);
        self.changed.broadcast(self.io);
    }
    fn waitFlag(self: *Client, flag: *std.atomic.Value(bool), milliseconds: i64) void {
        const deadline = timeout(milliseconds).toDeadline(self.io);
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        while (!flag.load(.acquire)) {
            self.changed.waitTimeout(self.io, &self.lock, deadline) catch break;
        }
    }
    fn cleanupData(self: *Client) void {
        if (self.configuration) |*configuration| configuration.deinit();
        for (self.outgoing.items) |bytes| transport_allocator.free(bytes);
        self.outgoing.deinit(transport_allocator);
        for (self.incoming.items) |*message| message.deinit();
        self.incoming.deinit(transport_allocator);
        var pending = self.pending.valueIterator();
        while (pending.next()) |item| transport_allocator.free(item.uri);
        self.pending.deinit(transport_allocator);
        var documents = self.documents.iterator();
        while (documents.next()) |entry| {
            entry.value_ptr.snapshot.deinit();
            self.allocator.free(entry.key_ptr.*);
        }
        self.documents.deinit(self.allocator);
        self.stderr_bytes.deinit(transport_allocator);
    }
    fn enqueue(self: *Client, value: anytype) !void {
        const json = try std.json.Stringify.valueAlloc(transport_allocator, value, .{});
        defer transport_allocator.free(json);
        const bytes = try frame.encode(transport_allocator, json);
        errdefer transport_allocator.free(bytes);
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        if (self.stopping.load(.acquire)) return error.ClientClosing;
        if (bytes.len > self.outgoing_limit_bytes or self.outgoing_bytes > self.outgoing_limit_bytes - bytes.len) return error.OutgoingQueueFull;
        try self.outgoing.append(transport_allocator, bytes);
        self.outgoing_bytes += bytes.len;
        self.counters.queued_messages +%= 1;
        self.counters.queued_bytes +%= bytes.len;
        if (@hasField(@TypeOf(value), "method") and std.mem.eql(u8, value.method, "textDocument/didChange")) self.counters.document_changes +%= 1;
        self.changed.signal(self.io);
    }
    pub fn stats(self: *Client) Stats {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        return self.counters;
    }
    fn publish(self: *Client, message_value: model.Message) void {
        var message = message_value;
        self.lock.lockUncancelable(self.io);
        if (self.incoming.items.len >= 1024 or message.arena.queryCapacity() > 16 * 1024 * 1024 - @min(self.incoming_bytes, 16 * 1024 * 1024)) {
            self.lock.unlock(self.io);
            message.deinit();
            self.state.store(.failed, .release);
            self.notify();
            return;
        }
        self.incoming.append(transport_allocator, message) catch {
            self.lock.unlock(self.io);
            message.deinit();
            self.state.store(.failed, .release);
            self.notify();
            return;
        };
        self.incoming_bytes += message.arena.queryCapacity();
        self.lock.unlock(self.io);
        self.notify();
    }
    fn notify(self: *Client) void {
        if (self.wake) |wake| wake.notify(wake.context);
    }
    fn fail(self: *Client, err: anyerror) void {
        if (self.stopping.load(.acquire)) return;
        self.state.store(.failed, .release);
        var arena = std.heap.ArenaAllocator.init(transport_allocator);
        const message = arena.allocator().dupe(u8, @errorName(err)) catch {
            arena.deinit();
            self.notify();
            return;
        };
        self.publish(.{ .arena = arena, .data = .{ .failure = .{ .message = message } } });
    }
};
fn timeout(milliseconds: i64) std.Io.Timeout {
    return .{ .duration = .{ .raw = .fromMilliseconds(milliseconds), .clock = .awake } };
}
fn signalKill(child: *std.process.Child) void {
    if (child.id) |id| switch (builtin.os.tag) {
        .windows => {},
        .wasi => {},
        else => {
            _ = std.posix.system.kill(id, .KILL);
        },
    };
}
fn forceKill(child: *std.process.Child, io: std.Io) void {
    if (child.id == null) return;
    signalKill(child);
    _ = child.wait(io) catch {
        child.kill(io);
    };
}
fn writerMain(self: *Client) void {
    while (true) {
        self.lock.lockUncancelable(self.io);
        while (self.outgoing.items.len == 0 and !self.stopping.load(.acquire)) self.changed.wait(self.io, &self.lock) catch {};
        if (self.stopping.load(.acquire)) {
            self.lock.unlock(self.io);
            return;
        }
        const bytes = self.outgoing.orderedRemove(0);
        self.outgoing_bytes -= bytes.len;
        self.lock.unlock(self.io);
        defer transport_allocator.free(bytes);
        var at: usize = 0;
        while (at < bytes.len and !self.stopping.load(.acquire)) {
            const result = self.io.operateTimeout(.{ .file_write_streaming = .{ .file = self.child.stdin.?, .data = &.{bytes[at..]} } }, timeout(100)) catch |err| {
                if (err == error.Timeout) continue;
                self.fail(err);
                return;
            };
            const count = result.file_write_streaming catch |err| {
                self.fail(err);
                return;
            };
            if (count == 0) {
                self.fail(error.ServerClosedInput);
                return;
            }
            at += count;
        }
    }
}
fn readMain(self: *Client) void {
    var decoder = frame.Decoder.init(transport_allocator);
    defer decoder.deinit();
    var buffer: [8192]u8 = undefined;
    defer {
        self.stdout_ended.store(true, .release);
        self.changed.broadcast(self.io);
        if (!self.stopping.load(.acquire) and self.status() != .failed) {
            self.state.store(.exited, .release);
            self.publish(.{ .arena = .init(transport_allocator), .data = .exited });
        }
    }
    while (!self.stopping.load(.acquire)) {
        const result = self.io.operateTimeout(.{ .file_read_streaming = .{ .file = self.child.stdout.?, .data = &.{&buffer} } }, timeout(100)) catch |err| {
            if (err == error.Timeout) continue;
            self.fail(err);
            return;
        };
        const count = result.file_read_streaming catch |err| {
            if (err != error.EndOfStream) self.fail(err);
            return;
        };
        if (count == 0) continue;
        decoder.feed(buffer[0..count]) catch |err| {
            self.fail(err);
            return;
        };
        while (decoder.next() catch |err| {
            self.fail(err);
            return;
        }) |body| parse(self, body) catch |err| {
            self.fail(err);
            return;
        };
    }
}
fn stderrMain(self: *Client) void {
    var buffer: [2048]u8 = undefined;
    while (!self.stopping.load(.acquire)) {
        const result = self.io.operateTimeout(.{ .file_read_streaming = .{ .file = self.child.stderr.?, .data = &.{&buffer} } }, timeout(100)) catch |err| {
            if (err == error.Timeout) continue;
            return;
        };
        const count = result.file_read_streaming catch return;
        if (count == 0) continue;
        self.lock.lockUncancelable(self.io);
        const available = 64 * 1024 - @min(64 * 1024, self.stderr_bytes.items.len);
        self.stderr_bytes.appendSlice(transport_allocator, buffer[0..@min(count, available)]) catch {};
        self.lock.unlock(self.io);
    }
}

fn field(value: std.json.Value, name: []const u8) ?std.json.Value {
    return if (value == .object) value.object.get(name) else null;
}
fn string(value: std.json.Value) ![]const u8 {
    if (value != .string) return error.InvalidMessage;
    return value.string;
}
fn unsigned(value: std.json.Value) !u64 {
    if (value != .integer or value.integer < 0) return error.InvalidMessage;
    return @intCast(value.integer);
}
fn position(value: std.json.Value) !model.Position {
    return .{ .line = @intCast(try unsigned(field(value, "line") orelse return error.InvalidMessage)), .character = @intCast(try unsigned(field(value, "character") orelse return error.InvalidMessage)) };
}
fn range(value: std.json.Value) !model.Range {
    return .{ .start = try position(field(value, "start") orelse return error.InvalidMessage), .end = try position(field(value, "end") orelse return error.InvalidMessage) };
}
fn edit(value: std.json.Value) !model.TextEdit {
    return .{ .range = try range(field(value, "range") orelse return error.InvalidMessage), .new_text = try string(field(value, "newText") orelse return error.InvalidMessage) };
}
fn parse(self: *Client, body: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(transport_allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    const root = try std.json.parseFromSliceLeaky(std.json.Value, a, body, .{ .allocate = .alloc_always, .max_value_len = frame.max_message });
    if (root != .object) return error.InvalidMessage;
    if (field(root, "jsonrpc")) |v| {
        if (!std.mem.eql(u8, try string(v), "2.0")) return error.InvalidMessage;
    }
    const id = field(root, "id");
    if (field(root, "method")) |method_value| {
        const method = try string(method_value);
        if (id) |request_id| {
            if (std.mem.eql(u8, method, "workspace/configuration")) {
                const params = field(root, "params") orelse return error.InvalidMessage;
                const items = field(params, "items") orelse return error.InvalidMessage;
                if (items != .array or items.array.items.len > 1024) return error.InvalidMessage;
                const values = try a.alloc(std.json.Value, items.array.items.len);
                for (items.array.items, values) |item, *value| {
                    value.* = if (self.configuration) |configuration| configuration.value else .null;
                    if (field(item, "section")) |section| if (section == .string and section.string.len > 0) {
                        var segments = std.mem.splitScalar(u8, section.string, '.');
                        while (segments.next()) |part| value.* = field(value.*, part) orelse .null;
                    };
                }
                try self.enqueue(.{ .jsonrpc = "2.0", .id = request_id, .result = values });
                arena.deinit();
                return;
            }
            if (std.mem.eql(u8, method, "client/registerCapability") or std.mem.eql(u8, method, "client/unregisterCapability") or std.mem.eql(u8, method, "window/workDoneProgress/create")) {
                try self.enqueue(.{ .jsonrpc = "2.0", .id = request_id, .result = @as(?u8, null) });
                arena.deinit();
                return;
            }
            try self.enqueue(.{ .jsonrpc = "2.0", .id = request_id, .@"error" = .{ .code = @as(i32, -32601), .message = "Method not supported by Zircon" } });
            arena.deinit();
            return;
        }
        const params = field(root, "params") orelse return error.InvalidMessage;
        if (std.mem.eql(u8, method, "textDocument/publishDiagnostics")) {
            const uri = try string(field(params, "uri") orelse return error.InvalidMessage);
            const values = field(params, "diagnostics") orelse return error.InvalidMessage;
            if (values != .array) return error.InvalidMessage;
            if (values.array.items.len > 10_000) return error.TooManyDiagnostics;
            const diagnostics = try a.alloc(model.Diagnostic, values.array.items.len);
            for (values.array.items, diagnostics) |item, *diagnostic| {
                const severity = if (field(item, "severity")) |v| try unsigned(v) else 1;
                diagnostic.* = .{ .range = try range(field(item, "range") orelse return error.InvalidMessage), .message = try string(field(item, "message") orelse return error.InvalidMessage), .severity = switch (severity) {
                    2 => .warning,
                    3 => .information,
                    4 => .hint,
                    else => .error_value,
                }, .source = if (field(item, "source")) |v| try string(v) else null };
            }
            const version = if (field(params, "version")) |v| if (v == .null) null else try unsigned(v) else null;
            self.publish(.{ .arena = arena, .data = .{ .diagnostics = .{ .uri = uri, .version = version, .items = diagnostics } } });
            return;
        }
        if (std.mem.eql(u8, method, "window/logMessage") or std.mem.eql(u8, method, "window/showMessage")) {
            const message = try string(field(params, "message") orelse return error.InvalidMessage);
            const severity = if (field(params, "type")) |v| try unsigned(v) else 3;
            self.publish(.{ .arena = arena, .data = .{ .log = .{ .message = message, .severity = @intCast(@min(255, severity)) } } });
            return;
        }
        arena.deinit();
        return;
    }
    const number = try unsigned(id orelse return error.InvalidMessage);
    self.lock.lockUncancelable(self.io);
    const removed = self.pending.fetchRemove(number);
    self.lock.unlock(self.io);
    const request = if (removed) |entry| entry.value else {
        arena.deinit();
        return;
    };
    defer transport_allocator.free(request.uri);
    if (field(root, "error")) |failure| {
        const message = if (field(failure, "message")) |v| try string(v) else "Language server request failed";
        if (request.kind == .initialize) self.state.store(.failed, .release);
        self.publish(.{ .arena = arena, .data = .{ .failure = .{ .message = message, .request_id = number } } });
        return;
    }
    const result = field(root, "result") orelse return error.InvalidMessage;
    switch (request.kind) {
        .initialize => {
            const capabilities = field(result, "capabilities") orelse return error.InvalidInitializeResult;
            self.sync_options = try synchronization.Options.parse(capabilities);
            const supported = if (field(capabilities, "completionProvider")) |provider| provider != .null and !(provider == .bool and !provider.bool) else false;
            self.completion_supported.store(supported, .release);
            const hover_provider = if (field(capabilities, "hoverProvider")) |provider| provider != .null and !(provider == .bool and !provider.bool) else false;
            self.hover_supported.store(hover_provider, .release);
            const definition_provider = if (field(capabilities, "definitionProvider")) |provider| provider != .null and !(provider == .bool and !provider.bool) else false;
            self.definition_supported.store(definition_provider, .release);
            const references_provider = if (field(capabilities, "referencesProvider")) |provider| provider != .null and !(provider == .bool and !provider.bool) else false;
            self.references_supported.store(references_provider, .release);
            const rename_provider = if (field(capabilities, "renameProvider")) |provider| provider != .null and !(provider == .bool and !provider.bool) else false;
            self.rename_supported.store(rename_provider, .release);
            const formatting_provider = if (field(capabilities, "documentFormattingProvider")) |provider| provider != .null and !(provider == .bool and !provider.bool) else false;
            self.formatting_supported.store(formatting_provider, .release);
            try self.enqueue(.{ .jsonrpc = "2.0", .method = "initialized", .params = @as(struct {}, .{}) });
            if (self.configuration) |configuration| try self.enqueue(.{ .jsonrpc = "2.0", .method = "workspace/didChangeConfiguration", .params = .{ .settings = configuration.value } });
            self.state.store(.ready, .release);
            self.publish(.{ .arena = arena, .data = .initialized });
        },
        .shutdown => {
            self.shutdown_answer.store(true, .release);
            self.changed.broadcast(self.io);
            arena.deinit();
        },
        .completion => {
            const entries = if (result == .array) result else if (result == .null) std.json.Value{ .array = std.array_list.Managed(std.json.Value).init(a) } else field(result, "items") orelse return error.InvalidCompletionResult;
            if (entries != .array or entries.array.items.len > 10_000) return error.InvalidCompletionResult;
            const items = try a.alloc(model.Completion, entries.array.items.len);
            for (entries.array.items, items) |item, *completion| {
                const label = try string(field(item, "label") orelse return error.InvalidCompletionResult);
                const insert_text = if (field(item, "insertText")) |v| try string(v) else label;
                completion.* = .{ .label = label, .insert_text = insert_text, .detail = if (field(item, "detail")) |v| try string(v) else null, .text_edit = if (field(item, "textEdit")) |v| if (field(v, "range") != null) try edit(v) else null else null, .snippet = if (field(item, "insertTextFormat")) |v| try unsigned(v) == 2 else false };
                if (field(item, "additionalTextEdits")) |edits| {
                    if (edits != .array or edits.array.items.len > 1024) return error.InvalidCompletionResult;
                    const additional = try a.alloc(model.TextEdit, edits.array.items.len);
                    for (edits.array.items, additional) |value, *actual| actual.* = try edit(value);
                    completion.additional_edits = additional;
                }
            }
            const incomplete = if (field(result, "isIncomplete")) |v| if (v == .bool) v.bool else false else false;
            const uri = try a.dupe(u8, request.uri);
            self.publish(.{ .arena = arena, .data = .{ .completion = .{ .id = number, .uri = uri, .version = request.version, .items = items, .incomplete = incomplete } } });
        },
        .hover => {
            const contents = if (result == .null) "" else try hover_content.contents(a, field(result, "contents") orelse return error.InvalidHover);
            self.publish(.{ .arena = arena, .data = .{ .hover = .{ .id = number, .uri = try a.dupe(u8, request.uri), .version = request.version, .contents = contents } } });
        },
        .definition, .references => {
            if (result == .null) {
                self.publish(.{ .arena = arena, .data = .{ .locations = .{ .id = number, .uri = try a.dupe(u8, request.uri), .version = request.version, .kind = if (request.kind == .references) .references else .definition, .items = &.{} } } });
                return;
            }
            const items = if (result == .array) blk: {
                if (result.array.items.len > 1024) return error.InvalidDefinitionResult;
                const many = try a.alloc(model.Location, result.array.items.len);
                for (result.array.items, many) |value, *location| location.* = .{ .uri = try string(field(value, "uri") orelse return error.InvalidDefinitionResult), .range = try range(field(value, "range") orelse return error.InvalidDefinitionResult) };
                break :blk many;
            } else blk: {
                const one = try a.alloc(model.Location, 1);
                one[0] = .{ .uri = try string(field(result, "uri") orelse return error.InvalidDefinitionResult), .range = try range(field(result, "range") orelse return error.InvalidDefinitionResult) };
                break :blk one;
            };
            self.publish(.{ .arena = arena, .data = .{ .locations = .{ .id = number, .uri = try a.dupe(u8, request.uri), .version = request.version, .kind = if (request.kind == .references) .references else .definition, .items = items } } });
        },
        .rename => {
            if (result == .null) {
                self.publish(.{ .arena = arena, .data = .{ .workspace_edit = .{ .id = number, .uri = try a.dupe(u8, request.uri), .version = request.version, .files = &.{} } } });
                return;
            }
            const changes = field(result, "changes") orelse return error.InvalidWorkspaceEdit;
            if (changes != .object or changes.object.count() > 1024) return error.InvalidWorkspaceEdit;
            const files = try a.alloc(model.FileEdits, changes.object.count());
            var index: usize = 0;
            var iterator = changes.object.iterator();
            while (iterator.next()) |entry| : (index += 1) {
                if (entry.value_ptr.* != .array or entry.value_ptr.array.items.len > 4096) return error.InvalidWorkspaceEdit;
                const edits = try a.alloc(model.TextEdit, entry.value_ptr.array.items.len);
                for (entry.value_ptr.array.items, edits) |value, *actual| actual.* = try edit(value);
                files[index] = .{ .uri = entry.key_ptr.*, .edits = edits };
            }
            self.publish(.{ .arena = arena, .data = .{ .workspace_edit = .{ .id = number, .uri = try a.dupe(u8, request.uri), .version = request.version, .files = files } } });
        },
        .formatting => {
            if (result == .null) {
                self.publish(.{ .arena = arena, .data = .{ .edits = .{ .id = number, .uri = try a.dupe(u8, request.uri), .version = request.version, .items = &.{} } } });
                return;
            }
            if (result != .array or result.array.items.len > 4096) return error.InvalidFormattingResult;
            const items = try a.alloc(model.TextEdit, result.array.items.len);
            for (result.array.items, items) |value, *actual| actual.* = try edit(value);
            self.publish(.{ .arena = arena, .data = .{ .edits = .{ .id = number, .uri = try a.dupe(u8, request.uri), .version = request.version, .items = items } } });
        },
    }
}
