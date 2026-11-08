//! Record semantic command keys and the resulting inserted span, rather than
//! replaying native IME events or copying an entire document to repeat one edit.
const std = @import("std");
const text = @import("zircon_text");
const editor = @import("editor.zig");
const Editor = editor.Editor;
pub const Recording = struct {
    keys: [64]u8 = undefined,
    len: usize = 0,
    last_keys: []u8 = &.{},
    inserted: []u8 = &.{},
    start: usize = 0,
    end: usize = 0,
    active: bool = false,
    changed: bool = false,
    replaying: bool = false,
    pub fn deinit(self: *Recording, a: std.mem.Allocator) void {
        a.free(self.last_keys);
        a.free(self.inserted);
    }
    pub fn append(self: *Recording, key: u8) void {
        if (self.len == self.keys.len) {
            self.len = 0;
            return;
        }
        self.keys[self.len] = key;
        self.len += 1;
    }
    pub fn remember(self: *Recording, a: std.mem.Allocator, inserted: []const u8) !void {
        const keys = try a.dupe(u8, self.keys[0..self.len]);
        errdefer a.free(keys);
        const bytes = try a.dupe(u8, inserted);
        a.free(self.last_keys);
        a.free(self.inserted);
        self.last_keys = keys;
        self.inserted = bytes;
    }
};
pub fn changed(self: *Editor, change: *const text.Change, edits: []const text.Edit) void {
    const recording = &self.vim.recording;
    if (!recording.active or recording.replaying) return;
    if (edits.len != 1 or edits[0].range.start < recording.start or edits[0].range.end > recording.end) {
        recording.active = false;
        recording.len = 0;
        return;
    }
    recording.end = change.map(recording.end, .after);
    recording.changed = true;
}
pub fn finish(self: *Editor, s: text.Snapshot) !void {
    const recording = &self.vim.recording;
    if (recording.active and recording.changed and recording.end <= s.byteLen()) {
        const bytes = try s.copy(self.allocator, .{ .start = recording.start, .end = recording.end });
        defer self.allocator.free(bytes);
        try recording.remember(self.allocator, bytes);
    }
    recording.active = false;
    recording.len = 0;
}
