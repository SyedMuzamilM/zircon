//! Commit messages use the editor's selection, history, wrapping and IME paths.

const std = @import("std");
const editing = @import("zircon_editor");
const text = @import("zircon_text");
const ui = @import("zircon_ui");
const v = @import("../components.zig");
pub const height: f32 = 104;
pub const Message = struct {
    allocator: std.mem.Allocator,
    document: text.Document,
    editor: editing.Editor,
    placeholder: []const u8 = "Commit message…",
    placeholder_color: ui.Color = .transparent,

    pub fn init(a: std.mem.Allocator) !Message {
        var document = try text.Document.init(a, "");
        errdefer document.deinit();
        var editor = try editing.Editor.init(a);
        errdefer editor.deinit();
        editor.font_size = 13;
        editor.line_height = 20;
        editor.show_line_numbers = false;
        editor.show_fold_controls = false;
        editor.show_git_gutters = false;
        editor.show_indent_guides = false;
        editor.highlight_active_line = false;
        editor.auto_close_pairs = false;
        editor.soft_wrap = .editor_width;
        return .{ .allocator = a, .document = document, .editor = editor };
    }

    pub fn deinit(self: *Message, _: std.mem.Allocator) void {
        self.editor.deinit();
        self.document.deinit();
    }

    pub fn copy(self: *const Message, a: std.mem.Allocator, out: *[]u8) !void {
        var snapshot = self.document.snapshot();
        defer snapshot.deinit();
        out.* = try snapshot.copy(a, .{ .start = 0, .end = snapshot.byteLen() });
    }

    pub fn replace(self: *Message, cx: *ui.Context(Message), bytes: []const u8) !void {
        var snapshot = self.document.snapshot();
        defer snapshot.deinit();
        var change = try self.document.apply(snapshot.revision(), &.{.{ .range = .{ .start = 0, .end = snapshot.byteLen() }, .text = bytes }}, 0);
        change.deinit();
        self.editor.selections.single(.{ .anchor = bytes.len, .head = bytes.len });
        self.editor.typing_group = 0;
        self.editor.scroll.offset = 0;
        self.editor.horizontal = 0;
        self.editor.marked = null;
        self.editor.composition_group = 0;
        var current = self.document.snapshot();
        defer current.deinit();
        self.editor.synchronize(current);
        cx.notify();
    }

    pub fn setColors(self: *Message, cx: *ui.Context(Message), colors: v.Palette) void {
        self.editor.theme.background = colors.document;
        self.editor.theme.foreground = colors.text;
        self.editor.theme.caret = colors.accent;
        self.editor.theme.selection = colors.selected;
        self.editor.theme.inactive_selection = colors.hover;
        self.editor.theme.scrollbar = colors.muted;
        self.placeholder_color = colors.muted;
        cx.notify();
    }

    pub fn render(self: *const Message, b: *ui.Ui) !ui.Element {
        var children: std.ArrayList(ui.Element) = .empty;
        try children.append(b.allocator(), try self.editor.render(&self.document, b));
        var snapshot = self.document.snapshot();
        defer snapshot.deinit();
        if (snapshot.byteLen() == 0) try children.append(b.allocator(), try b.fluent().div()
            .padding(.{ .left = 20, .top = 3 })
            .children(.{v.text(b, self.placeholder, self.placeholder_color, 13)})
            .build());
        return b.fluent().div()
            .h(.{ .px = height })
            .min_h(.{ .px = 0 })
            .overflow_hidden()
            .background(self.editor.theme.background)
            .stack()
            .children(children.items)
            .id(.{ .string = "commit-message-editor" })
            .listeners(.{ .focusable = true, .on_input = b.onInput(onInput) })
            .build();
    }

    fn onInput(self: *Message, e: *ui.Event(ui.Input), cx: *ui.Context(Message)) !void {
        // Commands for file search belong to the workspace, not this draft.
        var outcome = try self.editor.handle(&self.document, e);
        defer if (outcome.change) |*change| change.deinit();
        if (outcome.handled) {
            e.stopPropagation();
            cx.notify();
        }
    }
};
