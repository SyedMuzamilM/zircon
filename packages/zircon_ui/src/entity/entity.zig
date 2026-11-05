//! Non-owning typed identities. State lives in stable storage owned by a scope.
pub const Token = struct { app_id: u32, slot: u32, generation: u32 };
pub fn Entity(comptime T: type) type {
    return struct {
        app_id: u32,
        slot: u32,
        generation: u32,
        pub const State = T;
        pub fn token(handle: @This()) Token {
            return .{ .app_id = handle.app_id, .slot = handle.slot, .generation = handle.generation };
        }
    };
}
pub fn typed(comptime T: type, token: Token) Entity(T) {
    return .{ .app_id = token.app_id, .slot = token.slot, .generation = token.generation };
}
pub fn typeTag(comptime T: type) usize {
    const Identity = struct {
        var marker: u8 = 0;
        pub const State = T;
    };
    return @intFromPtr(&Identity.marker);
}
