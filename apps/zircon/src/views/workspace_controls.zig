//! Workspace-popover dispatch. Each feature owns its rows and interactions.
const std = @import("std");
const ui = @import("zircon_ui");
const actions = @import("../actions.zig");
const commands_module = @import("../commands.zig");
const shell = @import("../shell.zig");
const editor_options = @import("popovers/editor_options.zig");
const language = @import("popovers/language_picker.zig");
const language_servers = @import("popovers/language_servers.zig");
const recent = @import("popovers/recent_projects.zig");
const Shell = shell.Shell;
pub const Choice = language.Choice;
pub const choices = language.choices;
pub const choose = language.choose;
pub fn input(self: *Shell, e: *ui.Event(ui.Input), cx: *ui.Context(Shell)) !bool {
    if (self.popup == .none or e.data != .key_down) return false;
    if (e.data.key_down.key == .escape) {
        self.popup = .none;
    } else {
        const handled = switch (self.popup) {
            .language => try language.input(self, e, cx),
            .recent => try recent.input(self, e, cx),
            else => false,
        };
        if (!handled) return false;
    }
    e.preventDefault();
    e.stopPropagation();
    cx.notify();
    return true;
}

pub fn render(self: *const Shell, b: *ui.Ui) !ui.Element {
    return switch (self.popup) {
        .language => language.render(self, b),
        .recent => recent.render(self, b),
        .servers => language_servers.render(self, b),
        .editor => editor_options.render(self, b),
        .none => unreachable,
    };
}

pub fn open(self: *Shell, cx: *ui.Context(Shell), which: commands_module.Command) !void {
    switch (which) {
        .recent_projects, .language_picker, .language_servers, .editor_options => {
            if (which == .language_picker and self.tabs.items.len == 0) return;
            self.popup = switch (which) {
                .recent_projects => .recent,
                .language_picker => .language,
                .language_servers => .servers,
                else => .editor,
            };
            self.overlay_index = 0;
            switch (which) {
                .recent_projects => try recent.prepare(self, cx),
                .language_picker => try language.prepare(self, cx),
                else => {},
            }
            if (which == .language_picker) {
                var arena = std.heap.ArenaAllocator.init(self.allocator);
                defer arena.deinit();
                const current = try actions.active(self);
                const record = try self.workspace.getConst(current.id);
                const items = try choices(self, arena.allocator(), "");
                for (items, 0..) |choice, i| {
                    const matches = if (self.languageName(current.id)) |name| std.mem.eql(u8, name, choice.name) else std.mem.eql(u8, std.fs.path.extension(record.path orelse ""), std.fs.path.extension(choice.path));
                    if (matches) {
                        self.overlay_index = i;
                        break;
                    }
                }
            }
        },
        else => unreachable,
    }
}
