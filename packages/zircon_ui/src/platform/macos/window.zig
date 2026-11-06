//! AppKit windows and input through direct Zig Objective-C runtime bindings.
//! The heap-stable adapter is referenced by a private NSView ivar. Callbacks
//! borrow native strings only while delivering the synchronous framework event.
const std = @import("std");
const objc = @import("objc.zig");
const platform = @import("../interface.zig");
const geometry = @import("../../layout/geometry.zig");
const scene = @import("../../graphics/scene.zig");
const measurement = @import("../../layout/measure.zig");
const TextStyle = @import("../../text/style.zig").TextStyle;
const shaping = @import("../../text/shaping.zig");
const metal = @import("../../graphics/backends/metal.zig");
const Id = objc.Id;
const Sel = *opaque {};
const Range = extern struct { location: usize, length: usize };
// Foundation defines NSNotFound as NSIntegerMax, even in NSRange.location.
const not_found: usize = std.math.maxInt(isize);
const TextRequest = struct {
    kind: enum { insert, mark, unmark },
    value: Id = null,
    selection: Range = .{ .location = 0, .length = 0 },
    replacement: Range = .{ .location = not_found, .length = 0 },
};
extern "c" fn objc_allocateClassPair(Id, [*:0]const u8, usize) Id;
extern "c" fn objc_registerClassPair(Id) void;
extern "c" fn objc_disposeClassPair(Id) void;
extern "c" fn pthread_main_np() c_int;
extern "c" fn class_addIvar(Id, [*:0]const u8, usize, u8, [*:0]const u8) bool;
extern "c" fn class_addMethod(Id, Sel, *const anyopaque, [*:0]const u8) bool;
extern "c" fn class_addProtocol(Id, Id) bool;
extern "c" fn objc_getProtocol([*:0]const u8) Id;
extern "c" fn object_getInstanceVariable(Id, [*:0]const u8, *?*anyopaque) ?*anyopaque;
extern "c" fn object_setInstanceVariable(Id, [*:0]const u8, ?*anyopaque) ?*anyopaque;
extern "c" fn sel_registerName([*:0]const u8) Sel;
var view_class: Id = null;
var callback_error: ?anyerror = null;
var application = std.atomic.Value(usize).init(0);
var wake_pending = std.atomic.Value(bool).init(false);
const wake_subtype: i16 = 0x5a49;

/// AppKit permits posting events from a worker thread. The application singleton
/// is captured on the main thread before clients can start. Coalescing bounds
/// queued wake events even when a server publishes thousands of messages.
pub fn wake() void {
    const address = application.load(.acquire);
    if (address == 0 or wake_pending.swap(true, .acq_rel)) return;
    const pool = objc.Pool.init();
    defer pool.deinit();
    const event = objc.send(Id, objc.class("NSEvent"), "otherEventWithType:location:modifierFlags:timestamp:windowNumber:context:subtype:data1:data2:", .{ @as(usize, 15), objc.CGPoint{}, @as(usize, 0), @as(f64, 0), @as(isize, 0), @as(Id, null), wake_subtype, @as(isize, 0), @as(isize, 0) });
    if (event) |value| objc.send(void, @as(Id, @ptrFromInt(address)), "postEvent:atStart:", .{ value, false }) else wake_pending.store(false, .release);
}

const State = struct {
    allocator: std.mem.Allocator,
    sink: platform.Sink,
    window: Id,
    view: Id,
    layer: Id,
    renderer: *metal.Renderer,
    marked: Id = null,
    input: ?platform.TextSnapshot = null,
    awaiting_snapshot: bool = false,
    text_requests: std.ArrayList(TextRequest) = .empty,
    closed: bool = false,
    pending_appearance: ?bool = null,
    fn emit(s: *State, event: platform.Input) void {
        if (s.closed and event != .close) return;
        s.sink.event(s.sink.context, event) catch |err| {
            // A document changed after the input method queried its snapshot.
            // The window marks itself dirty and publishes a fresh snapshot;
            // refusing this obsolete replacement is ordinary recovery.
            if (err != error.StaleTextSnapshot and callback_error == null) callback_error = err;
        };
    }
};

pub fn now() f64 {
    return @as(f64, @floatFromInt(objc.clockNs())) / 1e9;
}

/// Pumps one native event, blocking at most the requested duration. A negative
/// timeout blocks until input. Application rendering stays outside AppKit.
pub fn pump(timeout_seconds: f64) !void {
    if (pthread_main_np() == 0) return error.WrongThread;
    const pool = objc.Pool.init();
    defer pool.deinit();
    const app = objc.send(Id, objc.class("NSApplication"), "sharedApplication", .{});
    // An input method may issue several mutations in one native callback.
    // Replay later requests only after the framework publishes the resulting
    // document snapshot. No guessed document revision enters the next edit.
    const windows = objc.send(Id, app, "windows", .{});
    const count = objc.send(usize, windows, "count", .{});
    for (0..count) |i| {
        const native_window = objc.send(Id, windows, "objectAtIndex:", .{i});
        const view = objc.send(Id, native_window, "contentView", .{});
        if (nativeState(view)) |s| if (s.pending_appearance) |dark| {
            s.pending_appearance = null;
            s.emit(.{ .appearance = dark });
        };
        if (nativeState(view)) |s| if (!s.closed and !s.awaiting_snapshot and s.text_requests.items.len > 0) {
            const request = s.text_requests.orderedRemove(0);
            defer objc.release(request.value);
            processTextRequest(s, request) catch |err| {
                if (callback_error == null) callback_error = err;
            };
            return takeCallbackError();
        };
    }
    const deadline = if (timeout_seconds < 0)
        objc.send(Id, objc.class("NSDate"), "distantFuture", .{})
    else
        objc.send(Id, objc.class("NSDate"), "dateWithTimeIntervalSinceNow:", .{@max(0, timeout_seconds)});
    const event = objc.send(Id, app, "nextEventMatchingMask:untilDate:inMode:dequeue:", .{ @as(usize, std.math.maxInt(usize)), deadline, objc.string("kCFRunLoopDefaultMode"), true });
    if (event != null) {
        if (objc.send(usize, event, "type", .{}) == 15 and objc.send(i16, event, "subtype", .{}) == wake_subtype) wake_pending.store(false, .release) else objc.send(void, app, "sendEvent:", .{event});
    }
    objc.send(void, app, "updateWindows", .{});
    try takeCallbackError();
}
fn takeCallbackError() !void {
    if (callback_error) |err| {
        callback_error = null;
        return err;
    }
}

pub fn open(allocator: std.mem.Allocator, options: platform.WindowOptions, sink: platform.Sink) !platform.Surface {
    if (pthread_main_np() == 0) return error.WrongThread;
    if (!std.math.isFinite(options.width) or !std.math.isFinite(options.height) or options.width <= 0 or options.height <= 0 or options.width > 32768 or options.height > 32768) return error.InvalidWindowSize;
    if (!std.unicode.utf8ValidateSlice(options.title)) return error.InvalidUtf8;
    const pool = objc.Pool.init();
    defer pool.deinit();
    const app = objc.send(Id, objc.class("NSApplication"), "sharedApplication", .{}) orelse return error.AppKitUnavailable;
    application.store(@intFromPtr(app), .release);
    _ = objc.send(bool, app, "setActivationPolicy:", .{@as(isize, 0)});
    objc.send(void, app, "finishLaunching", .{});
    try registerView();
    const renderer = try metal.create(allocator);
    errdefer metal.destroy(renderer);
    const rect: objc.CGRect = .{ .size = .{ .width = options.width, .height = options.height } };
    const style: usize = 1 | 2 | 4 | 8 | if (options.chrome == .integrated) @as(usize, 1 << 15) else 0;
    const window = objc.send(Id, objc.send(Id, objc.class("NSWindow"), "alloc", .{}), "initWithContentRect:styleMask:backing:defer:", .{ rect, style, @as(usize, 2), false }) orelse return error.WindowCreationFailed;
    errdefer objc.release(window);
    objc.send(void, window, "setReleasedWhenClosed:", .{false});
    if (options.chrome == .integrated) {
        objc.send(void, window, "setTitleVisibility:", .{@as(isize, 1)});
        objc.send(void, window, "setTitlebarAppearsTransparent:", .{true});
        objc.send(void, window, "setMovableByWindowBackground:", .{false});
    }
    const view = objc.send(Id, objc.send(Id, view_class, "alloc", .{}), "initWithFrame:", .{rect}) orelse return error.WindowCreationFailed;
    errdefer objc.release(view);
    const layer = objc.send(Id, objc.class("CAMetalLayer"), "new", .{}) orelse return error.WindowCreationFailed;
    errdefer objc.release(layer);
    const s = try allocator.create(State);
    errdefer allocator.destroy(s);
    s.* = .{ .allocator = allocator, .sink = sink, .window = window, .view = view, .layer = layer, .renderer = renderer };
    _ = object_setInstanceVariable(view, "zirconState", s);
    errdefer _ = object_setInstanceVariable(view, "zirconState", null);
    objc.send(void, layer, "setDevice:", .{renderer.device});
    objc.send(void, layer, "setPixelFormat:", .{@as(usize, 80)});
    objc.send(void, layer, "setFramebufferOnly:", .{true});
    objc.send(void, layer, "setPresentsWithTransaction:", .{false});
    objc.send(void, layer, "setMaximumDrawableCount:", .{@as(usize, 3)});
    objc.send(void, view, "setWantsLayer:", .{true});
    objc.send(void, view, "setLayer:", .{layer});
    objc.send(void, view, "setAutoresizingMask:", .{@as(usize, 2 | 16)});
    objc.send(void, window, "setContentView:", .{view});
    // Follow hover through entry and exit as well as movement. The visible-rect
    // option keeps this area correct when AppKit resizes the content view.
    const tracking = objc.send(Id, objc.send(Id, objc.class("NSTrackingArea"), "alloc", .{}), "initWithRect:options:owner:userInfo:", .{ objc.CGRect{}, @as(usize, 1 | 2 | 0x80 | 0x200), view, @as(Id, null) }) orelse return error.WindowCreationFailed;
    objc.send(void, view, "addTrackingArea:", .{tracking});
    objc.release(tracking);
    objc.send(void, window, "setDelegate:", .{view});
    objc.send(void, window, "setTitle:", .{objc.string(options.title)});
    objc.send(void, window, "setAcceptsMouseMovedEvents:", .{true});
    objc.send(void, window, "setContentMinSize:", .{objc.CGSize{ .width = 320, .height = 200 }});
    _ = objc.send(bool, window, "makeFirstResponder:", .{view});
    objc.send(void, window, "center", .{});
    if (options.visible) {
        objc.send(void, window, "makeKeyAndOrderFront:", .{@as(Id, null)});
        objc.send(void, app, "activateIgnoringOtherApps:", .{true});
    }
    updateLayer(s);
    return .{ .context = s, .ops = &ops };
}

const ops: platform.Surface.Ops = .{
    .system_dark = systemDark,
    .set_appearance = setAppearance,
    .choose_path = choosePath,
    .typography = setTypography,
    .deinit = deinit,
    .size = size,
    .present = present,
    .measurer = measurer,
    .snapshot = snapshot,
    .clipboard_read = clipboardRead,
    .clipboard_write = clipboardWrite,
    .set_text_input = setTextInput,
    .set_parent = setParent,
    .raise = raise,
    .accept_close = acceptClose,
};
fn systemDark(_: *anyopaque) bool {
    const app = objc.send(Id, objc.class("NSApplication"), "sharedApplication", .{});
    const appearance = objc.send(Id, app, "effectiveAppearance", .{});
    const names = objc.send(Id, objc.class("NSArray"), "arrayWithObjects:count:", .{ &[_]Id{ objc.string("NSAppearanceNameAqua"), objc.string("NSAppearanceNameDarkAqua") }, @as(usize, 2) });
    const match = objc.send(Id, appearance, "bestMatchFromAppearancesWithNames:", .{names});
    return std.mem.eql(u8, objc.fromString(match), "NSAppearanceNameDarkAqua");
}
fn setAppearance(raw: *anyopaque, dark: ?bool) void {
    const appearance: Id = if (dark) |value| objc.send(Id, objc.class("NSAppearance"), "appearanceNamed:", .{objc.string(if (value) "NSAppearanceNameDarkAqua" else "NSAppearanceNameAqua")}) else null;
    objc.send(void, state(raw).window, "setAppearance:", .{appearance});
}
fn didChangeAppearance(object: Id, _: Sel) callconv(.c) void {
    const s = nativeState(object) orelse return;
    s.pending_appearance = systemDark(s);
    wake();
}
fn state(raw: *anyopaque) *State {
    return @ptrCast(@alignCast(raw));
}
fn setParent(raw: *anyopaque, parent: ?platform.Surface) void {
    const s = state(raw);
    const old = objc.send(Id, s.window, "parentWindow", .{});
    if (old != null) objc.send(void, old, "removeChildWindow:", .{s.window});
    if (parent) |surface| {
        std.debug.assert(surface.ops == &ops);
        const parent_window = state(surface.context).window;
        const parent_frame = objc.send(objc.CGRect, parent_window, "frame", .{});
        const child_frame = objc.send(objc.CGRect, s.window, "frame", .{});
        objc.send(void, s.window, "setFrameOrigin:", .{objc.CGPoint{ .x = parent_frame.origin.x + (parent_frame.size.width - child_frame.size.width) / 2, .y = parent_frame.origin.y + (parent_frame.size.height - child_frame.size.height) / 2 }});
        objc.send(void, parent_window, "addChildWindow:ordered:", .{ s.window, @as(isize, 1) });
    }
}
fn raise(raw: *anyopaque) void {
    const s = state(raw);
    if (!s.closed) objc.send(void, s.window, "makeKeyAndOrderFront:", .{@as(Id, null)});
}
fn nativeState(object: Id) ?*State {
    var raw: ?*anyopaque = null;
    _ = object_getInstanceVariable(object, "zirconState", &raw);
    return if (raw) |value| @ptrCast(@alignCast(value)) else null;
}
fn deinit(raw: *anyopaque) void {
    const s = state(raw);
    const pool = objc.Pool.init();
    defer pool.deinit();
    s.closed = true;
    setParent(raw, null);
    objc.send(void, s.window, "setDelegate:", .{@as(Id, null)});
    _ = object_setInstanceVariable(s.view, "zirconState", null);
    objc.send(void, s.window, "orderOut:", .{@as(Id, null)});
    objc.send(void, s.window, "close", .{});
    objc.send(void, s.view, "setLayer:", .{@as(Id, null)});
    metal.destroy(s.renderer);
    objc.release(s.marked);
    for (s.text_requests.items) |request| objc.release(request.value);
    s.text_requests.deinit(s.allocator);
    objc.release(s.layer);
    objc.release(s.view);
    objc.release(s.window);
    s.allocator.destroy(s);
}
fn size(raw: *anyopaque) geometry.Size {
    const bounds = objc.send(objc.CGRect, state(raw).view, "bounds", .{});
    return .{ .width = @floatCast(bounds.size.width), .height = @floatCast(bounds.size.height) };
}
fn updateLayer(s: *State) void {
    const dimensions = size(s);
    const scale = objc.send(f64, s.window, "backingScaleFactor", .{});
    objc.send(void, s.layer, "setContentsScale:", .{scale});
    objc.send(void, s.layer, "setDrawableSize:", .{objc.CGSize{ .width = dimensions.width * scale, .height = dimensions.height * scale }});
}
fn present(raw: *anyopaque, frame: scene.Frame) !bool {
    const s = state(raw);
    if (s.closed or objc.send(bool, s.window, "isMiniaturized", .{})) return false;
    const dimensions = size(raw);
    if (dimensions.width <= 0 or dimensions.height <= 0) return false;
    const pool = objc.Pool.init();
    defer pool.deinit();
    updateLayer(s);
    const drawable = objc.send(Id, s.layer, "nextDrawable", .{}) orelse return false;
    const texture = objc.send(Id, drawable, "texture", .{}) orelse return error.InvalidDrawable;
    const scale: f32 = @floatCast(objc.send(f64, s.window, "backingScaleFactor", .{}));
    try metal.draw(s.renderer, frame, dimensions, scale, texture, drawable, false);
    return true;
}
fn measurer(raw: *anyopaque) measurement.Measurer {
    return .{ .context = raw, .text = measureText, .caret_fn = caret, .index_fn = index };
}
fn setTypography(raw: *anyopaque, value: @import("../../text/typography.zig").Typography) void {
    metal.setTypography(state(raw).renderer, value);
}
fn choosePath(_: *anyopaque, allocator: std.mem.Allocator, kind: platform.Surface.PathKind) !?[]u8 {
    const panel = objc.send(Id, objc.class("NSOpenPanel"), "openPanel", .{}) orelse return error.NativeDialogUnavailable;
    objc.send(void, panel, "setCanChooseDirectories:", .{kind == .folder});
    objc.send(void, panel, "setCanChooseFiles:", .{kind == .file});
    objc.send(void, panel, "setAllowsMultipleSelection:", .{false});
    objc.send(void, panel, "setPrompt:", .{objc.string("Open")});
    if (objc.send(isize, panel, "runModal", .{}) != 1) return null;
    const url = objc.send(Id, panel, "URL", .{}) orelse return error.InvalidPath;
    return try allocator.dupe(u8, objc.fromString(objc.send(Id, url, "path", .{})));
}
fn caret(raw: ?*anyopaque, bytes: []const u8, style: TextStyle, offset: usize) f32 {
    return state(raw.?).renderer.text.caret(bytes, style.size, style.mono, offset);
}
fn index(raw: ?*anyopaque, bytes: []const u8, style: TextStyle, x: f32) usize {
    return state(raw.?).renderer.text.index(bytes, style.size, style.mono, x);
}
fn measureText(raw: ?*anyopaque, bytes: []const u8, style: TextStyle) !geometry.Size {
    const s = state(raw.?);
    const layout = try s.renderer.text.layout(bytes, style.size, style.mono);
    var ascent: f64 = 0;
    var descent: f64 = 0;
    var leading: f64 = 0;
    const width = shaping.CTLineGetTypographicBounds(layout.line, &ascent, &descent, &leading);
    return .{ .width = @floatCast(width), .height = @floatCast(@max(@as(f64, style.size), ascent + descent + leading)) };
}
fn snapshot(raw: *anyopaque, frame: scene.Frame, path: []const u8) !void {
    const s = state(raw);
    return metal.snapshot(s.renderer, frame, size(raw), path);
}
fn clipboardRead(_: *anyopaque, allocator: std.mem.Allocator) ![]u8 {
    const pool = objc.Pool.init();
    defer pool.deinit();
    const pasteboard = objc.send(Id, objc.class("NSPasteboard"), "generalPasteboard", .{});
    const value = objc.send(Id, pasteboard, "stringForType:", .{objc.string("public.utf8-plain-text")});
    return allocator.dupe(u8, stringBytes(value));
}
fn clipboardWrite(_: *anyopaque, bytes: []const u8) !void {
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
    const pool = objc.Pool.init();
    defer pool.deinit();
    const pasteboard = objc.send(Id, objc.class("NSPasteboard"), "generalPasteboard", .{});
    _ = objc.send(isize, pasteboard, "clearContents", .{});
    if (!objc.send(bool, pasteboard, "setString:forType:", .{ objc.string(bytes), objc.string("public.utf8-plain-text") })) return error.ClipboardUnavailable;
}
fn setTextInput(raw: *anyopaque, value: ?platform.TextSnapshot) void {
    const s = state(raw);
    if (value == null and s.input == null and s.text_requests.items.len == 0 and s.marked == null) return;
    const pool = objc.Pool.init();
    defer pool.deinit();
    s.input = value;
    s.awaiting_snapshot = false;
    if (value == null) {
        for (s.text_requests.items) |request| objc.release(request.value);
        s.text_requests.clearRetainingCapacity();
        objc.release(s.marked);
        s.marked = null;
    }
    const context = objc.send(Id, s.view, "inputContext", .{});
    objc.send(void, context, "invalidateCharacterCoordinates", .{});
}
fn acceptClose(raw: *anyopaque) void {
    const s = state(raw);
    if (s.closed) return;
    s.closed = true;
    const pool = objc.Pool.init();
    defer pool.deinit();
    objc.send(void, s.window, "orderOut:", .{@as(Id, null)});
}

fn add(comptime function: anytype, selector: [:0]const u8, encoding: [:0]const u8) !void {
    if (!class_addMethod(view_class, sel_registerName(selector.ptr), @ptrCast(&function), encoding.ptr)) return error.NativeClassRegistrationFailed;
}
fn registerView() !void {
    if (view_class != null) return;
    view_class = objc_allocateClassPair(objc.class("NSView"), "ZirconFrameworkView", 0) orelse return error.NativeClassRegistrationFailed;
    errdefer {
        objc_disposeClassPair(view_class);
        view_class = null;
    }
    if (!class_addIvar(view_class, "zirconState", @sizeOf(?*anyopaque), @intCast(@ctz(@as(usize, @alignOf(?*anyopaque)))), "^v")) return error.NativeClassRegistrationFailed;
    try add(yes, "isFlipped", "B@:");
    try add(yes, "acceptsFirstResponder", "B@:");
    try add(acceptsFirstMouse, "acceptsFirstMouse:", "B@:@");
    try add(yes, "isOpaque", "B@:");
    try add(pointerDown, "mouseDown:", "v@:@");
    try add(pointerDown, "rightMouseDown:", "v@:@");
    try add(pointerDown, "otherMouseDown:", "v@:@");
    try add(pointerUp, "mouseUp:", "v@:@");
    try add(pointerUp, "rightMouseUp:", "v@:@");
    try add(pointerUp, "otherMouseUp:", "v@:@");
    try add(pointerMove, "mouseMoved:", "v@:@");
    try add(pointerMove, "mouseEntered:", "v@:@");
    try add(pointerExit, "mouseExited:", "v@:@");
    try add(pointerMove, "mouseDragged:", "v@:@");
    try add(pointerMove, "rightMouseDragged:", "v@:@");
    try add(pointerMove, "otherMouseDragged:", "v@:@");
    try add(scroll, "scrollWheel:", "v@:@");
    try add(didChangeAppearance, "viewDidChangeEffectiveAppearance", "v@:");
    try add(keyDown, "keyDown:", "v@:@");
    try add(insertText, "insertText:replacementRange:", "v@:@{_NSRange=QQ}");
    try add(insertSimpleText, "insertText:", "v@:@");
    try add(setMarkedText, "setMarkedText:selectedRange:replacementRange:", "v@:@{_NSRange=QQ}{_NSRange=QQ}");
    try add(unmarkText, "unmarkText", "v@:");
    try add(hasMarkedText, "hasMarkedText", "B@:");
    try add(markedRange, "markedRange", "{_NSRange=QQ}@:");
    try add(selectedRange, "selectedRange", "{_NSRange=QQ}@:");
    try add(validMarkedAttributes, "validAttributesForMarkedText", "@@:");
    try add(attributedSubstring, "attributedSubstringForProposedRange:actualRange:", "@@:{_NSRange=QQ}^{_NSRange=QQ}");
    try add(characterIndex, "characterIndexForPoint:", "Q@:{CGPoint=dd}");
    try add(firstRect, "firstRectForCharacterRange:actualRange:", "{CGRect={CGPoint=dd}{CGSize=dd}}@:{_NSRange=QQ}^{_NSRange=QQ}");
    try add(command, "doCommandBySelector:", "v@::");
    try add(shouldClose, "windowShouldClose:", "B@:@");
    try add(didResize, "windowDidResize:", "v@:@");
    try add(didResize, "windowDidChangeBackingProperties:", "v@:@");
    try add(didFocus, "windowDidBecomeKey:", "v@:@");
    try add(didBlur, "windowDidResignKey:", "v@:@");
    const protocol = objc_getProtocol("NSTextInputClient");
    if (protocol != null) _ = class_addProtocol(view_class, protocol);
    objc_registerClassPair(view_class);
}
fn yes(_: Id, _: Sel) callconv(.c) bool {
    return true;
}
fn acceptsFirstMouse(_: Id, _: Sel, _: Id) callconv(.c) bool {
    return true;
}
fn eventPoint(s: *State, event: Id) geometry.Point {
    const point = objc.send(objc.CGPoint, event, "locationInWindow", .{});
    const local = objc.send(objc.CGPoint, s.view, "convertPoint:fromView:", .{ point, @as(Id, null) });
    return .{ .x = @floatCast(local.x), .y = @floatCast(local.y) };
}
fn modifiers(event: Id) platform.Modifiers {
    const flags = objc.send(usize, event, "modifierFlags", .{});
    return .{ .shift = flags & (1 << 17) != 0, .control = flags & (1 << 18) != 0, .alt = flags & (1 << 19) != 0, .command = flags & (1 << 20) != 0 };
}
fn pointer(s: *State, event: Id) platform.Pointer {
    const button = objc.send(isize, event, "buttonNumber", .{});
    return .{ .position = eventPoint(s, event), .button = if (button == 1) .secondary else if (button == 2) .middle else .primary, .modifiers = modifiers(event), .clicks = @intCast(@min(255, @max(1, objc.send(isize, event, "clickCount", .{})))) };
}
fn pointerDown(object: Id, _: Sel, event: Id) callconv(.c) void {
    const s = nativeState(object) orelse return;
    const p = pointer(s, event);
    if (p.button == .primary) if (s.sink.drag_region) |query| if (query(s.sink.context, p.position)) {
        if (p.clicks == 2) objc.send(void, s.window, "performZoom:", .{@as(Id, null)}) else objc.send(void, s.window, "performWindowDragWithEvent:", .{event});
        return;
    };
    _ = objc.send(bool, s.window, "makeFirstResponder:", .{s.view});
    s.emit(.{ .pointer_down = pointer(s, event) });
}
fn pointerUp(object: Id, _: Sel, event: Id) callconv(.c) void {
    const s = nativeState(object) orelse return;
    s.emit(.{ .pointer_up = pointer(s, event) });
}
fn pointerMove(object: Id, _: Sel, event: Id) callconv(.c) void {
    const s = nativeState(object) orelse return;
    // Tracking events have a location and modifiers, but AppKit raises an
    // exception for clickCount/buttonNumber. Only button events use pointer().
    const kind = objc.send(usize, event, "type", .{});
    s.emit(.{ .pointer_move = .{ .position = eventPoint(s, event), .modifiers = modifiers(event), .button = if (kind == 7) .secondary else if (kind == 27) .middle else .primary } });
}
fn pointerExit(object: Id, _: Sel, _: Id) callconv(.c) void {
    const s = nativeState(object) orelse return;
    s.emit(.pointer_leave);
}
fn scroll(object: Id, _: Sel, event: Id) callconv(.c) void {
    const s = nativeState(object) orelse return;
    const precise = objc.send(bool, event, "hasPreciseScrollingDeltas", .{});
    const multiplier: f64 = if (precise) 1 else 20;
    s.emit(.{ .scroll = .{ .position = eventPoint(s, event), .x = @floatCast(objc.send(f64, event, "scrollingDeltaX", .{}) * multiplier), .y = @floatCast(objc.send(f64, event, "scrollingDeltaY", .{}) * multiplier), .modifiers = modifiers(event) } });
}
fn keyDown(object: Id, _: Sel, event: Id) callconv(.c) void {
    const s = nativeState(object) orelse return;
    const mods = modifiers(event);
    const key_code = objc.send(u16, event, "keyCode", .{});
    s.emit(.{ .key_down = .{ .key = key(key_code), .modifiers = mods, .repeat = objc.send(bool, event, "isARepeat", .{}) } });
    if (mods.command or mods.control or s.closed) return;
    const events = objc.send(Id, objc.class("NSArray"), "arrayWithObject:", .{event});
    objc.send(void, object, "interpretKeyEvents:", .{events});
}
fn key(code: u16) platform.Key {
    return switch (code) {
        0 => .a,
        1 => .s,
        2 => .d,
        3 => .f,
        4 => .h,
        5 => .g,
        6 => .z,
        7 => .x,
        8 => .c,
        9 => .v,
        11 => .b,
        12 => .q,
        13 => .w,
        14 => .e,
        15 => .r,
        16 => .y,
        17 => .t,
        31 => .o,
        32 => .u,
        34 => .i,
        35 => .p,
        37 => .l,
        38 => .j,
        40 => .k,
        43 => .comma,
        45 => .n,
        46 => .m,
        36, 76 => .enter,
        48 => .tab,
        49 => .space,
        51 => .backspace,
        53 => .escape,
        115 => .home,
        116 => .page_up,
        117 => .delete,
        119 => .end,
        121 => .page_down,
        123 => .left,
        124 => .right,
        125 => .down,
        126 => .up,
        else => .unknown,
    };
}
fn stringValue(value: Id) Id {
    return if (objc.send(bool, value, "isKindOfClass:", .{objc.class("NSAttributedString")})) objc.send(Id, value, "string", .{}) else value;
}
fn stringBytes(value: Id) []const u8 {
    const bytes = objc.send(?[*]const u8, value, "UTF8String", .{}) orelse return "";
    const length = objc.send(usize, value, "lengthOfBytesUsingEncoding:", .{@as(usize, 4)});
    return bytes[0..length];
}
fn insertSimpleText(object: Id, _: Sel, value: Id) callconv(.c) void {
    insertText(object, undefined, value, .{ .location = not_found, .length = 0 });
}
fn insertText(object: Id, _: Sel, value: Id, replacement: Range) callconv(.c) void {
    const s = nativeState(object) orelse return;
    requestText(s, .{ .kind = .insert, .value = stringValue(value), .replacement = replacement });
}
fn setMarkedText(object: Id, _: Sel, value: Id, selection: Range, replacement: Range) callconv(.c) void {
    const s = nativeState(object) orelse return;
    requestText(s, .{ .kind = .mark, .value = stringValue(value), .selection = selection, .replacement = replacement });
}
fn unmarkText(object: Id, _: Sel) callconv(.c) void {
    const s = nativeState(object) orelse return;
    requestText(s, .{ .kind = .unmark });
}
fn requestText(s: *State, request: TextRequest) void {
    if (s.closed) return;
    if (s.awaiting_snapshot) {
        if (s.text_requests.items.len >= 4096) {
            if (callback_error == null) callback_error = error.TextInputQueueFull;
            return;
        }
        var owned = request;
        owned.value = objc.retain(request.value);
        s.text_requests.append(s.allocator, owned) catch |err| {
            objc.release(owned.value);
            if (callback_error == null) callback_error = err;
        };
        return;
    }
    processTextRequest(s, request) catch |err| {
        if (callback_error == null) callback_error = err;
    };
}
fn processTextRequest(s: *State, request: TextRequest) !void {
    if (s.input) |input| {
        if (request.kind == .unmark) {
            if (input.marked != null) {
                s.awaiting_snapshot = true;
                s.emit(.{ .unmark = input.revision });
            }
            return;
        }
        const bytes = stringBytes(request.value);
        const replacement = if (request.replacement.location == not_found) input.marked orelse input.selection else try fromSnapshotRange(input, request.replacement);
        const selection: platform.TextRange = if (request.kind == .mark) try fromNativeRange(bytes, request.selection) else .{ .start = bytes.len, .end = bytes.len };
        const edit: platform.TextEdit = .{ .revision = input.revision, .range = .{ .start = input.base_byte + replacement.start, .end = input.base_byte + replacement.end }, .text = bytes, .selection = selection, .composing = request.kind == .mark };
        try edit.validate(input);
        s.awaiting_snapshot = true;
        s.emit(.{ .edit = edit });
        return;
    }
    // Non-editable views retain the original committed-text channel. A marked
    // preedit remains native until the input method commits it.
    if (request.kind == .mark) {
        const replacement = objc.retain(request.value);
        objc.release(s.marked);
        s.marked = replacement;
    } else {
        objc.release(s.marked);
        s.marked = null;
        if (request.kind == .insert) {
            const bytes = stringBytes(request.value);
            if (bytes.len > 0) s.emit(.{ .text = bytes });
        }
    }
}
fn fromNativeRange(bytes: []const u8, range: Range) !platform.TextRange {
    const total = shaping.byteToUtf16(bytes, bytes.len);
    if (range.location > total or range.length > total - range.location) return error.InvalidTextRange;
    const result: platform.TextRange = .{ .start = shaping.utf16ToByte(bytes, range.location), .end = shaping.utf16ToByte(bytes, range.location + range.length) };
    if (shaping.byteToUtf16(bytes, result.start) != range.location or shaping.byteToUtf16(bytes, result.end) != range.location + range.length) return error.InvalidTextRange;
    return result;
}
fn fromSnapshotRange(input: platform.TextSnapshot, range: Range) !platform.TextRange {
    if (range.location < input.base_utf16) return error.InvalidTextRange;
    return fromNativeRange(input.text, .{ .location = range.location - input.base_utf16, .length = range.length });
}
fn nativeRange(input: platform.TextSnapshot, range: platform.TextRange) Range {
    const start = shaping.byteToUtf16(input.text, range.start);
    return .{ .location = input.base_utf16 + start, .length = shaping.byteToUtf16(input.text, range.end) - start };
}
fn hasMarkedText(object: Id, _: Sel) callconv(.c) bool {
    const s = nativeState(object) orelse return false;
    if (s.input) |input| return input.marked != null;
    return s.marked != null and objc.send(usize, s.marked, "length", .{}) > 0;
}
fn markedRange(object: Id, _: Sel) callconv(.c) Range {
    const s = nativeState(object) orelse return .{ .location = not_found, .length = 0 };
    if (s.input) |input| return if (input.marked) |marked| nativeRange(input, marked) else .{ .location = not_found, .length = 0 };
    const length = if (s.marked != null) objc.send(usize, s.marked, "length", .{}) else 0;
    return .{ .location = if (length > 0) 0 else not_found, .length = length };
}
fn selectedRange(object: Id, _: Sel) callconv(.c) Range {
    const s = nativeState(object) orelse return .{ .location = not_found, .length = 0 };
    const input = s.input orelse return .{ .location = not_found, .length = 0 };
    return nativeRange(input, input.selection);
}
fn validMarkedAttributes(_: Id, _: Sel) callconv(.c) Id {
    return objc.send(Id, objc.class("NSArray"), "array", .{});
}
fn attributedSubstring(object: Id, _: Sel, proposed: Range, actual: ?*Range) callconv(.c) Id {
    if (actual) |range| range.* = .{ .location = not_found, .length = 0 };
    const s = nativeState(object) orelse return null;
    const input = s.input orelse return null;
    const total = shaping.byteToUtf16(input.text, input.text.len);
    if (proposed.location < input.base_utf16 or proposed.location - input.base_utf16 > total) return null;
    const local_start = proposed.location - input.base_utf16;
    const start = shaping.utf16ToByte(input.text, local_start);
    const end = shaping.utf16ToByte(input.text, local_start + @min(proposed.length, total - local_start));
    const range: platform.TextRange = .{ .start = start, .end = end };
    if (actual) |result| result.* = nativeRange(input, range);
    const value = objc.send(Id, objc.send(Id, objc.class("NSAttributedString"), "alloc", .{}), "initWithString:", .{objc.string(input.text[start..end])});
    return objc.send(Id, value, "autorelease", .{});
}
fn characterIndex(object: Id, _: Sel, screen_point: objc.CGPoint) callconv(.c) usize {
    const s = nativeState(object) orelse return not_found;
    const input = s.input orelse return not_found;
    const window_point = objc.send(objc.CGPoint, s.window, "convertPointFromScreen:", .{screen_point});
    const local = objc.send(objc.CGPoint, s.view, "convertPoint:fromView:", .{ window_point, @as(Id, null) });
    const caret_rect = input.caret;
    // The snapshot describes caret geometry, not every line's hit map. Return
    // a character only at that caret rather than inventing document geometry.
    if (local.x < caret_rect.x - 2 or local.x > caret_rect.x + caret_rect.width + 2 or local.y < caret_rect.y or local.y > caret_rect.y + caret_rect.height) return not_found;
    return input.base_utf16 + shaping.byteToUtf16(input.text, input.selection.end);
}
fn firstRect(object: Id, _: Sel, _: Range, actual: ?*Range) callconv(.c) objc.CGRect {
    if (actual) |range| range.* = .{ .location = not_found, .length = 0 };
    const s = nativeState(object) orelse return .{};
    const input = s.input orelse return .{};
    if (actual) |range| range.* = nativeRange(input, .{ .start = input.selection.end, .end = input.selection.end });
    const caret_rect = input.caret;
    const local: objc.CGRect = .{ .origin = .{ .x = caret_rect.x, .y = caret_rect.y }, .size = .{ .width = caret_rect.width, .height = caret_rect.height } };
    const window_rect = objc.send(objc.CGRect, s.view, "convertRect:toView:", .{ local, @as(Id, null) });
    return objc.send(objc.CGRect, s.window, "convertRectToScreen:", .{window_rect});
}
fn command(_: Id, _: Sel, _: Sel) callconv(.c) void {}
fn shouldClose(object: Id, _: Sel, _: Id) callconv(.c) bool {
    const s = nativeState(object) orelse return true;
    if (!s.closed) s.emit(.close);
    return false;
}
fn didResize(object: Id, _: Sel, _: Id) callconv(.c) void {
    const s = nativeState(object) orelse return;
    updateLayer(s);
    s.emit(.{ .resize = size(s) });
}
fn didFocus(object: Id, _: Sel, _: Id) callconv(.c) void {
    const s = nativeState(object) orelse return;
    s.emit(.{ .focus = true });
}
fn didBlur(object: Id, _: Sel, _: Id) callconv(.c) void {
    const s = nativeState(object) orelse return;
    s.emit(.{ .focus = false });
}
