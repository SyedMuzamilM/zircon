//! Workspace-popover dispatch. Each feature owns its rows and interactions.
const ui = @import("zircon_ui");
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
