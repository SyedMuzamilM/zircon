//! Agent workspace uses the same native editor, Markdown, icons and controls.
const std = @import("std");
const agent = @import("zircon_agent");
const text = @import("zircon_text");
const ui = @import("zircon_ui");
const actions = @import("../actions.zig");
const commands_module = @import("../commands.zig");
const service = @import("../services/agents.zig");
const shell = @import("../shell.zig");
const view_module = @import("../view.zig");
const v = @import("components.zig");
const field_input = @import("input.zig");
const overlays = @import("overlays.zig");
const Shell = shell.Shell;
const Command = commands_module.Command;
pub fn render(self: *const Shell, b: *ui.Ui) !ui.Element {
    const c = self.colors;
    const wide = b.viewport().width >= 1000;
    const rail_width: f32 = if (b.viewport().width < 700) 150 else 200;
    var sessions: std.ArrayList(ui.Element) = .empty;
    try sessions.append(b.allocator(), try b.fluent().div()
        .h(.{ .px = 42 })
        .padding(.{ .left = 12, .right = 8 })
        .items_center()
        .gap_px(6)
        .shrink_0()
        .flex()
        .children(.{
            b.fluent().adopt(try v.text(b, "Conversations", c.text, 13))
                .style(.{ .flex_grow = 1, .text = .{ .size = 13, .color = c.text } }),
            v.iconButton(b, c, .agent_new, "New conversation", .plus, false),
        }).build());
    const visible = try ui.controls.visibleRows(self.agents.sessions.items.len, 52, self.agents.session_scroll.offset, @max(0, b.viewport().height - 160), 1);
    if (visible.top > 0) try sessions.append(b.allocator(), try b.fluent().div()
        .h(.{ .px = visible.top })
        .shrink_0()
        .children(.{})
        .build());
    for (self.agents.sessions.items[visible.start..visible.end], visible.start..) |session, index| {
        const state = session.conversation.state;
        const status = try std.fmt.allocPrint(b.allocator(), "{s} · {s}", .{ session.provider, @tagName(state) });
        try sessions.append(b.allocator(), try b.fluent().button(.{
            .label = session.title,
        })
            .h(.{ .px = 52 })
            .shrink_0()
            .padding(.{ .left = 12, .top = 8, .right = 8 })
            .gap_px(5)
            .background(if (index == self.agents.active) c.selected else null)
            .hover_background(c.hover)
            .overflow_hidden()
            .on_click(b.onClickWith(selectSession, @as(u32, @intCast(index))))
            .children(&.{
                try v.text(b, session.title, c.text, 12),
                try v.text(b, status, c.muted, 10),
            }).id(.{ .number = @intCast(index) }).build());
    }
    try sessions.append(b.allocator(), try b.fluent().div().grow().children(.{}).build());
    try sessions.append(b.allocator(), try b.fluent().div()
        .gap_px(6)
        .padding(ui.Insets.all(8))
        .shrink_0()
        .flex_col()
        .children(.{
            v.actionButton(b, c, .agent_config, "Configure providers", false),
            v.actionButton(b, c, .agent_mode, "Back to editor", false),
        }).build());
    const rail = try b.fluent().div()
        .w(.{ .px = rail_width })
        .shrink_0()
        .background(c.sidebar)
        .overflow_hidden()
        .flex_col()
        .children(sessions.items)
        .listeners(.{ .on_input = b.onInput(scrollSessions) })
        .build();
    var content: std.ArrayList(ui.Element) = .empty;
    const session = self.agents.current();
    const provider_name = if (session) |s| s.provider else if (self.agents.config) |config| config.value.providers[self.agents.provider].name else "Choose provider";
    const model_name = if (session) |s| if (s.conversation.model.len > 0) s.conversation.model else "Default model" else "Default model";
    var header: std.ArrayList(ui.Element) = .empty;
    try header.appendSlice(b.allocator(), &.{ try pickerButton(b, c, provider_name, .providers), try pickerButton(b, c, model_name, .models) });
    if (session) |current| {
        if (current.conversation.modes.items.len > 0) try header.append(b.allocator(), try pickerButton(b, c, current.conversation.mode, .modes));
        if (current.conversation.efforts.items.len > 0) try header.append(b.allocator(), try pickerButton(b, c, current.conversation.effort, .efforts));
    }
    if (session) |current| if (lastResponse(current).len > 0) try header.append(b.allocator(), try b.fluent().button(.{
        .label = "Copy last response",
        .tooltip = "Copy last response",
        .tooltip_colors = .{ c.panel, c.text, c.line },
    })
        .style(v.iconButtonStyle(c, false))
        .on_click(b.onClick(copyResponse))
        .children(&.{try v.icon(b, .copy, c.muted, 16)})
        .build());
    try header.appendSlice(b.allocator(), &.{ try b.fluent().div()
        .grow()
        .children(.{})
        .build(), try v.iconButton(b, c, .agent_transcript, "Open saved conversation", .file, false), try v.iconButton(b, c, .agent_toggle_editor, "Toggle editor and changes", .split, self.agent_editor) });
    try content.append(b.allocator(), try b.fluent().div()
        .h(.{ .px = 42 })
        .shrink_0()
        .items_center()
        .padding(.{ .left = 12, .right = 12 })
        .gap_px(6)
        .overflow_hidden()
        .flex()
        .children(header.items)
        .build());
    try content.append(b.allocator(), try v.rule(b, c));
    if (session) |s| {
        if (s.conversation.entries.items.len == 0) {
            const welcome = if (s.conversation.state == .ready) try std.fmt.allocPrint(b.allocator(), "Connected to {s}", .{s.provider}) else "Connect your agent";
            try content.append(b.allocator(), try b.fluent().div()
                .grow()
                .justify_center()
                .items_center()
                .gap_px(12)
                .padding(ui.Insets.all(16))
                .overflow_hidden()
                .flex_col()
                .children(.{
                    v.icon(b, .commands, c.accent, 26),
                    v.text(b, welcome, c.text, 18),
                    v.text(b, "Describe a task below, or attach a file.", c.muted, 12),
                }).build());
        } else try content.append(b.allocator(), try b.fluent().adopt(try s.preview.render(b))
            .id(.{ .string = "agent-transcript" })
            .listeners(.{ .focusable = true, .on_input = b.onInput(onTranscript) })
            .build());
        if (s.conversation.permission) |permission| {
            const params = agent.field(permission.value, "params") orelse .null;
            var buttons: std.ArrayList(ui.Element) = .empty;
            if (s.conversation.protocol == .acp) {
                if (agent.field(params, "options")) |options| if (options == .array) for (options.array.items[0..@min(16, options.array.items.len)], 0..) |option, index| {
                    try buttons.append(b.allocator(), try b.fluent().button(.{
                        .label = agent.string(agent.field(option, "name")),
                    })
                        .style(v.buttonStyle(c, false))
                        .on_click(b.onClickWith(answer, @as(u32, @intCast(index))))
                        .build());
                };
            } else {
                try buttons.appendSlice(b.allocator(), &.{ try b.fluent().button(.{
                    .label = "Allow once",
                })
                    .style(v.buttonStyle(c, true))
                    .on_click(b.onClickWith(answer, @as(u32, 0)))
                    .build(), try b.fluent().button(.{
                    .label = "Reject",
                }).style(v.buttonStyle(c, false)).on_click(b.onClickWith(answer, @as(u32, 1))).build() });
            }
            try content.append(b.allocator(), try b.fluent().div()
                .gap_px(8)
                .padding(ui.Insets.all(12))
                .background(c.panel)
                .shrink_0()
                .flex_col()
                .children(.{
                    v.text(b, "Permission required · review the request above", c.warning, 12),
                    b.fluent().div().gap_px(6).overflow_hidden().flex().children(buttons.items),
                }).build());
        }
    } else {
        try content.append(b.allocator(), try b.fluent().div()
            .grow()
            .justify_center()
            .items_center()
            .gap_px(12)
            .padding(ui.Insets.all(20))
            .flex_col()
            .children(.{
                v.icon(b, .commands, c.accent, 28),
                v.text(b, "Work with an agent", c.text, 19),
                v.text(b, "Use a CLI login you already have.", c.muted, 12),
                v.actionButton(b, c, .agent_connect, "Connect", true),
            }).build());
    }
    if (self.agents.composer) |*compose| {
        var canvas = try compose.editor.render(&compose.document, b);
        canvas = try b.fluent().adopt(canvas)
            .style(.{ .height = .{ .px = 100 }, .flex_shrink = 0, .overflow = .hidden })
            .id(.{ .string = "agent-composer" })
            .listeners(.{ .focusable = true, .on_input = b.onInput(onComposer) })
            .build();
        canvas = try b.fluent().adopt(canvas).request_focus(self.agents.focus).build();
        try content.append(b.allocator(), try v.rule(b, c));
        try content.append(b.allocator(), canvas);
    }
    const state = if (session) |s| s.conversation.state else .disconnected;
    const running = state == .running or state == .permission;
    try content.append(b.allocator(), try b.fluent().div()
        .h(.{ .px = 38 })
        .shrink_0()
        .padding(.{ .left = 10, .right = 10 })
        .gap_px(6)
        .items_center()
        .overflow_hidden()
        .flex()
        .children(&.{
            try v.iconButton(b, c, .agent_context, "Attach editor selection or file", .plus, false),
            try v.text(b, if (state == .ready) "Enter sends · Shift Enter adds a line" else if (state == .disconnected or state == .failed) "Log in using your CLI, then connect." else @tagName(state), c.muted, 11),
            try b.fluent().div().grow().children(.{}).build(),
            try v.actionButton(b, c, if (running) .agent_cancel else if (state == .ready) .agent_send else .agent_connect, if (running) "Stop" else if (state == .ready) "Send" else "Connect", true),
        }).build());
    const chat = try b.fluent().div()
        .grow()
        .min_w(.{ .px = 0 })
        .min_h(.{ .px = 0 })
        .background(c.document)
        .overflow_hidden()
        .flex_col()
        .children(content.items)
        .build();
    var panes: std.ArrayList(ui.Element) = .empty;
    try panes.appendSlice(b.allocator(), &.{ rail, try b.fluent().div()
        .w(.{ .px = 1 })
        .shrink_0()
        .background(c.line)
        .children(.{})
        .build(), chat });
    if (wide and self.agent_editor) {
        const width = @max(320, b.viewport().width * 0.44);
        try panes.append(b.allocator(), try b.fluent().div()
            .w(.{ .px = 1 })
            .shrink_0()
            .background(c.line)
            .children(.{})
            .build());
        try panes.append(b.allocator(), try b.fluent().div()
            .w(.{ .px = width })
            .shrink_0()
            .min_w(.{ .px = 0 })
            .overflow_hidden()
            .flex_col()
            .children(&.{
                try b.fluent().div()
                    .h(.{ .px = 42 })
                    .items_center()
                    .padding(.{ .left = 10, .right = 10 })
                    .gap_px(6)
                    .shrink_0()
                    .flex()
                    .children(.{
                        v.actionButton(b, c, .back_to_editor, "Editor", false),
                        v.actionButton(b, c, .git_diff_all, "Review changes", false),
                        v.actionButton(b, c, .quick_open, "Open file", false),
                    }).build(),
                try view_module.editorArea(self, b, width),
            }).build());
    }
    var layers: std.ArrayList(ui.Element) = .empty;
    try layers.append(b.allocator(), try b.fluent().div()
        .grow()
        .min_h(.{ .px = 0 })
        .overflow_hidden()
        .flex()
        .children(panes.items)
        .build());
    if (self.agents.picker != .none) {
        var choices: std.ArrayList(ui.Element) = .empty;
        const query = try field_input.text(b, self.agents.query.?);
        const indices = try candidates(self, b.allocator(), query);
        try choices.append(b.allocator(), try b.fluent().view(self.agents.query.?)
            .autofocus()
            .style(.{ .height = .{ .px = 34 }, .flex_shrink = 0 })
            .build());
        const selected = @min(self.agents.picker_index, indices.len -| 1);
        const start = selected -| 5;
        for (indices[start..@min(indices.len, start + 10)], start..) |index, position| {
            const label = choiceLabel(self, index);
            var style = v.buttonStyle(c, false);
            style.background = if (position == selected) c.selected else null;
            style.justify_content = .start;
            style.overflow = .hidden;
            try choices.append(b.allocator(), try b.fluent().button(.{
                .label = label,
            }).style(style).on_click(b.onClickWith(choose, @as(u32, @intCast(index)))).build());
        }
        if (indices.len == 0) try choices.append(b.allocator(), try v.text(b, "No options. Connect an agent to load its models.", c.muted, 12));
        try choices.append(b.allocator(), try v.text(b, try std.fmt.allocPrint(b.allocator(), "{d} choices · ↑ ↓ navigate · Enter select · Esc close", .{indices.len}), c.muted, 10));
        const height = @min(@max(120, b.viewport().height - 160), @as(f32, @floatFromInt(choices.items.len)) * 34 + 12);
        const rect = v.popoverBounds(b.viewport(), .{ .x = rail_width + 8, .y = 34, .width = 320, .height = 42 }, .{ .width = 380, .height = height });
        const popup = try b.fluent().adopt(try v.floatingPanel(b, c, .{ .width = rect.width, .height = rect.height }, ui.Insets.all(6), 6, choices.items))
            .id(.{ .string = "agent-picker" })
            .build();
        try layers.append(b.allocator(), try b.fluent().div()
            .padding(.{ .left = rect.x, .top = rect.y - 34 })
            .stack()
            .children(.{popup})
            .listeners(.{ .on_capture = b.onInput(onPicker) })
            .modal()
            .build());
    }
    return b.fluent().div()
        .grow()
        .min_h(.{ .px = 0 })
        .overflow_hidden()
        .stack()
        .children(layers.items)
        .id(.{ .string = "agent-workspace" })
        .build();
}

fn pickerButton(b: *ui.Ui, c: v.Palette, label: []const u8, which: service.Picker) !ui.Element {
    return b.fluent().button(.{
        .label = label,
    })
        .flex()
        .gap_px(5)
        .h(.{ .px = 28 })
        .items_center()
        .padding(.{ .left = 7, .right = 7 })
        .rounded_px(v.metrics.control_radius)
        .hover_background(c.hover)
        .min_w(.{ .px = 0 })
        .overflow_hidden()
        .on_click(b.onClickWith(togglePicker, which))
        .children(&.{
            try v.text(b, label, c.text, 12),
            try v.icon(b, .chevron_down, c.muted, 10),
        }).build();
}

fn togglePicker(self: *Shell, _: *ui.Event(ui.Click), cx: *ui.Context(Shell), which: service.Picker) !void {
    if (self.agents.query == null) {
        var query = try ui.controls.TextInput.init(self.allocator, "");
        errdefer query.deinit(self.allocator);
        query.placeholder = "Search providers or models…";
        query.leading_icon = .search;
        query.show_focus_border = false;
        self.agents.query = try cx.createChild(ui.controls.TextInput, query);
    }
    self.agents.picker = if (self.agents.picker == which) .none else which;
    self.agents.picker_index = 0;
    const Reset = struct {
        fn call(input: *ui.controls.TextInput, context: *ui.Context(ui.controls.TextInput)) void {
            input.bytes.clearRetainingCapacity();
            input.cursor = 0;
            input.anchor = 0;
            input.marked = null;
            input.revision +%= 1;
            context.notify();
        }
    };
    try cx.update(self.agents.query.?, Reset.call, .{});
    cx.notify();
}

fn selectProvider(self: *Shell, _: *ui.Event(ui.Click), cx: *ui.Context(Shell), index: u32) !void {
    if (index >= self.agents.config.?.value.providers.len) return;
    self.agents.provider = index;
    self.agents.picker = .none;
    try service.newSession(self);
    cx.notify();
}

fn selectSession(self: *Shell, _: *ui.Event(ui.Click), cx: *ui.Context(Shell), index: u32) !void {
    try service.selectSession(self, index);
    cx.notify();
}

fn answer(self: *Shell, _: *ui.Event(ui.Click), cx: *ui.Context(Shell), index: u32) !void {
    const s = self.agents.current() orelse return;
    if (s.conversation.permission) |permission| {
        const params = agent.field(permission.value, "params") orelse .null;
        if (s.conversation.protocol == .acp) {
            const options = agent.field(params, "options") orelse return;
            if (options != .array or index >= options.array.items.len) return;
            try s.conversation.answer(agent.string(agent.field(options.array.items[index], "optionId")));
        } else try s.conversation.answer(if (index == 0) "accept" else "decline");
    }
    cx.notify();
}

fn onComposer(self: *Shell, e: *ui.Event(ui.Input), cx: *ui.Context(Shell)) !void {
    if (e.data == .key_down and e.data.key_down.key == .enter and !e.data.key_down.modifiers.shift) {
        e.preventDefault();
        e.stopPropagation();
        service.send(self, cx) catch |err| try self.reportError(err);
        return;
    }
    if (e.data == .key_down and e.data.key_down.key == .escape and self.agents.picker != .none) {
        self.agents.picker = .none;
        e.preventDefault();
        cx.notify();
        return;
    }
    const compose = &self.agents.composer.?;
    var outcome = try compose.editor.handle(&compose.document, e);
    if (outcome.change) |*change| change.deinit();
    if (outcome.handled) cx.notify();
}

fn onTranscript(self: *Shell, e: *ui.Event(ui.Input), cx: *ui.Context(Shell)) !void {
    const s = self.agents.current() orelse return;
    const outcome = try s.preview.handle(e);
    if (e.data == .scroll) s.follow = false;
    if (outcome.handled) cx.notify();
}

fn scrollSessions(self: *Shell, e: *ui.Event(ui.Input), cx: *ui.Context(Shell)) void {
    if (e.data == .scroll) {
        self.agents.session_scroll.wheel(e.data.scroll.y, @as(f32, @floatFromInt(self.agents.sessions.items.len)) * 52, @max(0, e.bounds.height - 120));
        e.preventDefault();
        cx.notify();
    }
}

pub fn attach(self: *Shell, cx: *ui.Context(Shell)) !void {
    try service.ensure(self);
    const active = try actions.active(self);
    const record = try self.workspace.getConst(active.id);
    var snapshot = record.doc.snapshot();
    defer snapshot.deinit();
    const selected = active.editor.primary().range();
    const range = if (selected.start < selected.end) selected else text.Range{ .start = 0, .end = snapshot.byteLen() };
    if (range.end - range.start > 128 * 1024) return error.AgentContextTooLarge;
    const bytes = try snapshot.copy(self.allocator, range);
    defer self.allocator.free(bytes);
    const context = try std.fmt.allocPrint(self.allocator, "\n\nFile: {s}\n```\n{s}\n```\n", .{ record.path orelse record.title(), bytes });
    defer self.allocator.free(context);
    const compose = &self.agents.composer.?;
    var result = try compose.editor.execute(&compose.document, .{ .insert = context });
    if (result.change) |*change| change.deinit();
    self.agents.focus +%= 1;
    cx.notify();
}

fn choiceLabel(self: *const Shell, index: usize) []const u8 {
    if (self.agents.picker == .providers) return self.agents.config.?.value.providers[index].name;
    const model = choiceModels(self)[index];
    return if (model.name.len > 0) model.name else model.id;
}

fn choiceModels(self: *const Shell) []const agent.Model {
    const s = self.agents.current() orelse return &.{};
    return switch (self.agents.picker) {
        .models => s.conversation.models.items,
        .modes => s.conversation.modes.items,
        .efforts => s.conversation.efforts.items,
        else => &.{},
    };
}

fn candidates(self: *const Shell, a: std.mem.Allocator, query: []const u8) ![]usize {
    var items: std.ArrayList(usize) = .empty;
    const count = if (self.agents.picker == .providers and self.agents.config != null) self.agents.config.?.value.providers.len else choiceModels(self).len;
    for (0..count) |i| if (overlays.matches(query, choiceLabel(self, i))) try items.append(a, i);
    return items.toOwnedSlice(a);
}

fn choose(self: *Shell, e: *ui.Event(ui.Click), cx: *ui.Context(Shell), index: u32) !void {
    if (self.agents.picker == .providers) return selectProvider(self, e, cx, index);
    const s = self.agents.current() orelse return;
    const models = choiceModels(self);
    if (index >= models.len) return;
    switch (self.agents.picker) {
        .models => try s.conversation.chooseModel(models[index].id),
        .modes => try s.conversation.chooseMode(models[index].id),
        .efforts => try s.conversation.chooseEffort(models[index].id),
        else => {},
    }
    self.agents.picker = .none;
    self.agents.focus +%= 1;
    cx.notify();
}

fn onPicker(self: *Shell, e: *ui.Event(ui.Input), cx: *ui.Context(Shell)) !void {
    if (e.data == .key_down) {
        const key = e.data.key_down.key;
        if (key == .escape) {
            self.agents.picker = .none;
            e.preventDefault();
            e.stopPropagation();
            cx.notify();
            return;
        }
        if (key == .up or key == .down or key == .enter) {
            var query: []u8 = undefined;
            try cx.read(self.agents.query.?, ui.controls.TextInput.copy, .{ self.allocator, &query });
            defer self.allocator.free(query);
            const indices = try candidates(self, self.allocator, query);
            defer self.allocator.free(indices);
            if (indices.len > 0) {
                self.agents.picker_index = @min(self.agents.picker_index, indices.len - 1);
                if (key == .enter) {
                    var click_event: ui.Event(ui.Click) = .{ .data = .{} };
                    try choose(self, &click_event, cx, @intCast(indices[self.agents.picker_index]));
                } else self.agents.picker_index = if (key == .down) @min(indices.len - 1, self.agents.picker_index + 1) else self.agents.picker_index -| 1;
            }
            e.preventDefault();
            e.stopPropagation();
            cx.notify();
            return;
        }
        self.agents.picker_index = 0;
    } else if (e.data == .pointer_down) {
        const frame = &(try cx.app.window(self.window.?)).frames.committed;
        for (frame.nodes.items, 0..) |node, index| if (node.key) |key| if (key == .string and std.mem.eql(u8, key.string, "agent-picker")) {
            const r = frame.bounds[index];
            const p = e.data.pointer_down.position;
            if (p.x < r.x or p.y < r.y or p.x >= r.x + r.width or p.y >= r.y + r.height) {
                self.agents.picker = .none;
                e.preventDefault();
                e.stopPropagation();
                cx.notify();
            }
            break;
        };
    } else if (e.data == .text or e.data == .edit) self.agents.picker_index = 0;
}

fn lastResponse(session: *const service.Session) []const u8 {
    var i = session.conversation.entries.items.len;
    while (i > 0) {
        i -= 1;
        const entry = session.conversation.entries.items[i];
        if (entry.role == .assistant) return entry.text.items;
    }
    return "";
}

fn copyResponse(self: *Shell, e: *ui.Event(ui.Click), _: *ui.Context(Shell)) !void {
    const session = self.agents.current() orelse return;
    try e.writeClipboard(lastResponse(session));
}
