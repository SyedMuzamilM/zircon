//! Typed semantic actions independent of native key codes. Applications provide
//! command enums and bindings; menus and keyboards can invoke the same command.
const std = @import("std");
const p = @import("../platform/interface.zig");
pub const Chord = struct {
    key: p.Key,
    modifiers: p.Modifiers = .{},
    pub fn matches(chord: Chord, key: p.Key, modifiers: p.Modifiers) bool {
        return chord.key == key and chord.modifiers.shift == modifiers.shift and chord.modifiers.command == modifiers.command and chord.modifiers.control == modifiers.control and chord.modifiers.alt == modifiers.alt;
    }
};
pub fn Keymap(comptime Action: type) type {
    return struct {
        pub const Binding = struct { chord: Chord, action: Action };
        bindings: []const Binding,
        pub fn init(bindings: []const Binding) !@This() {
            for (bindings, 0..) |binding, i| for (bindings[0..i]) |other| if (binding.chord.matches(other.chord.key, other.chord.modifiers)) return error.DuplicateKeyBinding;
            return .{ .bindings = bindings };
        }
        pub fn resolve(self: @This(), input: p.Input) ?Action {
            if (input != .key_down) return null;
            for (self.bindings) |binding| if (binding.chord.matches(input.key_down.key, input.key_down.modifiers)) return binding.action;
            return null;
        }
    };
}
