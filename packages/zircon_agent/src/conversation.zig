const std = @import("std");
const wire = @import("transport.zig");
pub const Protocol = enum { acp, codex };
pub const State = enum { disconnected, connecting, ready, running, permission, failed };
pub const Role = enum { user, assistant, activity, error_value };
pub const Entry = struct { role: Role, text: std.ArrayList(u8) = .empty };
pub const Model = struct { id: []u8, name: []u8 };
pub const Conversation = struct {
    allocator: std.mem.Allocator,
    client: ?*wire.Client = null,
    protocol: Protocol = .acp,
    state: State = .disconnected,
    entries: std.ArrayList(Entry) = .empty,
    models: std.ArrayList(Model) = .empty,
    modes: std.ArrayList(Model) = .empty,
    efforts: std.ArrayList(Model) = .empty,
    model_config: []u8 = &.{},
    mode_config: []u8 = &.{},
    effort_config: []u8 = &.{},
    mode: []u8 = &.{},
    effort: []u8 = &.{},
    choice_request: ?u64 = null,
    choice_kind: enum { model, mode, effort } = .model,
    choice_value: []u8 = &.{},
    session: []u8 = &.{},
    turn: []u8 = &.{},
    model: []u8 = &.{},
    cwd: []u8 = &.{},
    permission: ?wire.Message = null,
    permissions: std.ArrayList(wire.Message) = .empty,
    resume_session: []u8 = &.{},
    next_id: u64 = 100,
    prompt_id: ?u64 = null,
    bytes: usize = 0,
    revision: u64 = 0,
    pub fn init(a: std.mem.Allocator) Conversation {
        return .{ .allocator = a };
    }
    pub fn deinit(self: *Conversation) void {
        self.disconnect();
        for (self.entries.items) |*entry| entry.text.deinit(self.allocator);
        self.entries.deinit(self.allocator);
        for (self.models.items) |model| {
            self.allocator.free(model.id);
            self.allocator.free(model.name);
        }
        self.models.deinit(self.allocator);
        self.freeModels(&self.modes);
        self.modes.deinit(self.allocator);
        self.freeModels(&self.efforts);
        self.efforts.deinit(self.allocator);
        inline for (.{ "model_config", "mode_config", "effort_config", "mode", "effort", "choice_value" }) |name| self.allocator.free(@field(self, name));
        self.allocator.free(self.resume_session);
        self.allocator.free(self.session);
        self.allocator.free(self.turn);
        self.allocator.free(self.model);
        self.allocator.free(self.cwd);
    }
    pub fn disconnect(self: *Conversation) void {
        if (self.client) |client| client.deinit();
        self.client = null;
        if (self.permission) |*permission| permission.deinit();
        self.permission = null;
        for (self.permissions.items) |*permission| permission.deinit();
        self.permissions.deinit(self.allocator);
        self.permissions = .empty;
        self.state = .disconnected;
    }
    pub fn connect(self: *Conversation, io: std.Io, config: wire.Config, protocol: Protocol) !void {
        self.disconnect();
        const cwd = try self.allocator.dupe(u8, config.cwd);
        self.allocator.free(self.cwd);
        self.cwd = cwd;
        self.allocator.free(self.session);
        self.session = &.{};
        self.protocol = protocol;
        self.client = try wire.Client.start(self.allocator, io, config);
        errdefer self.disconnect();
        self.state = .connecting;
        if (protocol == .acp) try self.client.?.send(.{ .jsonrpc = "2.0", .id = @as(u64, 1), .method = "initialize", .params = .{ .protocolVersion = @as(u32, 1), .clientCapabilities = .{ .fs = .{ .readTextFile = false, .writeTextFile = false }, .terminal = false }, .clientInfo = .{ .name = "zircon", .version = "0.1.0" } } }) else try self.client.?.send(.{ .id = @as(u64, 1), .method = "initialize", .params = .{ .clientInfo = .{ .name = "zircon", .version = "0.1.0" } } });
        self.revision +%= 1;
    }
    pub fn reconnect(self: *Conversation, io: std.Io, config: wire.Config, protocol: Protocol) !void {
        const sid = try self.allocator.dupe(u8, self.session);
        errdefer self.allocator.free(sid);
        try self.connect(io, config, protocol);
        self.allocator.free(self.resume_session);
        self.resume_session = sid;
    }
    pub fn append(self: *Conversation, role: Role, bytes: []const u8, merge: bool) !void {
        if (bytes.len == 0) return;
        if (self.bytes + bytes.len > 8 * 1024 * 1024 or self.entries.items.len >= 10000) return error.TranscriptTooLarge;
        if (!merge or self.entries.items.len == 0 or self.entries.items[self.entries.items.len - 1].role != role) try self.entries.append(self.allocator, .{ .role = role });
        try self.entries.items[self.entries.items.len - 1].text.appendSlice(self.allocator, bytes);
        self.bytes += bytes.len;
        self.revision +%= 1;
    }
    pub fn prompt(self: *Conversation, bytes: []const u8) !void {
        if (self.state != .ready) return error.AgentNotReady;
        if (std.mem.trim(u8, bytes, " \r\n\t").len == 0) return error.EmptyPrompt;
        const id = self.next_id;
        self.next_id += 1;
        if (self.protocol == .acp) try self.client.?.send(.{ .jsonrpc = "2.0", .id = id, .method = "session/prompt", .params = .{ .sessionId = self.session, .prompt = [_]struct { type: []const u8 = "text", text: []const u8 }{.{ .text = bytes }} } }) else try self.client.?.send(.{ .id = id, .method = "turn/start", .params = .{ .threadId = self.session, .model = if (self.model.len > 0) self.model else @as(?[]const u8, null), .input = [_]struct { type: []const u8 = "text", text: []const u8 }{.{ .text = bytes }} } });
        try self.append(.user, bytes, false);
        self.prompt_id = id;
        self.state = .running;
    }
    pub fn chooseModel(self: *Conversation, id: []const u8) !void {
        try self.choose(.model, id);
    }
    pub fn chooseMode(self: *Conversation, id: []const u8) !void {
        try self.choose(.mode, id);
    }
    pub fn chooseEffort(self: *Conversation, id: []const u8) !void {
        try self.choose(.effort, id);
    }
    fn choose(self: *Conversation, kind: @TypeOf(self.choice_kind), id: []const u8) !void {
        if (self.state != .ready or self.choice_request != null) return error.AgentNotReady;
        if (self.protocol == .codex) {
            if (kind != .model) return error.AgentOptionUnsupported;
            try self.replace(&self.model, id);
            return;
        }
        const config_id = switch (kind) {
            .model => self.model_config,
            .mode => self.mode_config,
            .effort => self.effort_config,
        };
        if (config_id.len > 0) try self.client.?.send(.{ .jsonrpc = "2.0", .id = self.next_id, .method = "session/set_config_option", .params = .{ .sessionId = self.session, .configId = config_id, .value = id } }) else if (kind == .model) try self.client.?.send(.{ .jsonrpc = "2.0", .id = self.next_id, .method = "session/set_model", .params = .{ .sessionId = self.session, .modelId = id } }) else return error.AgentOptionUnsupported;
        try self.replace(&self.choice_value, id);
        self.choice_kind = kind;
        self.choice_request = self.next_id;
        self.next_id += 1;
    }
    pub fn cancel(self: *Conversation) !void {
        if (self.client == null) return;
        if (self.permission != null) try self.answer(null);
        if (self.protocol == .acp) try self.client.?.send(.{ .jsonrpc = "2.0", .method = "session/cancel", .params = .{ .sessionId = self.session } }) else if (self.turn.len > 0) {
            try self.client.?.send(.{ .id = self.next_id, .method = "turn/interrupt", .params = .{ .threadId = self.session, .turnId = self.turn } });
            self.next_id += 1;
        }
    }
    pub fn answer(self: *Conversation, option: ?[]const u8) !void {
        const permission = self.permission orelse return error.NoPermissionRequest;
        const id = field(permission.value, "id") orelse return error.InvalidAgentMessage;
        if (self.protocol == .acp) {
            if (option) |selected| try self.client.?.send(.{ .jsonrpc = "2.0", .id = id, .result = .{ .outcome = .{ .outcome = "selected", .optionId = selected } } }) else try self.client.?.send(.{ .jsonrpc = "2.0", .id = id, .result = .{ .outcome = .{ .outcome = "cancelled" } } });
        } else try self.client.?.send(.{ .id = id, .result = .{ .decision = option orelse "cancel" } });
        self.permission.?.deinit();
        self.permission = if (self.permissions.items.len > 0) self.permissions.orderedRemove(0) else null;
        self.state = if (self.permission != null) .permission else .running;
        self.revision +%= 1;
    }
    pub fn poll(self: *Conversation) !bool {
        const client = self.client orelse return false;
        var changed = false;
        var count: usize = 0;
        while (count < 256) : (count += 1) {
            var message = client.poll() orelse break;
            const keep = self.receive(message.value) catch |err| {
                message.deinit();
                self.state = .failed;
                try self.append(.error_value, @errorName(err), false);
                return true;
            };
            if (keep) {
                if (self.permission != null) {
                    if (self.permissions.items.len >= 32) {
                        message.deinit();
                        return error.TooManyPermissionRequests;
                    }
                    self.permissions.append(self.allocator, message) catch |err| {
                        message.deinit();
                        return err;
                    };
                } else self.permission = message;
                self.state = .permission;
            } else message.deinit();
            changed = true;
        }
        if (client.status() != .running and self.state != .failed and self.state != .disconnected) {
            self.state = .failed;
            try self.append(.error_value, "Agent connection closed. Check its CLI login and configuration, then reconnect.", false);
            changed = true;
        }
        if (changed) self.revision +%= 1;
        return changed;
    }
    fn replace(self: *Conversation, target: *[]u8, value: []const u8) !void {
        const copy = try self.allocator.dupe(u8, value);
        self.allocator.free(target.*);
        target.* = copy;
    }
    fn freeModels(self: *Conversation, models: *std.ArrayList(Model)) void {
        for (models.items) |model| {
            self.allocator.free(model.id);
            self.allocator.free(model.name);
        }
        models.clearRetainingCapacity();
    }
    fn configModels(self: *Conversation, models: *std.ArrayList(Model), values: std.json.Value) anyerror!void {
        if (values != .array) return;
        for (values.array.items) |option| {
            if (field(option, "options")) |group| {
                try self.configModels(models, group);
                continue;
            }
            const id = string(field(option, "value"));
            if (id.len == 0 or models.items.len >= 2000) continue;
            const owned = try self.allocator.dupe(u8, id);
            errdefer self.allocator.free(owned);
            const name = try self.allocator.dupe(u8, string(field(option, "name")));
            errdefer self.allocator.free(name);
            try models.append(self.allocator, .{ .id = owned, .name = name });
        }
    }
    fn configOptions(self: *Conversation, options: std.json.Value) !void {
        if (options != .array) return;
        for (options.array.items) |option| {
            const category = string(field(option, "category"));
            const current = string(field(option, "currentValue"));
            const id = string(field(option, "id"));
            const values = field(option, "options") orelse continue;
            if (std.mem.eql(u8, category, "model")) {
                try self.replace(&self.model_config, id);
                try self.replace(&self.model, current);
                self.freeModels(&self.models);
                try self.configModels(&self.models, values);
            } else if (std.mem.eql(u8, category, "mode")) {
                try self.replace(&self.mode_config, id);
                try self.replace(&self.mode, current);
                self.freeModels(&self.modes);
                try self.configModels(&self.modes, values);
            } else if (std.mem.eql(u8, category, "thought_level")) {
                try self.replace(&self.effort_config, id);
                try self.replace(&self.effort, current);
                self.freeModels(&self.efforts);
                try self.configModels(&self.efforts, values);
            }
        }
    }
    fn addModels(self: *Conversation, values: std.json.Value, acp: bool) !void {
        if (values != .array) return;
        for (self.models.items) |model| {
            self.allocator.free(model.id);
            self.allocator.free(model.name);
        }
        self.models.clearRetainingCapacity();
        for (values.array.items[0..@min(values.array.items.len, 1000)]) |model| {
            const id = string(field(model, if (acp) "modelId" else "id"));
            if (id.len == 0) continue;
            const owned = try self.allocator.dupe(u8, id);
            errdefer self.allocator.free(owned);
            const name = try self.allocator.dupe(u8, string(field(model, if (acp) "name" else "displayName")));
            errdefer self.allocator.free(name);
            try self.models.append(self.allocator, .{ .id = owned, .name = name });
        }
    }
    fn receive(self: *Conversation, root: std.json.Value) !bool {
        const method = string(field(root, "method"));
        const params = field(root, "params") orelse .null;
        const id = field(root, "id");
        if (method.len > 0) {
            if (id) |request| {
                if (std.mem.eql(u8, method, "session/request_permission") or std.mem.eql(u8, method, "item/commandExecution/requestApproval") or std.mem.eql(u8, method, "item/fileChange/requestApproval")) {
                    const tool = field(params, "toolCall") orelse .null;
                    const title = string(field(tool, "title"));
                    const reason = string(field(params, "reason"));
                    try self.append(.activity, if (title.len > 0) title else if (reason.len > 0) reason else "Agent requests permission", false);
                    if (field(params, "command") orelse field(tool, "rawInput")) |input| {
                        const details = try std.json.Stringify.valueAlloc(self.allocator, input, .{ .whitespace = .indent_2 });
                        defer self.allocator.free(details);
                        const note = try std.mem.concat(self.allocator, u8, &.{ "\n\n```\n", details, "\n```" });
                        defer self.allocator.free(note);
                        try self.append(.activity, note, true);
                    }
                    return true;
                }
                try self.client.?.send(.{ .jsonrpc = "2.0", .id = request, .@"error" = .{ .code = @as(i32, -32601), .message = "This agent client capability is not supported" } });
                try self.append(.activity, method, false);
                return false;
            }
            if (std.mem.eql(u8, method, "session/update")) {
                const update = field(params, "update") orelse .null;
                const kind = string(field(update, "sessionUpdate"));
                if (std.mem.eql(u8, kind, "config_option_update")) {
                    if (field(update, "configOptions")) |options| try self.configOptions(options);
                } else if (std.mem.eql(u8, kind, "agent_message_chunk")) {
                    const content = field(update, "content") orelse .null;
                    if (std.mem.eql(u8, string(field(content, "type")), "text")) try self.append(.assistant, string(field(content, "text")), true);
                } else if (std.mem.eql(u8, kind, "tool_call") or std.mem.eql(u8, kind, "tool_call_update")) {
                    const title = string(field(update, "title"));
                    if (title.len > 0) try self.append(.activity, title, false);
                }
            } else if (std.mem.eql(u8, method, "item/agentMessage/delta")) {
                try self.append(.assistant, string(field(params, "delta")), true);
            } else if (std.mem.eql(u8, method, "item/commandExecution/outputDelta")) {
                try self.append(.activity, string(field(params, "delta")), true);
            } else if (std.mem.eql(u8, method, "turn/started")) {
                try self.replace(&self.turn, string(field(field(params, "turn") orelse .null, "id")));
            } else if (std.mem.eql(u8, method, "turn/completed")) {
                self.state = .ready;
                const turn = field(params, "turn") orelse .null;
                if (field(turn, "error")) |err| if (err != .null) try self.append(.error_value, string(field(err, "message")), false);
            } else if (std.mem.eql(u8, method, "item/started") or std.mem.eql(u8, method, "item/completed")) {
                const item = field(params, "item") orelse .null;
                const kind = string(field(item, "type"));
                if (!std.mem.eql(u8, kind, "agentMessage") and !std.mem.eql(u8, kind, "userMessage")) try self.append(.activity, if (field(item, "command")) |command| string(command) else kind, false);
            } else if (std.mem.eql(u8, method, "error")) try self.append(.error_value, string(field(field(params, "error") orelse params, "message")), false);
            return false;
        }
        if (field(root, "error")) |err| {
            try self.append(.error_value, string(field(err, "message")), false);
            const number = if (id != null and id.? == .integer) id.?.integer else 0;
            if (self.choice_request != null and number == self.choice_request.?) self.choice_request = null;
            if (number <= 2) self.state = .failed else if (self.prompt_id != null and number == self.prompt_id.?) self.state = .ready;
            return false;
        }
        const number = if (id != null and id.? == .integer) id.?.integer else return false;
        const result = field(root, "result") orelse .null;
        if (self.choice_request != null and number == self.choice_request.?) {
            switch (self.choice_kind) {
                .model => try self.replace(&self.model, self.choice_value),
                .mode => try self.replace(&self.mode, self.choice_value),
                .effort => try self.replace(&self.effort, self.choice_value),
            }
            self.choice_request = null;
            if (field(result, "configOptions")) |options| try self.configOptions(options);
        } else if (number == 1) {
            if (self.protocol == .acp) {
                if (self.resume_session.len > 0) {
                    const caps = field(result, "agentCapabilities") orelse .null;
                    const load = field(caps, "loadSession") orelse .null;
                    if (load != .bool or !load.bool) return error.SessionResumeUnsupported;
                    try self.client.?.send(.{ .jsonrpc = "2.0", .id = @as(u64, 2), .method = "session/load", .params = .{ .sessionId = self.resume_session, .cwd = self.cwd, .mcpServers = @as([]const struct {}, &.{}) } });
                } else try self.client.?.send(.{ .jsonrpc = "2.0", .id = @as(u64, 2), .method = "session/new", .params = .{ .cwd = self.cwd, .mcpServers = @as([]const struct {}, &.{}) } });
            } else {
                try self.client.?.send(.{ .method = "initialized", .params = @as(struct {}, .{}) });
                if (self.resume_session.len > 0) try self.client.?.send(.{ .id = @as(u64, 2), .method = "thread/resume", .params = .{ .threadId = self.resume_session, .cwd = self.cwd, .approvalPolicy = "on-request", .sandbox = "workspace-write" } }) else try self.client.?.send(.{ .id = @as(u64, 2), .method = "thread/start", .params = .{ .cwd = self.cwd, .approvalPolicy = "on-request", .sandbox = "workspace-write" } });
                try self.client.?.send(.{ .id = @as(u64, 3), .method = "model/list", .params = @as(struct {}, .{}) });
            }
        } else if (number == 2) {
            const sid = if (self.protocol == .acp) string(field(result, "sessionId")) else string(field(field(result, "thread") orelse .null, "id"));
            if (sid.len == 0 and self.resume_session.len == 0) return error.MissingSessionId;
            try self.replace(&self.session, if (sid.len > 0) sid else self.resume_session);
            if (self.protocol == .acp) if (field(result, "models")) |models| {
                try self.replace(&self.model, string(field(models, "currentModelId")));
                if (field(models, "availableModels")) |list| try self.addModels(list, true);
            };
            if (field(result, "configOptions")) |options| try self.configOptions(options);
            self.state = .ready;
        } else if (number == 3 and self.protocol == .codex) {
            if (field(result, "data")) |models| try self.addModels(models, false);
        } else if (self.prompt_id != null and number == self.prompt_id.?) {
            if (self.protocol == .acp) self.state = .ready else if (field(result, "turn")) |turn| try self.replace(&self.turn, string(field(turn, "id")));
        }
        return false;
    }
};
pub fn field(value: std.json.Value, name: []const u8) ?std.json.Value {
    return if (value == .object) value.object.get(name) else null;
}
pub fn string(value: ?std.json.Value) []const u8 {
    return if (value) |v| if (v == .string) v.string else "" else "";
}
