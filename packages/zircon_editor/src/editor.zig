//! Persistent editor presentation state. The document is supplied for each
//! operation, so split views share bytes/history while keeping selections/scroll.
const std = @import("std");
const text = @import("zircon_text");
const ui = @import("zircon_ui");
const annotations = @import("annotations.zig");
const brackets = @import("brackets.zig");
const canvas = @import("canvas.zig");
const commands = @import("commands.zig");
const comments = @import("comments.zig");
const input = @import("input.zig");
const navigation = @import("navigation.zig");
const pairing = @import("pairing.zig");
const profile_module = @import("profile.zig");
const selection = @import("selections.zig");
const syntax = @import("syntax.zig");
const theme_module = @import("theme.zig");
const vim_module = @import("vim.zig");
const vim_repeat = @import("vim_repeat.zig");
const wrap = @import("wrap.zig");
pub const Outcome = struct { request_find: bool = false, request_project_search: bool = false, handled: bool = false, change: ?text.Change = null, reset: bool = false, history_reset: ?struct { before: u64, action: enum { undo, redo } } = null };
const SelectionHistory = struct { state: u64, items: []selection.Selection };
var next_group = std.atomic.Value(u64).init(1);
pub const Editor = struct {
    allocator: std.mem.Allocator,
    vim: vim_module.State = .{},
    selections: selection.Set,
    pairs: pairing.State = .{},
    bracket_cache: *brackets.Cache,
    /// Optional source range exposed by an excerpt view. Edits cannot consume
    /// bytes outside it; insertion at either endpoint remains valid.
    edit_scope: ?text.Range = null,
    scroll: ui.controls.Scroll = .{},
    horizontal: f32 = 0,
    soft_wrap: wrap.Mode = .none,
    wrap_cache: *wrap.Cache,
    preferred_x: ?f32 = null,
    theme: theme_module.Theme = .{},
    git_changes: []annotations.GitChange = &.{},
    git_revision: u64 = 0,
    git_baseline: []u8 = &.{},
    blame_hovered: bool = false,
    blame_bounds: ui.Rect = .{},
    blame_pinned: bool = false,
    blame_message_scroll: f32 = 0,
    show_git_gutters: bool = true,
    inline_blame: ?annotations.Blame = null,
    show_line_numbers: bool = true,
    gutter_hovered: bool = false,
    show_indent_guides: bool = true,
    highlight_active_line: bool = true,
    show_fold_controls: bool = true,
    show_scrollbars: bool = true,
    font_size: f32 = 14,
    line_height: f32 = 22,
    tab_width: usize = 4,
    language: syntax.Language = .plain,
    language_id: ?[]const u8 = null,
    language_profile: ?profile_module.Profile = null,
    syntax_cache: syntax.Cache,
    grammar_spans: []syntax.Span = &.{},
    grammar_revision: ?u64 = null,
    history: std.ArrayList(SelectionHistory) = .empty,
    typing_group: u64 = 0,
    composition_group: u64 = 0,
    composition_changed: bool = false,
    marked: ?text.Range = null,
    dragging: bool = false,
    last_viewport: ui.Size = .{ .width = 800, .height = 500 },
    search_ranges: []text.Range = &.{},
    search_revision: ?u64 = null,
    search_visible: bool = false,
    search_query: []u8 = &.{},
    search_case_sensitive: bool = true,
    pub fn init(a: std.mem.Allocator) !Editor {
        var selections = try selection.Set.init(a);
        errdefer selections.deinit(a);
        const bracket_cache = try a.create(brackets.Cache);
        errdefer a.destroy(bracket_cache);
        bracket_cache.* = .{};
        return .{ .allocator = a, .bracket_cache = bracket_cache, .selections = selections, .syntax_cache = .init(a), .wrap_cache = try wrap.Cache.init(a) };
    }
    pub fn deinit(self: *Editor) void {
        self.allocator.free(self.grammar_spans);
        self.wrap_cache.release();
        self.vim.deinit(self.allocator);
        self.allocator.free(self.git_changes);
        self.allocator.free(self.git_baseline);
        if (self.inline_blame) |*blame| blame.deinit(self.allocator);
        self.selections.deinit(self.allocator);
        self.pairs.deinit(self.allocator);
        self.allocator.destroy(self.bracket_cache);
        self.syntax_cache.deinit();
        for (self.history.items) |entry| self.allocator.free(entry.items);
        self.history.deinit(self.allocator);
        self.allocator.free(self.search_ranges);
        self.allocator.free(self.search_query);
        self.* = undefined;
    }
    pub fn setHighlights(self: *Editor, snapshot: text.Snapshot, spans: []const syntax.Span) !void {
        if (spans.len > 1_000_000) return error.TooManyHighlights;
        var previous: usize = 0;
        for (spans) |span| {
            try snapshot.validateRange(.{ .start = span.start, .end = span.end });
            if (span.start < previous) return error.InvalidHighlights;
            previous = span.end;
        }
        const next = try self.allocator.dupe(syntax.Span, spans);
        self.allocator.free(self.grammar_spans);
        self.grammar_spans = next;
        self.grammar_revision = snapshot.revision();
    }
    pub fn setVim(self: *Editor, enabled: bool) void {
        vim_module.enable(self, enabled);
    }
    pub fn render(self: *const Editor, document: *const text.Document, builder: *ui.Ui) !ui.Element {
        try self.validate();
        return canvas.render(self, document, builder);
    }
    pub fn symbolAt(self: *Editor, snapshot: text.Snapshot, event: *ui.Event(ui.Input), point: ui.Point) !?text.Range {
        if (event._surface == null) return null;
        const gutter = if (self.show_line_numbers) canvas.gutterWidth(snapshot.lineCount(), self.font_size) else 20;
        if (point.x < event.bounds.x + gutter or point.x >= event.bounds.x + event.bounds.width - 12 or !annotations.contains(event.bounds, point)) return null;
        const at = try navigation.position(self, snapshot, event, point);
        if (at >= snapshot.byteLen()) return null;
        const byte = try snapshot.byteAt(at);
        if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte < 0x80) return null;
        return try navigation.wordRange(snapshot, at);
    }
    pub fn validate(self: *const Editor) !void {
        if (!std.math.isFinite(self.font_size) or self.font_size <= 0 or self.font_size > 128 or !std.math.isFinite(self.line_height) or self.line_height < self.font_size or !std.math.isFinite(self.scroll.offset) or self.scroll.offset < 0 or !std.math.isFinite(self.horizontal) or self.horizontal < 0 or self.tab_width == 0 or self.tab_width > 32) return error.InvalidEditorOptions;
    }
    pub fn synchronize(self: *Editor, snapshot: text.Snapshot) void {
        self.bracket_cache.revision = null;
        self.selections.synchronize(snapshot);
        vim_module.synchronize(self, snapshot);
        self.syntax_cache.profile = self.language_profile;
        if (self.language == .plain) self.syntax_cache.clear() else if (self.syntax_cache.revision != snapshot.revision() or self.syntax_cache.language != self.language) {
            self.syntax_cache.clear();
            self.syntax_cache.refresh(snapshot, self.language, 0) catch self.syntax_cache.clear();
        }
        if (self.marked) |range| if (range.end > snapshot.byteLen()) {
            self.marked = null;
            self.composition_group = 0;
        };
    }
    pub fn mapChange(self: *Editor, change: *const text.Change) void {
        self.pairs.map(change);
        self.mapHighlights(change);
        if (self.edit_scope) |*range| {
            range.start = change.map(range.start, .before);
            range.end = change.map(range.end, .after);
        }
        self.wrap_cache.noteChange(change);
        self.vim.recording.active = false;
        self.vim.cursor = change.map(self.vim.cursor, .after);
        self.vim.anchor = change.map(self.vim.anchor, .after);
        for (self.selections.items.items) |*item| {
            item.anchor = change.map(item.anchor, .after);
            item.head = change.map(item.head, .after);
        }
        self.selections.normalize();
        self.marked = null;
        self.typing_group = 0;
    }
    fn mapHighlights(self: *Editor, change: *const text.Change) void {
        if (self.grammar_revision != change.before) return;
        for (self.grammar_spans) |*span| {
            span.start = change.map(span.start, .after);
            span.end = @max(span.start, change.map(span.end, .before));
        }
        self.grammar_revision = change.after;
    }
    pub fn setBlame(self: *Editor, value: annotations.Blame) !void {
        const prepared = try value.copy(self.allocator);
        self.hideBlame();
        self.inline_blame = prepared;
    }
    pub fn hideBlame(self: *Editor) void {
        if (self.inline_blame) |*value| value.deinit(self.allocator);
        self.inline_blame = null;
    }
    pub fn projected(self: *const Editor) bool {
        return self.soft_wrap != .none or self.wrap_cache.folding.collapsed.items.len > 0;
    }
    pub fn projectionWidth(self: *const Editor, width: f32) f32 {
        return if (self.soft_wrap != .none) width else 1e12;
    }
    pub fn toggleFold(self: *Editor, snapshot: text.Snapshot, row: usize) !bool {
        try self.wrap_cache.folding.ensure(self.allocator, snapshot, self.tab_width);
        if (!try self.wrap_cache.folding.toggle(self.allocator, row)) return false;
        self.wrap_cache.revision = null;
        self.wrap_cache.pending = null;
        self.hideBlame();
        const region = self.wrap_cache.folding.region(row).?;
        if (self.wrap_cache.folding.isCollapsed(region.start)) {
            self.selections.single(.{ .anchor = region.start, .head = region.start });
            self.vim.cursor = region.start;
            for (self.git_changes) |*change| {
                if (change.start >= row and change.start <= region.last) change.expanded = false;
            }
        }
        return true;
    }
    pub fn rowAt(self: *const Editor, y: f32, revision: u64) usize {
        if (self.projected() and self.wrap_cache.valid(revision)) return self.wrap_cache.rows.items[self.wrap_cache.visualAt(y, self.line_height, self.visibleChanges(revision))].line;
        return annotations.sourceRow(y, self.line_height, self.visibleChanges(revision));
    }
    pub fn primary(self: *const Editor) selection.Selection {
        return self.selections.primary();
    }
    pub fn setSelection(self: *Editor, snapshot: text.Snapshot, range: text.Range) !void {
        try snapshot.validateRange(range);
        self.selections.single(.{ .anchor = range.start, .head = range.end });
        self.typing_group = 0;
    }
    pub fn freshGroup() !u64 {
        const id = next_group.fetchAdd(1, .monotonic);
        if (id == 0 or id == std.math.maxInt(u64)) return error.HistoryGroupExhausted;
        return id;
    }
    fn remember(self: *Editor, state: u64, items: []const selection.Selection) !void {
        for (self.history.items) |entry| if (entry.state == state) return;
        const copy = try self.allocator.dupe(selection.Selection, items);
        errdefer self.allocator.free(copy);
        try self.history.append(self.allocator, .{ .state = state, .items = copy });
        if (self.history.items.len > 1024) {
            const old = self.history.orderedRemove(0);
            self.allocator.free(old.items);
        }
    }
    fn restoreSelections(self: *Editor, snapshot: text.Snapshot) !void {
        for (self.history.items) |entry| if (entry.state == snapshot.stateId()) {
            try self.selections.items.ensureTotalCapacity(self.allocator, entry.items.len);
            self.selections.items.clearRetainingCapacity();
            self.selections.items.appendSliceAssumeCapacity(entry.items);
            self.selections.synchronize(snapshot);
            return;
        };
        self.selections.synchronize(snapshot);
    }
    pub fn applyEdits(self: *Editor, document: *text.Document, edits: []const text.Edit, group: u64) !Outcome {
        return self.applyEditsWithSelection(document, edits, group, null);
    }

    /// Applies one transaction while keeping a single intentional caret. This
    /// is used by language edits that include auxiliary edits elsewhere in the
    /// document, such as an import added by completion.
    pub fn applyEditsWithSelection(self: *Editor, document: *text.Document, edits: []const text.Edit, group: u64, selection_range: ?text.Range) !Outcome {
        var prepared = try self.prepareEdits(document, edits, group, if (selection_range) |range| .{ .caret = range } else .edit_carets);
        defer prepared.deinit();
        return prepared.commit();
    }

    pub const EditSelection = union(enum) { preserve, edit_carets, caret: text.Range };

    /// Prepares text and selection history without changing the document. The
    /// editor and document must stay at their current addresses until commit.
    pub const PreparedEdit = struct {
        editor: *Editor,
        document: *text.Document,
        text_edit: text.Document.PreparedEdit,
        before: text.Snapshot,
        edits: []const text.Edit,
        selections: []selection.Selection,
        transferred: bool = false,

        pub fn deinit(self: *PreparedEdit) void {
            self.text_edit.deinit();
            self.before.deinit();
            if (!self.transferred) self.editor.allocator.free(self.selections);
        }

        pub fn commit(self: *PreparedEdit) !Outcome {
            if (self.transferred) return error.EditAlreadyCommitted;
            const editor_value = self.editor;
            var change = try self.text_edit.commit(self.document);
            if (change.before == change.after) {
                change.deinit();
                return .{ .handled = true };
            }
            editor_value.pairs.map(&change);
            editor_value.mapHighlights(&change);
            if (editor_value.edit_scope) |*scope| {
                scope.start = change.map(scope.start, .before);
                scope.end = change.map(scope.end, .after);
            }
            editor_value.wrap_cache.noteChange(&change);
            vim_repeat.changed(editor_value, &change, self.edits);
            editor_value.selections.items.clearRetainingCapacity();
            editor_value.selections.items.appendSliceAssumeCapacity(self.selections);
            editor_value.selections.normalize();
            editor_value.history.appendAssumeCapacity(.{ .state = change.state, .items = self.selections });
            self.transferred = true;
            if (editor_value.history.items.len > 1024) {
                const old = editor_value.history.orderedRemove(0);
                editor_value.allocator.free(old.items);
            }
            var snapshot = self.document.snapshot();
            defer snapshot.deinit();
            const row = if (self.edits.len > 0) (self.before.pointAt(self.edits[0].range.start) catch unreachable).line else 0;
            if (editor_value.language == .plain) editor_value.syntax_cache.clear() else {
                if (editor_value.syntax_cache.revision != self.before.revision() or self.edits.len > 1) editor_value.syntax_cache.clear();
                editor_value.syntax_cache.refresh(snapshot, editor_value.language, row) catch editor_value.syntax_cache.clear();
            }
            editor_value.reveal(snapshot);
            return .{ .handled = true, .change = change };
        }
    };

    pub fn prepareEdits(self: *Editor, document: *text.Document, edits: []const text.Edit, group: u64, selection_mode: EditSelection) !PreparedEdit {
        if (self.edit_scope) |scope| for (edits) |edit| {
            if (edit.range.start < scope.start or edit.range.end > scope.end) return error.CrossExcerptEdit;
        };
        var before = document.snapshot();
        errdefer before.deinit();
        try self.remember(before.stateId(), self.selections.items.items);
        try self.history.ensureUnusedCapacity(self.allocator, 1);
        const count = switch (selection_mode) {
            .preserve => self.selections.items.items.len,
            .edit_carets => @max(1, edits.len),
            .caret => 1,
        };
        const after = try self.allocator.alloc(selection.Selection, count);
        errdefer self.allocator.free(after);
        try self.selections.items.ensureTotalCapacity(self.allocator, count);
        var prepared = try document.prepare(before.revision(), edits, group);
        errdefer prepared.deinit();
        const change = &prepared.change;
        switch (selection_mode) {
            .preserve => for (self.selections.items.items, after) |item, *mapped| {
                mapped.* = .{ .anchor = change.map(item.anchor, .after), .head = change.map(item.head, .after) };
            },
            .caret => |range| {
                const end = change.map(range.end, .after);
                after[0] = .{ .anchor = end, .head = end };
            },
            .edit_carets => {
                if (edits.len == 0) after[0] = self.primary();
                for (edits, after[0..edits.len]) |edit, *mapped| {
                    const end = change.map(edit.range.end, .after);
                    mapped.* = .{ .anchor = end, .head = end };
                }
            },
        }
        return .{ .editor = self, .document = document, .text_edit = prepared, .before = before, .edits = edits, .selections = after };
    }
    pub fn insert(self: *Editor, document: *text.Document, bytes: []const u8) !Outcome {
        self.preferred_x = null;
        if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
        self.selections.normalize();
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const edits = try arena.allocator().alloc(text.Edit, self.selections.items.items.len);
        for (self.selections.items.items, 0..) |item, i| edits[i] = .{ .range = item.range(), .text = bytes };
        if (self.typing_group == 0) self.typing_group = try freshGroup();
        return self.applyEdits(document, edits, self.typing_group);
    }
    pub fn execute(self: *Editor, document: *text.Document, command: commands.Command) !Outcome {
        try self.validate();
        if (command != .move or (command.move.direction != .up and command.move.direction != .down and command.move.direction != .page_up and command.move.direction != .page_down)) self.preferred_x = null;
        var snapshot = document.snapshot();
        defer snapshot.deinit();
        switch (command) {
            .insert => |bytes| return self.insert(document, bytes),
            .select_all => {
                const range = self.edit_scope orelse text.Range{ .start = 0, .end = snapshot.byteLen() };
                self.selections.single(.{ .anchor = range.start, .head = range.end });
                self.typing_group = 0;
            },
            .move => |request| {
                try navigation.move(self, snapshot, request);
                self.typing_group = 0;
            },
            .delete_to => |request| {
                self.selections.normalize();
                var arena = std.heap.ArenaAllocator.init(self.allocator);
                defer arena.deinit();
                const edits = try arena.allocator().alloc(text.Edit, self.selections.items.items.len);
                var count: usize = 0;
                for (self.selections.items.items) |item| {
                    var range = item.range();
                    if (item.empty()) {
                        const row = (try snapshot.pointAt(item.head)).line;
                        const at = switch (request.direction) {
                            .home => (try snapshot.lineRange(row)).start,
                            .end => (try snapshot.lineRange(row)).end,
                            .left => try navigation.wordBoundary(snapshot, item.head, false),
                            .right => try navigation.wordBoundary(snapshot, item.head, true),
                            else => item.head,
                        };
                        range = .{ .start = @min(at, item.head), .end = @max(at, item.head) };
                        if (at == item.head and request.direction == .home and row > 0) range.start = (try snapshot.lineRange(row - 1)).end;
                        if (at == item.head and request.direction == .end and row + 1 < snapshot.lineCount()) range.end = try snapshot.lineStart(row + 1);
                    }
                    if (count > 0 and edits[count - 1].range.end >= range.start) {
                        edits[count - 1].range.end = @max(edits[count - 1].range.end, range.end);
                    } else {
                        edits[count] = .{ .range = range, .text = "" };
                        count += 1;
                    }
                }
                self.typing_group = 0;
                return self.applyEdits(document, edits[0..count], 0);
            },
            .toggle_comment => return comments.toggle(self, document, snapshot),
            .delete_line => {
                const row = (try snapshot.pointAt(self.primary().head)).line;
                var range = try snapshot.lineRangeIncludingEnding(row);
                if (range.end == snapshot.byteLen() and row > 0 and (range.start == range.end or (try snapshot.byteAt(range.end - 1)) != '\n')) range.start = (try snapshot.lineRange(row - 1)).end;
                self.typing_group = 0;
                return self.applyEdits(document, &.{.{ .range = range, .text = "" }}, 0);
            },
            .delete_backward, .delete_forward => {
                self.selections.normalize();
                if (command == .delete_backward) if (try pairing.backspace(self, document, snapshot)) |outcome| return outcome;
                var arena = std.heap.ArenaAllocator.init(self.allocator);
                defer arena.deinit();
                const edits = try arena.allocator().alloc(text.Edit, self.selections.items.items.len);
                for (self.selections.items.items, 0..) |item, i| {
                    var range = item.range();
                    if (range.start == range.end) {
                        if (command == .delete_backward) range.start = try snapshot.previousBoundary(range.start) else range.end = try snapshot.nextBoundary(range.end);
                    }
                    edits[i] = .{ .range = range, .text = "" };
                }
                self.typing_group = 0;
                return self.applyEdits(document, edits, 0);
            },
            .undo, .redo => {
                self.typing_group = 0;
                self.marked = null;
                self.composition_group = 0;
                var capacity = self.selections.items.items.len;
                for (self.history.items) |entry| capacity = @max(capacity, entry.items.len);
                try self.selections.items.ensureTotalCapacity(self.allocator, capacity);
                const changed = if (command == .undo) try document.undo() else try document.redo();
                if (changed) {
                    self.pairs.items.clearRetainingCapacity();
                    var current = document.snapshot();
                    defer current.deinit();
                    try self.restoreSelections(current);
                    self.synchronize(current);
                    self.reveal(current);
                }
                return .{ .handled = true, .reset = changed, .history_reset = if (changed) .{ .before = snapshot.revision(), .action = if (command == .undo) .undo else .redo } else null };
            },
            .indent, .outdent => return self.indent(document, snapshot, command == .outdent),
            .newline => return self.newline(document, snapshot),
            .duplicate_line => {
                const row = (try snapshot.pointAt(self.primary().head)).line;
                const range = try snapshot.lineRangeIncludingEnding(row);
                const bytes = try snapshot.copy(self.allocator, range);
                defer self.allocator.free(bytes);
                var arena = std.heap.ArenaAllocator.init(self.allocator);
                defer arena.deinit();
                const insertion = if (row + 1 < snapshot.lineCount()) bytes else try std.mem.concat(arena.allocator(), u8, &.{ "\n", bytes });
                return self.applyEdits(document, &.{.{ .range = .{ .start = range.end, .end = range.end }, .text = insertion }}, 0);
            },
        }
        self.reveal(snapshot);
        return .{ .handled = true };
    }
    fn indent(self: *Editor, document: *text.Document, snapshot: text.Snapshot, remove: bool) !Outcome {
        if (!remove and self.selections.items.items.len == 1 and self.primary().empty()) return self.insert(document, "    ");
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        var edits: std.ArrayList(text.Edit) = .empty;
        var last_row: ?usize = null;
        self.selections.normalize();
        for (self.selections.items.items) |item| {
            const first = (try snapshot.pointAt(item.range().start)).line;
            var end = (try snapshot.pointAt(item.range().end)).line;
            if (item.range().end > item.range().start and item.range().end == try snapshot.lineStart(end)) end -|= 1;
            var row = first;
            while (row <= end) : (row += 1) {
                if (last_row != null and row <= last_row.?) continue;
                last_row = row;
                const start = try snapshot.lineStart(row);
                var n: usize = 0;
                if (remove) while (n < self.tab_width and start + n < snapshot.byteLen()) {
                    const ch = try snapshot.byteAt(start + n);
                    if (ch == '\t' and n == 0) {
                        n = 1;
                        break;
                    }
                    if (ch != ' ') break;
                    n += 1;
                };
                try edits.append(arena.allocator(), .{ .range = .{ .start = start, .end = start + n }, .text = if (remove) "" else "    " });
            }
        }
        self.typing_group = 0;
        return self.applyEdits(document, edits.items, 0);
    }
    fn newline(self: *Editor, document: *text.Document, snapshot: text.Snapshot) !Outcome {
        self.selections.normalize();
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const edits = try arena.allocator().alloc(text.Edit, self.selections.items.items.len);
        const carets = try arena.allocator().alloc(usize, edits.len);
        const ending = if (snapshot.lineCount() > 1 and (try snapshot.lineRangeIncludingEnding(0)).end - (try snapshot.lineRange(0)).end == 2) "\r\n" else "\n";
        for (self.selections.items.items, 0..) |item, i| {
            const range = try snapshot.lineRange((try snapshot.pointAt(item.head)).line);
            var end = range.start;
            while (end < @min(range.end, item.head)) : (end += 1) {
                const ch = try snapshot.byteAt(end);
                if (ch != ' ' and ch != '\t') break;
            }
            const prefix = try snapshot.copy(arena.allocator(), .{ .start = range.start, .end = end });
            const opening = if (item.head > range.start) try snapshot.byteAt(item.head - 1) else @as(u8, 0);
            const closing: u8 = switch (opening) {
                '{' => '}',
                '(' => ')',
                '[' => ']',
                else => 0,
            };
            const split_pair = item.empty() and closing != 0 and item.head < snapshot.byteLen() and try snapshot.byteAt(item.head) == closing;
            const extra: []u8 = if (opening == '{' or split_pair) try arena.allocator().alloc(u8, self.tab_width) else &.{};
            @memset(extra, ' ');
            const inside = try std.mem.concat(arena.allocator(), u8, &.{ ending, prefix, extra });
            carets[i] = inside.len;
            edits[i] = .{ .range = item.range(), .text = if (split_pair) try std.mem.concat(arena.allocator(), u8, &.{ inside, ending, prefix }) else inside };
        }
        self.typing_group = 0;
        var prepared = try self.prepareEdits(document, edits, 0, .preserve);
        defer prepared.deinit();
        for (edits, carets, prepared.selections) |edit, caret, *selected| {
            const end = prepared.text_edit.change.map(edit.range.start, .before) + caret;
            selected.* = .{ .anchor = end, .head = end };
        }
        return prepared.commit();
    }
    pub fn prepareView(self: *Editor, snapshot: text.Snapshot, viewport: ui.Size, metrics: ui.layout.Measurer) !void {
        self.last_viewport = viewport;
        if (self.projected()) {
            const gutter = if (self.show_line_numbers) canvas.gutterWidth(snapshot.lineCount(), self.font_size) else 20;
            try self.wrap_cache.ensure(snapshot, self.projectionWidth(viewport.width - gutter - 12), self.font_size, self.tab_width, metrics);
            if (self.soft_wrap != .none) self.horizontal = 0;
        }
        self.reveal(snapshot);
    }
    pub fn reveal(self: *Editor, snapshot: text.Snapshot) void {
        if (self.wrap_cache.folding.reveal(self.primary().head)) {
            self.wrap_cache.revision = null;
            self.wrap_cache.pending = null;
        }
        const row = (snapshot.pointAt(if (self.vim.enabled and self.vim.visual()) self.vim.cursor else self.primary().head) catch return).line;
        const start = if (self.projected() and self.wrap_cache.valid(snapshot.revision())) self.wrap_cache.rowY(self.wrap_cache.atOffset(if (self.vim.enabled and self.vim.visual()) self.vim.cursor else self.primary().head), self.line_height, self.visibleChanges(snapshot.revision())) else self.rowY(row, snapshot.revision());
        self.scroll.reveal(start, start + self.line_height, self.contentHeight(snapshot), self.last_viewport.height);
    }
    pub fn rowY(self: *const Editor, row: usize, revision: u64) f32 {
        if (self.projected() and self.wrap_cache.valid(revision)) return self.wrap_cache.y(row, self.line_height, self.visibleChanges(revision));
        return annotations.rowY(row, self.line_height, self.visibleChanges(revision));
    }
    pub fn visibleChanges(self: *const Editor, revision: u64) []const annotations.GitChange {
        return if (self.show_git_gutters and self.git_revision == revision) self.git_changes else &.{};
    }
    pub fn contentHeight(self: *const Editor, snapshot: text.Snapshot) f32 {
        return self.rowY(snapshot.lineCount(), snapshot.revision());
    }
    pub fn findNext(self: *Editor, document: *const text.Document, query: []const u8, backward: bool) !bool {
        if (query.len == 0) return false;
        const owned = try self.allocator.dupe(u8, query);
        errdefer self.allocator.free(owned);
        var snapshot = document.snapshot();
        defer snapshot.deinit();
        const modal = self.vim.enabled and self.vim.mode != .insert;
        const start = if (modal and self.primary().empty()) (if (backward) try snapshot.previousBoundary(self.primary().head) else try snapshot.nextBoundary(self.primary().head)) else if (backward) self.primary().range().start else self.primary().range().end;
        const direction: text.Direction = if (backward) .backward else .forward;
        const found: ?text.Range = if (self.search_revision == snapshot.revision() and std.mem.eql(u8, query, self.search_query)) blk: {
            if (self.search_ranges.len == 0) break :blk null;
            if (backward) {
                var i = self.search_ranges.len;
                while (i > 0) {
                    i -= 1;
                    if (self.search_ranges[i].start < self.primary().range().start) break :blk self.search_ranges[i];
                }
                break :blk self.search_ranges[self.search_ranges.len - 1];
            }
            for (self.search_ranges) |range| if (range.start >= start) break :blk range;
            break :blk self.search_ranges[0];
        } else (try snapshot.find(query, start, direction, self.search_case_sensitive)) orelse (try snapshot.find(query, if (backward) snapshot.byteLen() else 0, direction, self.search_case_sensitive));
        self.allocator.free(self.search_query);
        self.search_query = owned;
        self.search_visible = true;
        if (found) |range| {
            self.selections.single(.{ .anchor = range.start, .head = if (modal) range.start else range.end });
            if (modal) {
                self.vim.cursor = range.start;
                self.vim.mode = .normal;
            }
            self.typing_group = 0;
            self.reveal(snapshot);
            return true;
        }
        return false;
    }
    pub fn replaceAll(self: *Editor, document: *text.Document, query: []const u8, replacement: []const u8) !Outcome {
        if (query.len == 0) return .{ .handled = true };
        if (!std.unicode.utf8ValidateSlice(replacement)) return error.InvalidUtf8;
        var snapshot = document.snapshot();
        defer snapshot.deinit();
        var edits: std.ArrayList(text.Edit) = .empty;
        defer edits.deinit(self.allocator);
        var at: usize = 0;
        while (try snapshot.find(query, at, .forward, self.search_case_sensitive)) |range| {
            try edits.append(self.allocator, .{ .range = range, .text = replacement });
            at = range.end;
        }
        self.typing_group = 0;
        return self.applyEdits(document, edits.items, 0);
    }
    pub fn handle(self: *Editor, document: *text.Document, event: *ui.Event(ui.Input)) !Outcome {
        const result = try input.handle(self, document, event);
        if (self.soft_wrap != .none and result.handled) {
            var snapshot = document.snapshot();
            defer snapshot.deinit();
            var fixed: ui.layout.FixedMetrics = .{ .advance = self.font_size * 0.6, .line_height = self.line_height };
            const metrics = if (event._surface != null) try event.textMetrics() else fixed.measurer();
            const gutter = if (self.show_line_numbers) canvas.gutterWidth(snapshot.lineCount(), self.font_size) else 20;
            try self.wrap_cache.ensure(snapshot, self.projectionWidth(event.bounds.width - gutter - 12), self.font_size, self.tab_width, metrics);
            if (event.data == .text or event.data == .edit or event.data == .key_down) self.reveal(snapshot);
        }
        if (result.handled and event._surface != null and (event.data == .text or event.data == .edit or event.data == .key_down)) {
            var snapshot = document.snapshot();
            defer snapshot.deinit();
            navigation.revealHorizontal(self, snapshot, event) catch {};
        }
        return result;
    }
};
