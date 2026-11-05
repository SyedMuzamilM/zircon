//! Semantic chrome colors resolved independently from editor token classes.
const ui = @import("zircon_ui");
pub const Palette = struct {
    document: ui.Color = ui.Color.rgb(0x242830),
    chrome: ui.Color = ui.Color.rgb(0x303641),
    sidebar: ui.Color = ui.Color.rgb(0x292e37),
    panel: ui.Color = ui.Color.rgb(0x303640),
    line: ui.Color = ui.Color.rgb(0x3c4350),
    text: ui.Color = ui.Color.rgb(0xd3dae5),
    muted: ui.Color = ui.Color.rgb(0x929cab),
    accent: ui.Color = ui.Color.rgb(0x87afd6),
    selected: ui.Color = ui.Color.rgb(0x3d485b),
    warning: ui.Color = ui.Color.rgb(0xd8b579),
    primary: ui.Color = ui.Color.rgb(0x426486),
    pub const light: Palette = .{ .document = ui.Color.rgb(0xf8f9fb), .chrome = ui.Color.rgb(0xe7ebf1), .sidebar = ui.Color.rgb(0xeff2f6), .panel = ui.Color.rgb(0xf5f7fa), .line = ui.Color.rgb(0xd5dce6), .text = ui.Color.rgb(0x293344), .muted = ui.Color.rgb(0x748197), .accent = ui.Color.rgb(0x315f9b), .selected = ui.Color.rgb(0xd4e2f4), .warning = ui.Color.rgb(0x9d652c), .primary = ui.Color.rgb(0x416fa9) };
};
