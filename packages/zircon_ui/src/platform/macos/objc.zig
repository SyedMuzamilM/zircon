//! Direct Objective-C runtime bindings used by the macOS adapter. There is no
//! generated C header, Objective-C source, or widget-toolkit dependency.
//! Message signatures are generated from the concrete argument tuple at comptime.
const std = @import("std");
const builtin = @import("builtin");
pub const Id = ?*anyopaque;
pub const SEL = *opaque {};
pub const CGPoint = extern struct { x: f64 = 0, y: f64 = 0 };
pub const CGSize = extern struct { width: f64 = 0, height: f64 = 0 };
pub const CGRect = extern struct { origin: CGPoint = .{}, size: CGSize = .{} };
pub const NSRange = extern struct { location: usize, length: usize };
extern "c" fn objc_getClass([*:0]const u8) Id;
extern "c" fn sel_registerName([*:0]const u8) SEL;
extern "c" fn sel_getName(SEL) [*:0]const u8;
extern "c" fn objc_msgSend() void;
extern "c" fn objc_msgSend_stret() void;
extern "c" fn objc_autoreleasePoolPush() ?*anyopaque;
extern "c" fn objc_autoreleasePoolPop(?*anyopaque) void;
pub fn class(name: [:0]const u8) Id {
    return objc_getClass(name.ptr);
}
pub fn sel(name: [:0]const u8) SEL {
    return sel_registerName(name.ptr);
}
pub fn selectorName(value: SEL) []const u8 {
    return std.mem.span(sel_getName(value));
}
pub fn send(comptime R: type, target: Id, selector: [:0]const u8, args: anytype) R {
    const Arguments = @typeInfo(@TypeOf(args)).@"struct".field_types;
    const parameters = comptime blk: {
        var types: [Arguments.len + 2]type = undefined;
        types[0] = Id;
        types[1] = SEL;
        for (Arguments, 0..) |T, i| types[i + 2] = T;
        break :blk types;
    };
    const F = @Fn(&parameters, &@splat(.{}), R, .{ .@"callconv" = .c });
    const needs_stret = comptime builtin.cpu.arch == .x86_64 and @typeInfo(R) == .@"struct" and @sizeOf(R) > 16;
    const function: *const F = if (needs_stret) @ptrCast(&objc_msgSend_stret) else @ptrCast(&objc_msgSend);
    return @call(.auto, function, .{ target, sel(selector) } ++ args);
}
pub fn retain(value: Id) Id {
    return send(Id, value, "retain", .{});
}
pub fn release(value: Id) void {
    if (value != null) send(void, value, "release", .{});
}
pub fn string(bytes: []const u8) Id {
    const result = send(Id, send(Id, class("NSString"), "alloc", .{}), "initWithBytes:length:encoding:", .{ @as(?*const anyopaque, if (bytes.len == 0) null else bytes.ptr), bytes.len, @as(usize, 4) });
    return send(Id, result, "autorelease", .{});
}
pub fn fromString(value: Id) []const u8 {
    const pointer = send(?[*:0]const u8, value, "UTF8String", .{});
    return if (pointer) |p| std.mem.span(p) else "";
}
pub const Pool = struct {
    handle: ?*anyopaque,
    pub fn init() Pool {
        return .{ .handle = objc_autoreleasePoolPush() };
    }
    pub fn deinit(pool: Pool) void {
        objc_autoreleasePoolPop(pool.handle);
    }
};
pub extern "c" fn clock_gettime_nsec_np(u32) u64;
pub fn clockNs() u64 {
    return clock_gettime_nsec_np(8);
}
