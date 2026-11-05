//! Explicit ownership scopes. Copying a handle never extends an owner's life.
const Token = @import("entity.zig").Token;
pub const Scope = struct { app_id: u32, slot: u32, generation: u32 };
pub const Owner = union(enum) { application, scope: Scope, entity: Token };
