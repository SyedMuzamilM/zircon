//! Project diagnostics, grouped by source and virtualized independently of editors.
const std = @import("std");
const editor = @import("zircon_editor");
const lsp = @import("zircon_language");
const zircon_text = @import("zircon_text");
const ui = @import("zircon_ui");
const ws = @import("zircon_workspace");
const actions = @import("../actions.zig");
const language = @import("../services/language.zig");
const shell = @import("../shell.zig");
const v = @import("components.zig");
const Shell = shell.Shell;
const header_height: f32 = 36;

pub const Filter = enum { all, errors, warnings };
pub const Model = struct { filter: Filter = .all, scroll: [2]ui.controls.Scroll = @splat(.{}), viewport: [2]?f32 = @splat(null) };
const Target = struct { document: ws.DocumentId, session: usize, revision: u64, index: u32, generation: u64, pane: u8 };
const Issue = struct { diagnostic: lsp.Diagnostic, target: Target, first: usize, last: usize };
const Row = union(enum) {
    file: struct { path: []const u8, target: Target },
    issue: Issue,

    fn height(self: Row, line_height: f32) f32 {
        return switch (self) {
            .file => header_height,
            .issue => |issue| @as(f32, @floatFromInt(issue.last - issue.first + 1)) * line_height + 32,
        };
    }
};

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
        var snapshot = record.doc.snapshot();
        defer snapshot.deinit();
        for (message.data.diagnostics.items, 0..) |issue, index| {
            if (!matches(self.diagnostics.filter, issue)) continue;
            const target: Target = .{
                .document = doc.id,
                .session = doc.session,
                .revision = record.doc.revision(),
                .index = @intCast(index),
                .generation = self.language.diagnostics_generation,
                .pane = pane,
            };
            if (!grouped) {
                try result.append(a, .{ .file = .{ .path = doc.path, .target = target } });
                grouped = true;
            }
            const line = @min(issue.range.start.line, snapshot.lineCount() - 1);
            try result.append(a, .{ .issue = .{ .diagnostic = issue, .target = target, .first = line -| 1, .last = @min(snapshot.lineCount() - 1, line + 1) } });
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
    const line_height = self.editor_options.font_size * self.editor_options.line_height;
    var total: f32 = 0;
    for (issues) |row| total += row.height(line_height);
    const top = std.math.clamp(self.diagnostics.scroll[pane].offset, 0, @max(0, total - viewport));
    const bottom = top + viewport;
    var elements: std.ArrayList(ui.Element) = .empty;
    var y: f32 = 0;
    var first: ?f32 = null;
    for (issues, 0..) |row, index| {
        const height = row.height(line_height);
        defer y += height;
        if (y + height <= top) continue;
        if (y >= bottom) break;
        if (first == null) first = y;
        const element = switch (row) {
            .file => |file| blk: {
                const root = self.workspace.root_path;
                const absolute = file.path;
                const path = if (absolute.len > root.len and std.mem.startsWith(u8, absolute, root) and absolute[root.len] == '/') absolute[root.len + 1 ..] else absolute;
                break :blk try b.fluent().button(.{ .label = path })
                    .h_px(header_height).shrink_0()
                    .padding(.{ .left = 14, .right = 14 }).items_center().gap_px(8).flex()
                    .background(c.panel).hover_background(c.hover).overflow_hidden()
                    .on_click(b.onClickWith(openIssue, file.target))
                    .children(.{
                        v.fileGlyph(self, b, path, false, false, 16),
                        v.text(b, path, c.text, 13),
                        v.text(b, "Open File", c.muted, 11),
                    })
                    .build();
            },
            .issue => |issue| try issueExcerpt(self, b, issue, height, line_height),
        };
        try elements.append(b.allocator(), try b.fluent().adopt(element).id(.{ .number = @intCast(index) }).build());
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
                .scroll_y_px(if (first) |origin| @max(0, top - origin) else 0)
                .children(elements.items)
                .id(.{ .string = "diagnostics-list" })
                .listeners(.{ .on_input = b.onInputWith(onScroll, pane) }),
        })
        .id(.{ .string = "diagnostics-panel" })
        .build();
}

fn issueExcerpt(self: *const Shell, b: *ui.Ui, issue: Issue, height: f32, line_height: f32) !ui.Element {
    const c = self.colors;
    const font = self.editor_options.font_size;
    const diagnostic = issue.diagnostic;
    const color = switch (diagnostic.severity) {
        .error_value => c.deleted,
        .warning => c.warning,
        else => c.muted,
    };
    const record = try self.workspace.getConst(issue.target.document);
    var snapshot = record.doc.snapshot();
    defer snapshot.deinit();
    const gutter = if (self.editor_options.line_numbers) editor.gutterWidth(snapshot.lineCount(), font) else 20;
    var lines: std.ArrayList(ui.Element) = .empty;
    for (issue.first..issue.last + 1) |row| {
        const range = try snapshot.lineRange(row);
        const bytes = if (range.end - range.start <= 65536) try snapshot.copy(b.allocator(), range) else "[Line exceeds the display limit]";
        var highlight: [1]editor.code_line.Highlight = undefined;
        var marks: []const editor.code_line.Highlight = &.{};
        var underline: ?editor.element.Mark = null;
        if (row == diagnostic.range.start.line) {
            const start = lsp.offsetAt(snapshot, diagnostic.range.start) catch range.start;
            const end = lsp.offsetAt(snapshot, diagnostic.range.end) catch range.end;
            var tint = color;
            tint.a = 0.16;
            const local_start = start -| range.start;
            const local_end = @min(range.end, end) -| range.start;
            highlight[0] = .{ .start = local_start, .end = local_end, .color = tint };
            marks = &highlight;
            underline = .{ .range = .{ .start = local_start, .end = local_end }, .severity = language.severityOf(diagnostic.severity), .message = diagnostic.message, .source = diagnostic.source orelse "" };
        }
        const code = try editor.code_line.element(b, bytes, record.path orelse "", font, line_height, self.editor_options.theme, marks, .{
            .tab_width = self.editor_options.tab_width,
            .indent_guides = self.editor_options.indent_guides,
            .indent_cells = if (editor.indent_guides.blank(bytes)) try editor.indent_guides.blankCells(snapshot, row, self.editor_options.tab_width, b.allocator()) else null,
            .underline = underline,
        });
        const number = if (self.editor_options.line_numbers) try std.fmt.allocPrint(b.allocator(), "{d}", .{row + 1}) else "";
        try lines.append(b.allocator(), try b.fluent().row().h_px(line_height).shrink_0().children(.{
            b.fluent().row().w_px(gutter).shrink_0().items_center().justify(.end).padding(.{ .right = if (self.editor_options.line_numbers) 36 else 0 }).child(
                b.fluent().text(number).text_style(.{
                    .size = font - 1,
                    .mono = true,
                    .color = self.editor_options.theme.line_number,
                }),
            ),
            code,
        }).build());
        if (row == diagnostic.range.start.line) {
            const message = try std.fmt.allocPrint(b.allocator(), "{s}{s}{s}", .{ diagnostic.message, if (diagnostic.source != null) " · " else "", diagnostic.source orelse "" });
            try lines.append(b.allocator(), try b.fluent().row().h_px(24).shrink_0().padding(.{ .left = gutter, .right = 12 }).items_center().overflow_hidden().children(.{
                b.fluent().div().w_px(2).h_px(18).shrink_0().background(color),
                b.fluent().adopt(try v.text(b, message, color, 12)).padding(.{ .left = 8 }),
            }).build());
        }
    }
    return b.fluent().button(.{
        .label = diagnostic.message,
        .tooltip = diagnostic.message,
        .tooltip_colors = .{ c.panel, c.text, c.line },
    })
        .h_px(height).shrink_0().padding(.{ .top = 4, .bottom = 4 }).flex_col().overflow_hidden().cursor(.pointing_hand)
        .on_click(b.onClickWith(openIssue, issue.target)).children(lines.items).build();
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
    var total: f32 = 0;
    for (current) |row| total += row.height(self.editor_options.font_size * self.editor_options.line_height);
    self.diagnostics.scroll[pane].wheel(e.data.scroll.y, total, e.bounds.height);
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
