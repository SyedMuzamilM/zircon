//! Bounded settings overrides. A null action unbinds a chord, including defaults.
const std = @import("std");
const ui = @import("zircon_ui");
const catalogue = @import("commands.zig");
pub const Override = struct { chord: ui.Keymap(catalogue.Command).Binding, disabled: bool = false };
pub const Overrides = struct {
    items: [32]Override = undefined,
    len: usize = 0,
    pub fn resolve(self: *const Overrides, input: ui.Input) ?catalogue.Command {
        if (input != .key_down) return null;
        for (self.items[0..self.len]) |item| if (item.chord.chord.matches(input.key_down.key, input.key_down.modifiers)) return if (item.disabled) null else item.chord.action;
        const map: ui.Keymap(catalogue.Command) = .{ .bindings = &catalogue.bindings };
        return map.resolve(input);
    }
    /// Clipboard chords are normally handled inside Editor. Projected views
    /// must resolve them before dispatching to an individual source editor.
    pub fn resolveEditor(self: *const Overrides, input: ui.Input) ?catalogue.Command {
        if (self.resolve(input)) |command| return command;
        if (input != .key_down or !input.key_down.modifiers.command) return null;
        return switch (input.key_down.key) {
            .a => .select_all,
            .c => .copy,
            .x => .cut,
            .v => .paste,
            else => null,
        };
    }
    pub fn shortcut(self: *const Overrides, a: std.mem.Allocator, action: catalogue.Command) ![]const u8 {
        for (self.items[0..self.len]) |item| if (!item.disabled and item.chord.action == action) return format(a, item.chord);
        for (catalogue.bindings) |binding| if (binding.action == action) {
            var overridden = false;
            for (self.items[0..self.len]) |item| if (item.chord.chord.matches(binding.chord.key, binding.chord.modifiers)) {
                overridden = true;
                break;
            };
            if (!overridden) return format(a, binding);
        };
        return "";
    }
};
pub fn parse(value: std.json.Value) !Overrides {
    if (value != .object or value.object.count() > 32) return error.InvalidKeyBindings;
    var result: Overrides = .{};
    var iterator = value.object.iterator();
    while (iterator.next()) |entry| {
        var tokens = std.mem.splitScalar(u8, entry.key_ptr.*, '-');
        var modifiers: ui.Modifiers = .{};
        var key: ?ui.Key = null;
        while (tokens.next()) |token| {
            if (key != null) return error.InvalidKeyBindings;
            if (std.mem.eql(u8, token, "cmd")) {
                if (modifiers.command) return error.InvalidKeyBindings;
                modifiers.command = true;
            } else if (std.mem.eql(u8, token, "ctrl")) {
                if (modifiers.control) return error.InvalidKeyBindings;
                modifiers.control = true;
            } else if (std.mem.eql(u8, token, "alt")) {
                if (modifiers.alt) return error.InvalidKeyBindings;
                modifiers.alt = true;
            } else if (std.mem.eql(u8, token, "shift")) {
                if (modifiers.shift) return error.InvalidKeyBindings;
                modifiers.shift = true;
            } else key = std.meta.stringToEnum(ui.Key, token) orelse return error.InvalidKeyBindings;
        }
        if (key == null or key.? == .unknown or (!modifiers.command and !modifiers.control and !modifiers.alt and !functionKey(key.?))) return error.InvalidKeyBindings;
        const action = entry.value_ptr.*;
        const command = if (action == .null) catalogue.Command.dismiss else if (action == .string) std.meta.stringToEnum(catalogue.Command, action.string) orelse return error.InvalidKeyBindings else return error.InvalidKeyBindings;
        if (catalogue.retired(command)) continue;
        if (action != .null) {
            var public = false;
            for (catalogue.commands) |item| if (item.command == command) {
                public = true;
                break;
            };
            if (!public) return error.InvalidKeyBindings;
        }
        const binding: ui.Keymap(catalogue.Command).Binding = .{ .chord = .{ .key = key.?, .modifiers = modifiers }, .action = command };
        for (result.items[0..result.len]) |other| if (other.chord.chord.matches(key.?, modifiers)) return error.DuplicateKeyBinding;
        result.items[result.len] = .{ .chord = binding, .disabled = action == .null };
        result.len += 1;
    }
    return result;
}

fn format(a: std.mem.Allocator, binding: ui.Keymap(catalogue.Command).Binding) ![]const u8 {
    const m = binding.chord.modifiers;
    const key: []const u8 = switch (binding.chord.key) {
        .left => "←",
        .right => "→",
        .up => "↑",
        .down => "↓",
        .comma => ",",
        .period => ".",
        .slash => "/",
        .space => "Space",
        .enter => "Enter",
        else => @tagName(binding.chord.key),
    };
    const label = try std.fmt.allocPrint(a, "{s}{s}{s}{s}{s}", .{ if (m.control) "⌃" else "", if (m.alt) "⌥" else "", if (m.shift) "⇧" else "", if (m.command) "⌘" else "", key });
    for (label) |*byte| byte.* = std.ascii.toUpper(byte.*);
    return label;
}

fn functionKey(key: ui.Key) bool {
    return switch (key) {
        .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12 => true,
        else => false,
    };
}
