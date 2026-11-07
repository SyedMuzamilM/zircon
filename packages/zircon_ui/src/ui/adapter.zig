//! Generated adapters bind entity identities and immutable frame-owned payloads.
//! No callback stores a pointer into mutable entity state or a render stack.
const std = @import("std");
const runtime = @import("../app/app.zig");
const identity = @import("../entity/entity.zig");
const event = @import("../event/event.zig");
pub fn Handler(comptime E: type) type {
    return struct {
        owner: identity.Token,
        payload: ?*const anyopaque = null,
        invoke: *const fn (*runtime.App, identity.Token, *event.Event(E), ?*const anyopaque) anyerror!void,
        pub fn dispatch(handler: @This(), app: *runtime.App, value: *event.Event(E)) !void {
            try handler.invoke(app, handler.owner, value, handler.payload);
        }
    };
}
pub const InputHandler = Handler(event.Input);
pub const ClickHandler = Handler(event.Click);
pub fn click(owner: identity.Token, comptime callback: anytype) ClickHandler {
    return bind(event.Click, owner, callback);
}
pub fn input(owner: identity.Token, comptime callback: anytype) InputHandler {
    return bind(event.Input, owner, callback);
}
pub fn clickWith(a: std.mem.Allocator, owner: identity.Token, value: anytype, comptime callback: anytype) !ClickHandler {
    return bindWith(event.Click, a, owner, value, callback);
}
pub fn inputWith(a: std.mem.Allocator, owner: identity.Token, value: anytype, comptime callback: anytype) !InputHandler {
    return bindWith(event.Input, a, owner, value, callback);
}
fn validate(comptime E: type, comptime F: type, comptime count: usize) type {
    const name = if (E == event.Click) "onClick" else "onInput";
    const message = name ++ " requires fn (*Self, *Event(" ++ (if (E == event.Click) "Click" else "Input") ++ "), *Context(Self)) !void";
    const info = @typeInfo(F).@"fn";
    if (info.param_types.len != count) @compileError(message);
    const pointer = @typeInfo(info.param_types[0].?);
    if (pointer != .pointer or pointer.pointer.attrs.@"const") @compileError(name ++ " self must be a mutable entity pointer");
    const T = pointer.pointer.child;
    if (info.param_types[1] != *event.Event(E) or info.param_types[2] != *runtime.Context(T)) @compileError(message);
    return T;
}
pub fn CallbackPayload(comptime E: type, comptime F: type) type {
    _ = validate(E, F, 4);
    return @typeInfo(F).@"fn".param_types[3] orelse @compileError("handler payload parameter must have a concrete type");
}
fn bind(comptime E: type, owner: identity.Token, comptime callback: anytype) Handler(E) {
    const T = comptime validate(E, @TypeOf(callback), 3);
    const Adapter = struct {
        fn invoke(app: *runtime.App, token: identity.Token, value: *event.Event(E), _: ?*const anyopaque) !void {
            try app.update(identity.typed(T, token), call, .{value});
        }
        fn call(self: *T, cx: *runtime.Context(T), value: *event.Event(E)) anyerror!void {
            return @call(.auto, callback, .{ self, value, cx });
        }
    };
    return .{ .owner = owner, .invoke = Adapter.invoke };
}
fn bindWith(comptime E: type, a: std.mem.Allocator, owner: identity.Token, value: anytype, comptime callback: anytype) !Handler(E) {
    const Payload = @TypeOf(value);
    comptime requireValue(Payload);
    const T = comptime validate(E, @TypeOf(callback), 4);
    if (@typeInfo(@TypeOf(callback)).@"fn".param_types[3] != Payload) @compileError("handler payload parameter must match the copied payload type");
    const Adapter = struct {
        fn invoke(app: *runtime.App, token: identity.Token, e: *event.Event(E), raw: ?*const anyopaque) !void {
            const payload: *const Payload = @ptrCast(@alignCast(raw.?));
            try app.update(identity.typed(T, token), call, .{ e, payload.* });
        }
        fn call(self: *T, cx: *runtime.Context(T), e: *event.Event(E), payload: Payload) anyerror!void {
            return @call(.auto, callback, .{ self, e, cx, payload });
        }
    };
    const owned = try a.create(Payload);
    owned.* = value;
    return .{ .owner = owner, .payload = owned, .invoke = Adapter.invoke };
}
fn requireValue(comptime T: type) void {
    if (@import("../entity/value.zig").containsPointer(T)) @compileError("handler payloads must be pointer-free copied values");
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
