//! Semantic chrome colors resolved independently from editor token classes.
const ui = @import("zircon_ui");
pub const Palette = struct {
    document: ui.Color = ui.Color.rgb(0x282c33),
    chrome: ui.Color = ui.Color.rgb(0x3b414d),
    sidebar: ui.Color = ui.Color.rgb(0x2f343e),
    panel: ui.Color = ui.Color.rgb(0x2f343e),
    tab_bar: ui.Color = ui.Color.rgb(0x2f343e),
    hover: ui.Color = ui.Color.rgb(0x363c46),
    folder: ui.Color = ui.Color.rgb(0xd6bf83),
    line: ui.Color = ui.Color.rgb(0x464b57),
    text: ui.Color = ui.Color.rgb(0xdce0e5),
    muted: ui.Color = ui.Color.rgb(0xa9afbc),
    accent: ui.Color = ui.Color.rgb(0x74ade8),
    selected: ui.Color = ui.Color.rgb(0x364357),
    warning: ui.Color = ui.Color.rgb(0xd8b579),
    primary: ui.Color = ui.Color.rgb(0x4d78a3),
    pub const light: Palette = .{ .document = ui.Color.rgb(0xf8f9fb), .chrome = ui.Color.rgb(0xe7ebf1), .sidebar = ui.Color.rgb(0xeff2f6), .panel = ui.Color.rgb(0xf5f7fa), .tab_bar = ui.Color.rgb(0xe7ebf1), .hover = ui.Color.rgb(0xdce2eb), .folder = ui.Color.rgb(0x9d7333), .line = ui.Color.rgb(0xd5dce6), .text = ui.Color.rgb(0x293344), .muted = ui.Color.rgb(0x748197), .accent = ui.Color.rgb(0x315f9b), .selected = ui.Color.rgb(0xd4e2f4), .warning = ui.Color.rgb(0x9d652c), .primary = ui.Color.rgb(0x416fa9) };
};
