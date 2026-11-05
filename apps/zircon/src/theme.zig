//! Chrome colors stay separate from the editor's language-token palette.
const ui = @import("zircon_ui");
pub const document = ui.Color.rgb(0x171b22);
pub const chrome = ui.Color.rgb(0x202630);
pub const sidebar = ui.Color.rgb(0x1c222b);
pub const panel = ui.Color.rgb(0x252d39);
pub const line = ui.Color.rgb(0x303a48);
pub const text = ui.Color.rgb(0xd9e1ed);
pub const muted = ui.Color.rgb(0x8996a9);
pub const accent = ui.Color.rgb(0x8abaff);
pub const selected = ui.Color.rgb(0x2d4261);
pub const warning = ui.Color.rgb(0xe7bc80);
pub const primary = ui.Color.rgb(0x365b93);
pub const ui_text: ui.TextStyle = .{ .size = 13, .color = text };
