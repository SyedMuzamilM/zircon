//! Project diagnostics, grouped by source and virtualized independently of editors.
const std = @import("std");
const lsp = @import("zircon_language");
const zircon_text = @import("zircon_text");
const ui = @import("zircon_ui");
const ws = @import("zircon_workspace");
const actions = @import("../actions.zig");
const shell = @import("../shell.zig");
const v = @import("components.zig");
const Shell = shell.Shell;
const row_height: f32 = 48;

pub const Filter = enum { all, errors, warnings };
pub const Model = struct { filter: Filter = .all, scroll: [2]ui.controls.Scroll = @splat(.{}), viewport: [2]?f32 = @splat(null) };
const Target = struct { document: ws.DocumentId, session: usize, revision: u64, index: u32, generation: u64, pane: u8 };
const Row = union(enum) { file: []const u8, issue: struct { diagnostic: lsp.Diagnostic, target: Target } };

fn matches(filter: Filter, diagnostic: lsp.Diagnostic) bool {
    return switch (filter) {
        .all => true,
        .errors => diagnostic.severity == .error_value,
        .warnings => diagnostic.severity == .warning,
    };
}

pub fn count(self: *const Shell, filter: Filter) usize {
    var total: usize = 0;
    for (self.language.documents.items) |doc| {
        const record = self.workspace.getConst(doc.id) catch continue;
        const message = doc.diagnostics orelse continue;
        if (message.data.diagnostics.version != record.doc.revision()) continue;
        for (message.data.diagnostics.items) |issue| if (matches(filter, issue)) {
            total += 1;
        };
    }
    return total;
}

fn rows(self: *const Shell, a: std.mem.Allocator, pane: u8) ![]Row {
    var result: std.ArrayList(Row) = .empty;
    errdefer result.deinit(a);
    for (self.language.documents.items) |doc| {
        const record = self.workspace.getConst(doc.id) catch continue;
        const message = doc.diagnostics orelse continue;
        if (message.data.diagnostics.version != record.doc.revision()) continue;
        var grouped = false;
        for (message.data.diagnostics.items, 0..) |issue, index| {
            if (!matches(self.diagnostics.filter, issue)) continue;
            if (!grouped) {
                try result.append(a, .{ .file = doc.path });
                grouped = true;
            }
            try result.append(a, .{ .issue = .{ .diagnostic = issue, .target = .{
                .document = doc.id,
                .session = doc.session,
                .revision = record.doc.revision(),
                .index = @intCast(index),
                .generation = self.language.diagnostics_generation,
                .pane = pane,
            } } });
        }
    }
    return result.toOwnedSlice(a);
}

pub fn render(self: *const Shell, b: *ui.Ui, pane: u8) !ui.Element {
    const c = self.colors;
    var filters: std.ArrayList(ui.Element) = .empty;
    inline for (std.meta.tags(Filter)) |filter| {
        const name = switch (filter) {
            .all => "All issues",
            .errors => "Errors",
            .warnings => "Warnings",
        };
        const label = try std.fmt.allocPrint(b.allocator(), "{s} ({d})", .{ name, count(self, filter) });
        try filters.append(b.allocator(), try b.fluent().button(.{ .label = label })
            .h(.{ .px = 28 })
            .padding(.{ .left = 10, .right = 10 })
            .items_center()
            .rounded_px(v.metrics.control_radius)
            .background(if (self.diagnostics.filter == filter) c.selected else null)
            .hover_background(c.hover)
            .on_click(b.onClickWith(setFilter, filter))
            .children(.{v.text(b, label, c.text, 12)})
            .build());
    }
    const issues = try rows(self, b.allocator(), pane);
    const viewport = self.diagnostics.viewport[pane] orelse @max(1, b.viewport().height - v.metrics.titlebar - v.metrics.tabs - v.metrics.status - 57);
    const visible = try ui.controls.visibleRows(issues.len, row_height, self.diagnostics.scroll[pane].offset, viewport, 2);
    var elements: std.ArrayList(ui.Element) = .empty;
    for (issues[visible.start..visible.end], visible.start..) |row, index| {
        const element = switch (row) {
            .file => |absolute| blk: {
                const root = self.workspace.root_path;
                const path = if (absolute.len > root.len and std.mem.startsWith(u8, absolute, root) and absolute[root.len] == '/') absolute[root.len + 1 ..] else absolute;
                break :blk try b.fluent().div()
                    .h(.{ .px = row_height })
                    .shrink_0()
                    .padding(.{ .left = 14, .right = 14 })
                    .items_center()
                    .gap_px(8)
                    .flex()
                    .background(c.panel)
                    .overflow_hidden()
                    .children(.{ v.fileGlyph(self, b, path, false, false, 16), v.text(b, path, c.text, 13) })
                    .build();
            },
            .issue => |issue| blk: {
                const diagnostic = issue.diagnostic;
                const severity = switch (diagnostic.severity) {
                    .error_value => "Error",
                    .warning => "Warning",
                    .information => "Information",
                    .hint => "Hint",
                };
                const color = switch (diagnostic.severity) {
                    .error_value => c.deleted,
                    .warning => c.warning,
                    else => c.muted,
                };
                const location = try std.fmt.allocPrint(b.allocator(), "{s} · {d}:{d}{s}{s}", .{ severity, diagnostic.range.start.line + 1, diagnostic.range.start.character + 1, if (diagnostic.source != null) " · " else "", diagnostic.source orelse "" });
                break :blk try b.fluent().button(.{ .label = diagnostic.message, .tooltip = diagnostic.message, .tooltip_colors = .{ c.panel, c.text, c.line } })
                    .h(.{ .px = row_height })
                    .shrink_0()
                    .padding(.{ .left = 26, .right = 14, .top = 5 })
                    .gap_px(3)
                    .flex_col()
                    .overflow_hidden()
                    .hover_background(c.hover)
                    .on_click(b.onClickWith(openIssue, issue.target))
                    .children(.{ v.text(b, diagnostic.message, c.text, 12), v.text(b, location, color, 11) })
                    .build();
            },
        };
        try elements.append(b.allocator(), try b.fluent().adopt(element)
            .id(.{ .number = @intCast(index) })
            .build());
    }
    if (issues.len == 0) try elements.append(b.allocator(), try b.fluent().div()
        .padding(ui.Insets.all(20))
        .flex_col()
        .gap_px(8)
        .children(.{
            v.text(b, "No current issues", c.text, 14),
            v.text(b, "Diagnostics appear for files opened by an enabled language server.", c.muted, 12),
        })
        .build());
    return b.fluent().div()
        .grow()
        .min_h(.{ .px = 0 })
        .background(c.document)
        .flex_col()
        .overflow_hidden()
        .children(.{
            b.fluent().div()
                .h(.{ .px = 56 })
                .shrink_0()
                .padding(.{ .left = 14 })
                .items_center()
                .gap_px(6)
                .flex()
                .children(filters.items),
            v.rule(b, c),
            b.fluent().div()
                .grow()
                .min_h(.{ .px = 0 })
                .flex_col()
                .overflow_hidden()
                .scroll_y_px(@max(0, -visible.top))
                .padding(.{ .top = @max(0, visible.top) })
                .children(elements.items)
                .id(.{ .string = "diagnostics-list" })
                .listeners(.{ .on_input = b.onInputWith(onScroll, pane) }),
        })
        .id(.{ .string = "diagnostics-panel" })
        .build();
}

fn setFilter(self: *Shell, _: *ui.Event(ui.Click), cx: *ui.Context(Shell), filter: Filter) void {
    self.diagnostics.filter = filter;
    self.diagnostics.scroll = @splat(.{});
    cx.notify();
}

fn onScroll(self: *Shell, e: *ui.Event(ui.Input), cx: *ui.Context(Shell), pane: u8) !void {
    if (e.data != .scroll) return;
    const current = try rows(self, self.allocator, pane);
    defer self.allocator.free(current);
    self.diagnostics.viewport[pane] = e.bounds.height;
    self.diagnostics.scroll[pane].wheel(e.data.scroll.y, @as(f32, @floatFromInt(current.len)) * row_height, e.bounds.height);
    e.preventDefault();
    cx.notify();
}

fn openIssue(self: *Shell, _: *ui.Event(ui.Click), cx: *ui.Context(Shell), target: Target) !void {
    open(self, cx, target) catch |err| try self.reportError(err);
    cx.notify();
}

fn open(self: *Shell, cx: *ui.Context(Shell), target: Target) !void {
    if (target.generation != self.language.diagnostics_generation) return error.StaleDiagnostics;
    const record = try self.workspace.getConst(target.document);
    if (record.doc.revision() != target.revision) return error.StaleDiagnostics;
    for (self.language.documents.items) |doc| {
        if (!std.meta.eql(doc.id, target.document) or doc.session != target.session) continue;
        const message = doc.diagnostics orelse return error.StaleDiagnostics;
        if (message.data.diagnostics.version != target.revision or target.index >= message.data.diagnostics.items.len) return error.StaleDiagnostics;
        const range = message.data.diagnostics.items[target.index].range;
        var snapshot = record.doc.snapshot();
        defer snapshot.deinit();
        const selection: zircon_text.Range = .{ .start = try lsp.offsetAt(snapshot, range.start), .end = try lsp.offsetAt(snapshot, range.end) };
        self.active_pane = if (target.pane == 1 and self.secondary != null) .secondary else .primary;
        try actions.openPath(self, doc.path);
        if (self.active_pane == .secondary) self.secondary_tool = null else self.panel = .editor;
        const current = try actions.active(self);
        try current.editor.setSelection(snapshot, selection);
        current.editor.reveal(snapshot);
        self.editor_focus_request +%= 1;
        cx.notify();
        return;
    }
    return error.StaleDiagnostics;
}
