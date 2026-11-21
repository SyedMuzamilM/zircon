//! Parse the two LSP text-edit encodings into one validated representation.

const std = @import("std");
const model = @import("model.zig");
/// The caller owns the returned files and their strings in the supplied arena.
pub fn parse(a: std.mem.Allocator, value: std.json.Value) ![]const model.FileEdits {
    if (value == .null) return &.{};
    if (value != .object) return error.InvalidWorkspaceEdit;
    const changes = value.object.get("changes");
    const document_changes = value.object.get("documentChanges");
    if (changes != null and document_changes != null) return error.AmbiguousWorkspaceEdit;
    if (document_changes) |items| {
        if (items != .array or items.array.items.len > 1024) return error.InvalidWorkspaceEdit;
        const files = try a.alloc(model.FileEdits, items.array.items.len);
        for (items.array.items, files) |item, *file| {
            if (field(item, "kind") != null) return error.UnsupportedResourceOperation;
            const document = field(item, "textDocument") orelse return error.InvalidWorkspaceEdit;
            const version = field(document, "version") orelse return error.InvalidWorkspaceEdit;
            file.* = .{
                .uri = try a.dupe(u8, try string(field(document, "uri") orelse return error.InvalidWorkspaceEdit)),
                .version = if (version == .null) null else try unsigned(version),
                .edits = try parseEdits(a, field(item, "edits") orelse return error.InvalidWorkspaceEdit),
            };
        }
        return files;
    }
    if (changes) |items| {
        if (items != .object or items.object.count() > 1024) return error.InvalidWorkspaceEdit;
        const files = try a.alloc(model.FileEdits, items.object.count());
        var iterator = items.object.iterator();
        var index: usize = 0;
        while (iterator.next()) |entry| : (index += 1) files[index] = .{ .uri = try a.dupe(u8, entry.key_ptr.*), .edits = try parseEdits(a, entry.value_ptr.*) };
        return files;
    }
    return &.{};
}

fn parseEdits(a: std.mem.Allocator, value: std.json.Value) ![]const model.TextEdit {
    if (value != .array or value.array.items.len > 4096) return error.InvalidWorkspaceEdit;
    const edits = try a.alloc(model.TextEdit, value.array.items.len);
    for (value.array.items, edits) |item, *edit| {
        const range = field(item, "range") orelse return error.InvalidWorkspaceEdit;
        edit.* = .{
            .range = .{ .start = try position(field(range, "start") orelse return error.InvalidWorkspaceEdit), .end = try position(field(range, "end") orelse return error.InvalidWorkspaceEdit) },
            .new_text = try a.dupe(u8, try string(field(item, "newText") orelse return error.InvalidWorkspaceEdit)),
        };
    }
    return edits;
}

fn position(value: std.json.Value) !model.Position {
    return .{ .line = @intCast(try unsigned(field(value, "line") orelse return error.InvalidWorkspaceEdit)), .character = @intCast(try unsigned(field(value, "character") orelse return error.InvalidWorkspaceEdit)) };
}
fn field(value: std.json.Value, name: []const u8) ?std.json.Value {
    return if (value == .object) value.object.get(name) else null;
}
fn string(value: std.json.Value) ![]const u8 {
    return if (value == .string) value.string else error.InvalidWorkspaceEdit;
}
fn unsigned(value: std.json.Value) !u64 {
    return if (value == .integer and value.integer >= 0) @intCast(value.integer) else error.InvalidWorkspaceEdit;
}
