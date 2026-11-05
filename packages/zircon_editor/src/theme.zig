//! Semantic editor colors. Hosts can resolve these from extension contributions
//! without changing lexical token classification or retaining registry pointers.
const ui = @import("zircon_ui");
pub const Theme = struct {
    background: ui.Color = ui.Color.rgb(0x242830),
    foreground: ui.Color = ui.Color.rgb(0xc9d1df),
    active_line: ui.Color = ui.Color.rgb(0x292f3a),
    selection: ui.Color = ui.Color.rgb(0x304e79),
    inactive_selection: ui.Color = ui.Color.rgb(0x2b3648),
    caret: ui.Color = ui.Color.rgb(0x9ac5ff),
    line_number: ui.Color = ui.Color.rgb(0x536075),
    active_number: ui.Color = ui.Color.rgb(0xa5b3c9),
    scrollbar: ui.Color = ui.Color.rgb(0x47536a),
    tokens: [7]ui.Color = .{ ui.Color.rgb(0xc9d1df), ui.Color.rgb(0xc792ea), ui.Color.rgb(0xa9c77e), ui.Color.rgb(0xe4a56a), ui.Color.rgb(0x68788e), ui.Color.rgb(0x9aaac1), ui.Color.rgb(0x78c4ce) },
    pub const light: Theme = .{ .background = ui.Color.rgb(0xf8f9fb), .foreground = ui.Color.rgb(0x28323f), .active_line = ui.Color.rgb(0xeef1f5), .selection = ui.Color.rgb(0xbad4f6), .inactive_selection = ui.Color.rgb(0xd8e2ef), .caret = ui.Color.rgb(0x315eae), .line_number = ui.Color.rgb(0x9aa4b3), .active_number = ui.Color.rgb(0x4a5c74), .scrollbar = ui.Color.rgb(0xaebacb), .tokens = .{ ui.Color.rgb(0x28323f), ui.Color.rgb(0x8d3cb8), ui.Color.rgb(0x50772a), ui.Color.rgb(0xb3652e), ui.Color.rgb(0x7f8b9a), ui.Color.rgb(0x617185), ui.Color.rgb(0x247c89) } };
};
