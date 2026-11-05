//! Typed adapters bind entity identities, not pointers to rendered view state.
const std = @import("std");
const runtime = @import("../app/app.zig");
const identity = @import("../entity/entity.zig");
const event = @import("../event/event.zig");
pub const ClickHandler = struct {
    owner: identity.Token,
    invoke: *const fn (*runtime.App, identity.Token, *event.Event(event.Click)) anyerror!void,
    pub fn dispatch(handler: ClickHandler, app: *runtime.App, value: *event.Event(event.Click)) !void {
        try handler.invoke(app, handler.owner, value);
    }
};
pub fn click(owner: identity.Token, comptime function: anytype) ClickHandler {
    const info = @typeInfo(@TypeOf(function)).@"fn";
    if (info.param_types.len != 3) @compileError("onClick requires fn (*Self, *Event(Click), *Context(Self)) !void");
    const pointer = @typeInfo(info.param_types[0].?);
    if (pointer != .pointer or pointer.pointer.attrs.@"const") @compileError("onClick self must be a mutable entity pointer");
    const T = pointer.pointer.child;
    if (info.param_types[1] != *event.Event(event.Click) or info.param_types[2] != *runtime.Context(T)) @compileError("onClick requires (*Self, *Event(Click), *Context(Self))");
    const Adapter = struct {
        fn invoke(app: *runtime.App, token: identity.Token, value: *event.Event(event.Click)) !void {
            try app.update(identity.typed(T, token), call, .{value});
        }
        fn call(self: *T, cx: *runtime.Context(T), value: *event.Event(event.Click)) anyerror!void {
            return @call(.auto, function, .{ self, value, cx });
        }
    };
    return .{ .owner = owner, .invoke = Adapter.invoke };
}
pub fn requireView(comptime T: type) void {
    const Ui = @import("ui.zig").Ui;
    const Element = @import("element.zig").Element;
    if (!@hasDecl(T, "render")) @compileError(@typeName(T) ++ " must implement render(*const Self, *Ui) !Element");
    const info = @typeInfo(@TypeOf(T.render));
    if (info != .@"fn" or info.@"fn".param_types.len != 2 or info.@"fn".param_types[0] != *const T or info.@"fn".param_types[1] != *Ui) @compileError("render must receive (*const Self, *Ui)");
    const result = info.@"fn".return_type.?;
    if (@typeInfo(result) != .error_union or @typeInfo(result).error_union.payload != Element) @compileError("render must return an error union containing Element");
}
