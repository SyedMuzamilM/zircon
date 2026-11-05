//! Verified framework foundations. This module has no native or GPU imports.
pub const App = @import("app/app.zig").App;
pub const Context = @import("app/app.zig").Context;
pub const Entity = @import("entity/entity.zig").Entity;
pub const Scope = @import("entity/scope.zig").Scope;
pub const testing = struct {
    pub const Harness = @import("testing/headless.zig").Harness;
};
