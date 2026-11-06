//! Semantic editor colors. Hosts can resolve these from extension contributions
//! without changing lexical token classification or retaining registry pointers.
const ui = @import("zircon_ui");
pub const Theme = struct {
    git_added: ui.Color = ui.Color.rgb(0x75b88a),
    git_modified: ui.Color = ui.Color.rgb(0xd8b579),
    git_deleted: ui.Color = ui.Color.rgb(0xd1787c),
    background: ui.Color = ui.Color.rgb(0x282c33),
    foreground: ui.Color = ui.Color.rgb(0xacb2be),
    active_line: ui.Color = ui.Color.rgb(0x2f343e),
    selection: ui.Color = ui.Color.rgb(0x3d5275),
    inactive_selection: ui.Color = ui.Color.rgb(0x33425a),
    caret: ui.Color = ui.Color.rgb(0x528bff),
    line_number: ui.Color = ui.Color.rgb(0x7b8495),
    active_number: ui.Color = ui.Color.rgb(0xabb2bf),
    scrollbar: ui.Color = ui.Color.rgb(0x47536a),
    tokens: [7]ui.Color = .{ ui.Color.rgb(0xacb2be), ui.Color.rgb(0xc678dd), ui.Color.rgb(0x98c379), ui.Color.rgb(0xd19a66), ui.Color.rgb(0x5c6370), ui.Color.rgb(0xabb2bf), ui.Color.rgb(0x56b6c2) },
    pub const light: Theme = .{ .git_added = ui.Color.rgb(0x477531), .git_modified = ui.Color.rgb(0x946f20), .git_deleted = ui.Color.rgb(0xb3434e), .background = ui.Color.rgb(0xfafafa), .foreground = ui.Color.rgb(0x383a42), .active_line = ui.Color.rgb(0xeef1f5), .selection = ui.Color.rgb(0xc6d2f5), .inactive_selection = ui.Color.rgb(0xe0e5f1), .caret = ui.Color.rgb(0x315eae), .line_number = ui.Color.rgb(0x7a8290), .active_number = ui.Color.rgb(0x4a5c74), .scrollbar = ui.Color.rgb(0xaebacb), .tokens = .{ ui.Color.rgb(0x383a42), ui.Color.rgb(0x8a2f94), ui.Color.rgb(0x3c7e35), ui.Color.rgb(0x9c4e00), ui.Color.rgb(0x68717c), ui.Color.rgb(0x5b6370), ui.Color.rgb(0x16647b) } };
};
