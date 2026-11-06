//! Semantic editing commands, independent of shortcuts or application chrome.
pub const Direction = enum { left, right, up, down, home, end, page_up, page_down, document_start, document_end };
pub const Move = struct { direction: Direction, extend: bool = false, word: bool = false };
pub const Command = union(enum) {
    insert: []const u8,
    delete_backward,
    delete_forward,
    delete_to: Move,
    delete_line,
    toggle_comment,
    move: Move,
    select_all,
    undo,
    redo,
    indent,
    outdent,
    newline,
    duplicate_line,
};
