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

/// Context-aware multi-stroke bindings. The map keeps only a small pending
/// prefix; callers decide how to handle a pending sequence timeout.
pub fn SequenceMap(comptime Action: type) type {
    return struct {
        pub const Binding = struct {
            sequence: []const Chord,
            action: Action,
            context: []const u8 = "",
        };
        pub const Result = union(enum) { none, pending, action: Action };
        bindings: []const Binding,
        pending: []const Chord = &.{},
        context: []const u8 = "",

        pub fn init(bindings: []const Binding) !@This() {
            for (bindings, 0..) |binding, i| {
                if (binding.sequence.len == 0) return error.EmptyKeySequence;
                for (bindings[0..i]) |other| if (other.sequence.len == binding.sequence.len and sameSequence(other.sequence, binding.sequence) and std.mem.eql(u8, other.context, binding.context)) return error.DuplicateKeyBinding;
            }
            return .{ .bindings = bindings };
        }

        pub fn setContext(self: *@This(), context: []const u8) void {
            self.context = context;
            self.pending = &.{};
        }

        pub fn reset(self: *@This()) void {
            self.pending = &.{};
        }

        pub fn resolve(self: *@This(), input: p.Input) Result {
            if (input != .key_down) return .none;
            const key = input.key_down.key;
            const modifiers = input.key_down.modifiers;
            const prefix = self.pending;
            var next: []const Chord = &.{};
            for (self.bindings) |binding| {
                if (binding.context.len != 0 and !std.mem.eql(u8, binding.context, self.context)) continue;
                if (binding.sequence.len <= prefix.len or !sameSequence(binding.sequence[0..prefix.len], prefix)) continue;
                if (!binding.sequence[prefix.len].matches(key, modifiers)) continue;
                if (binding.sequence.len == prefix.len + 1) {
                    self.reset();
                    return .{ .action = binding.action };
                }
                next = binding.sequence[0 .. prefix.len + 1];
            }
            self.pending = next;
            if (next.len != 0) return .pending;
            if (prefix.len != 0) return self.resolve(input);
            return .none;
        }
    };
}

fn sameSequence(a: []const Chord, b: []const Chord) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| if (!left.matches(right.key, right.modifiers)) return false;
    return true;
}
