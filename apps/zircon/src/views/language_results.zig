//! Language locations and actions have a tab separate from project search.
const std = @import("std");
const lsp = @import("zircon_language");
const ui = @import("zircon_ui");
const language = @import("../services/language.zig");
const shell = @import("../shell.zig");
const v = @import("components.zig");
const Shell = shell.Shell;
const row_height: f32 = 36;
const Target = struct { pane: u8, index: u32, request: u64 };

fn count(self: *const Shell) usize {
    return switch (self.language.results_kind) {
        .code_actions => if (self.language.code_actions) |message| message.data.code_actions.items.len else 0,
        .references => if (self.language.references) |message| message.data.locations.items.len else 0,
    };
}

pub fn render(self: *const Shell, b: *ui.Ui, pane: u8) !ui.Element {
    const c = self.colors;
    const actions = self.language.results_kind == .code_actions;
    const total = count(self);
    const title = try std.fmt.allocPrint(b.allocator(), "{d} {s}", .{ total, if (actions) "code actions" else "references" });
    const viewport = self.language.results_viewport[pane] orelse @max(1, b.viewport().height - v.metrics.titlebar - v.metrics.tabs - v.metrics.status - 49);
    const visible = try ui.controls.visibleRows(total, row_height, self.language.results_scroll[pane].offset, viewport, 2);
    var rows: std.ArrayList(ui.Element) = .empty;
    for (visible.start..visible.end) |index| {
        const label, const unavailable, const request = if (actions) blk: {
            const message = self.language.code_actions.?.data.code_actions;
            const action = message.items[index];
            break :blk .{ action.title, action.disabled_reason, message.id };
        } else blk: {
            const message = self.language.references.?.data.locations;
            const location = message.items[index];
            const absolute = lsp.filePath(b.allocator(), location.uri) catch location.uri;
            const root = self.workspace.root_path;
            const path = if (absolute.len > root.len and std.mem.startsWith(u8, absolute, root) and absolute[root.len] == '/') absolute[root.len + 1 ..] else absolute;
            break :blk .{ try std.fmt.allocPrint(b.allocator(), "{s}:{d}:{d}", .{ path, location.range.start.line + 1, location.range.start.character + 1 }), @as(?[]const u8, null), message.id };
        };
        try rows.append(b.allocator(), try b.fluent().button(.{ .label = label, .tooltip = unavailable orelse label, .tooltip_colors = .{ c.panel, c.text, c.line } })
            .h(.{ .px = row_height })
            .shrink_0()
            .padding(.{ .left = 14, .right = 10 })
            .items_center()
            .overflow_hidden()
            .hover_background(c.hover)
            .opacity(if (unavailable != null) 0.6 else 1)
            .on_click(if (unavailable != null) null else try b.onClickWith(open, Target{ .pane = pane, .index = @intCast(index), .request = request }))
            .children(.{v.text(b, label, c.text, 12)})
            .id(.{ .number = @intCast(index) })
            .build());
    }
    if (total == 0) try rows.append(b.allocator(), try b.fluent().div()
        .padding(ui.Insets.all(20))
        .children(.{v.text(b, "No results found.", c.muted, 13)})
        .build());
    return b.fluent().div()
        .grow()
        .min_h(.{ .px = 0 })
        .background(c.document)
        .overflow_hidden()
        .flex_col()
        .children(.{
            b.fluent().div()
                .h(.{ .px = 48 })
                .shrink_0()
                .padding(.{ .left = 14 })
                .items_center()
                .flex()
                .children(.{v.text(b, title, c.text, 14)}),
            v.rule(b, c),
            b.fluent().div()
                .grow()
                .min_h(.{ .px = 0 })
                .flex_col()
                .overflow_hidden()
                .scroll_y_px(@max(0, -visible.top))
                .padding(.{ .top = @max(0, visible.top) })
                .children(rows.items)
                .id(.{ .string = "language-results-list" })
                .listeners(.{ .on_input = b.onInputWith(onScroll, pane) }),
        })
        .id(.{ .string = "language-results-panel" })
        .build();
}

fn onScroll(self: *Shell, e: *ui.Event(ui.Input), cx: *ui.Context(Shell), pane: u8) void {
    if (e.data != .scroll) return;
    self.language.results_viewport[pane] = e.bounds.height;
    self.language.results_scroll[pane].wheel(e.data.scroll.y, @as(f32, @floatFromInt(count(self))) * row_height, e.bounds.height);
    e.preventDefault();
    cx.notify();
}

fn open(self: *Shell, _: *ui.Event(ui.Click), cx: *ui.Context(Shell), target: Target) !void {
    self.active_pane = if (target.pane == 1 and self.secondary != null) .secondary else .primary;
    if (self.language.results_kind == .code_actions) {
        const message = self.language.code_actions orelse return;
        if (message.data.code_actions.id != target.request) return;
        language.applyCodeAction(self, cx, target.index) catch |err| try self.reportError(err);
    } else {
        const message = self.language.references orelse return;
        if (message.data.locations.id != target.request) return;
        language.acceptReference(self, cx, target.index) catch |err| try self.reportError(err);
    }
    cx.notify();
}
