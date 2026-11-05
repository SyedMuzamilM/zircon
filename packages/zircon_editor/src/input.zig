//! Native-independent input routing for one editor view. Application commands
//! remain with the shell; handled editing events prevent framework defaults.
const std = @import("std");
const text = @import("zircon_text");
const ui = @import("zircon_ui");
const model = @import("editor.zig");
const Editor = model.Editor;
const Outcome = model.Outcome;
const navigation = @import("navigation.zig");
pub fn handle(self: *Editor, document: *text.Document, e: *ui.Event(ui.Input)) !Outcome {
    try self.validate();
    self.last_viewport = .{ .width = e.bounds.width, .height = e.bounds.height };
    var snapshot = document.snapshot();
    defer snapshot.deinit();
    switch (e.data) {
        .text => |bytes| {
            if (bytes.len == 0) return .{};
            const result = try self.insert(document, bytes);
            e.preventDefault();
            return result;
        },
        .edit => |edit| {
            if (edit.revision != document.revision()) return error.StaleTextSnapshot;
            try snapshot.validateRange(.{ .start = edit.range.start, .end = edit.range.end });
            try edit.selection.validate(edit.text);
            if (!std.unicode.utf8ValidateSlice(edit.text)) return error.InvalidUtf8;
            const composing = edit.composing or self.composition_group != 0;
            const previous_group = self.composition_group;
            const previous_typing = self.typing_group;
            const previous_changed = self.composition_changed;
            errdefer {
                self.composition_group = previous_group;
                self.typing_group = previous_typing;
                self.composition_changed = previous_changed;
            }
            if (!composing and self.selections.items.items.len > 1 and std.meta.eql(self.primary().range(), text.Range{ .start = edit.range.start, .end = edit.range.end })) {
                const outcome = try self.insert(document, edit.text);
                e.preventDefault();
                return outcome;
            }
            if (composing) {
                if (self.composition_group == 0) {
                    self.composition_group = try Editor.freshGroup();
                    self.composition_changed = false;
                }
            } else if (self.typing_group == 0) self.typing_group = try Editor.freshGroup();
            const result = try self.applyEdits(document, &.{.{ .range = .{ .start = edit.range.start, .end = edit.range.end }, .text = edit.text }}, if (composing) self.composition_group else self.typing_group);
            if (composing) if (result.change) |change| {
                self.composition_changed = self.composition_changed or change.before != change.after;
            };
            self.selections.single(.{ .anchor = edit.range.start + edit.selection.start, .head = edit.range.start + edit.selection.end });
            self.marked = if (edit.composing) .{ .start = edit.range.start, .end = edit.range.start + edit.text.len } else null;
            if (!edit.composing) {
                self.composition_group = 0;
                self.composition_changed = false;
            }
            if (composing) self.typing_group = 0;
            e.preventDefault();
            return result;
        },
        .unmark => |revision| {
            if (revision != document.revision()) return error.StaleTextSnapshot;
            self.marked = null;
            self.composition_group = 0;
            self.composition_changed = false;
            document.breakHistoryGroup();
            e.preventDefault();
            return .{ .handled = true };
        },
        .key_down => |key| {
            const command = key.modifiers.command or key.modifiers.control;
            // Candidate navigation and acceptance belong to the input method
            // while marked text exists. Escape explicitly cancels our group.
            if (self.marked != null and !command and key.key != .escape) return .{};
            if (!command and (key.key == .up or key.key == .down or key.key == .page_up or key.key == .page_down) and e._surface != null) {
                try navigation.vertical(self, snapshot, e, key.key, key.modifiers.shift);
                e.preventDefault();
                return .{ .handled = true };
            }
            var result: Outcome = .{};
            if (command) switch (key.key) {
                .a => result = try self.execute(document, .select_all),
                .z => result = try self.execute(document, if (key.modifiers.shift) .redo else .undo),
                .y => result = try self.execute(document, .redo),
                .c, .x => {
                    var arena = std.heap.ArenaAllocator.init(self.allocator);
                    defer arena.deinit();
                    var bytes: std.ArrayList(u8) = .empty;
                    for (self.selections.items.items, 0..) |item, i| {
                        if (i > 0) try bytes.append(arena.allocator(), '\n');
                        try bytes.appendSlice(arena.allocator(), try snapshot.copy(arena.allocator(), item.range()));
                    }
                    try e.writeClipboard(bytes.items);
                    result = if (key.key == .x) try self.execute(document, .{ .insert = "" }) else .{ .handled = true };
                    self.typing_group = 0;
                },
                .v => {
                    const bytes = try e.readClipboard(self.allocator);
                    defer self.allocator.free(bytes);
                    self.typing_group = 0;
                    result = try self.insert(document, bytes);
                    self.typing_group = 0;
                },
                .d => {
                    const item = self.primary();
                    if (item.empty()) {
                        const range = try navigation.wordRange(snapshot, item.head);
                        self.selections.single(.{ .anchor = range.start, .head = range.end });
                    } else {
                        const last = self.selections.items.items[self.selections.items.items.len - 1].range();
                        const query = try snapshot.copy(self.allocator, item.range());
                        defer self.allocator.free(query);
                        const next = (try snapshot.find(query, last.end, .forward, true)) orelse (try snapshot.find(query, 0, .forward, true));
                        if (next) |range| {
                            try self.selections.items.append(self.allocator, .{ .anchor = range.start, .head = range.end });
                            self.selections.normalize();
                        }
                    }
                    self.typing_group = 0;
                    result = .{ .handled = true };
                },
                .left, .right, .up, .down => result = try self.execute(document, .{ .move = .{ .direction = switch (key.key) {
                    .left => .home,
                    .right => .end,
                    .up => .document_start,
                    .down => .document_end,
                    else => unreachable,
                }, .extend = key.modifiers.shift } }),
                else => return .{},
            } else switch (key.key) {
                .left, .right, .up, .down, .home, .end, .page_up, .page_down => result = try self.execute(document, .{ .move = .{ .direction = switch (key.key) {
                    .left => .left,
                    .right => .right,
                    .up => .up,
                    .down => .down,
                    .home => .home,
                    .end => .end,
                    .page_up => .page_up,
                    .page_down => .page_down,
                    else => unreachable,
                }, .extend = key.modifiers.shift, .word = key.modifiers.alt } }),
                .backspace => result = try self.execute(document, .delete_backward),
                .delete => result = try self.execute(document, .delete_forward),
                .enter => result = try self.execute(document, .newline),
                .tab => result = try self.execute(document, if (key.modifiers.shift) .outdent else .indent),
                .escape => {
                    if (self.marked != null) {
                        if (self.composition_changed) result = try self.execute(document, .undo) else {
                            self.marked = null;
                            self.composition_group = 0;
                            self.typing_group = 0;
                            document.breakHistoryGroup();
                            result = .{ .handled = true };
                        }
                        self.composition_changed = false;
                    } else {
                        const head = self.primary().head;
                        self.selections.single(.{ .anchor = head, .head = head });
                        result = .{ .handled = true };
                    }
                },
                else => return .{},
            }
            if (result.handled) e.preventDefault();
            return result;
        },
        .pointer_down => |pointer| {
            if (pointer.button != .primary) return .{};
            const at = try navigation.position(self, snapshot, e, pointer.position);
            if (pointer.modifiers.alt) {
                try self.selections.items.append(self.allocator, .{ .anchor = at, .head = at });
                self.selections.normalize();
            } else if (pointer.clicks >= 3) {
                const range = try snapshot.lineRangeIncludingEnding((try snapshot.pointAt(at)).line);
                self.selections.single(.{ .anchor = range.start, .head = range.end });
            } else if (pointer.clicks == 2) {
                const range = try navigation.wordRange(snapshot, at);
                self.selections.single(.{ .anchor = range.start, .head = range.end });
            } else if (pointer.modifiers.shift) {
                self.selections.items.items[0].head = at;
            } else self.selections.single(.{ .anchor = at, .head = at });
            self.dragging = true;
            self.preferred_x = null;
            self.typing_group = 0;
            e.focus();
            e.capturePointer();
            e.preventDefault();
            return .{ .handled = true };
        },
        .pointer_move => |pointer| {
            if (!self.dragging) return .{};
            self.selections.items.items[0].head = try navigation.position(self, snapshot, e, pointer.position);
            e.preventDefault();
            return .{ .handled = true };
        },
        .pointer_up => {
            if (!self.dragging) return .{};
            self.dragging = false;
            e.releasePointer();
            return .{ .handled = true };
        },
        .scroll => |wheel| {
            self.scroll.wheel(wheel.y, @as(f32, @floatFromInt(snapshot.lineCount())) * self.line_height, e.bounds.height);
            self.horizontal = @max(0, self.horizontal - wheel.x);
            e.preventDefault();
            return .{ .handled = true };
        },
        .focus => |focused| {
            if (!focused) self.dragging = false;
            return .{ .handled = true };
        },
        else => return .{},
    }
}
