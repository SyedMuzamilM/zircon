//! Stable window ownership and a single tree/layout/scene transaction. Both
//! native and in-memory adapters drive this runtime and its committed handlers.
const std = @import("std");
const runtime = @import("app.zig");
const entity = @import("../entity/entity.zig");
const tree = @import("../ui/tree.zig");
const builder = @import("../ui/ui.zig");
const adapter = @import("../ui/adapter.zig");
const events = @import("../event/event.zig");
const platform = @import("../platform/interface.zig");
const g = @import("../layout/geometry.zig");
const flex = @import("../layout/flex.zig");
const Painter = @import("../graphics/painter.zig").Painter;
const native_enabled = @import("zircon_options").native;
const backend = if (native_enabled) @import("../platform/macos/window.zig") else @import("../platform/headless.zig");
pub const Handle = struct { app_id: u32, slot: u32, generation: u32 = 1 };
pub const Options = platform.WindowOptions;
pub const Window = struct {
    parent: ?Handle = null,
    app: runtime.App,
    allocator: std.mem.Allocator,
    scope: @import("../entity/scope.zig").Scope,
    root: entity.Token,
    render_root: *const fn (*runtime.App, entity.Token, *tree.Frame) anyerror!@import("../ui/element.zig").Element,
    frames: tree.Frames,
    surface: ?platform.Surface = null,
    dimensions: g.Size,
    background: g.Color,
    focus: ?u32 = null,
    restore_focus: ?u32 = null,
    capture: ?u32 = null,
    pressed: ?u32 = null,
    pointer_position: ?g.Point = null,
    dirty: bool = true,
    closed: bool = false,
    active: bool = true,
    pending_native_focus: ?bool = null,
    pending_native_blur: bool = false,
    frame_count: u64 = 0,
    animations: @import("../animation/timeline.zig").Timeline,
    time: f64 = 0,
    animating: bool = false,
    deadline: ?f64 = null,
    pub fn create(app: runtime.App, a: std.mem.Allocator, comptime T: type, options: Options, value: T) !*Window {
        comptime adapter.requireView(T);
        if (!std.math.isFinite(options.width) or !std.math.isFinite(options.height) or options.width <= 0 or options.height <= 0 or options.width > 32768 or options.height > 32768) return error.InvalidWindowSize;
        if (!std.unicode.utf8ValidateSlice(options.title)) return error.InvalidUtf8;
        var owner = app;
        const scope = try owner.createScope();
        errdefer owner.destroyScope(scope) catch {};
        const Render = struct {
            fn call(target: *runtime.App, token: entity.Token, frame: *tree.Frame) !@import("../ui/element.zig").Element {
                return builder.render(target, entity.typed(T, token), frame);
            }
        };
        const window = try a.create(Window);
        errdefer a.destroy(window);
        window.* = .{ .app = app, .allocator = a, .scope = scope, .root = .{ .app_id = scope.app_id, .slot = std.math.maxInt(u32), .generation = 0 }, .render_root = Render.call, .frames = try tree.Frames.init(a), .dimensions = .{ .width = options.width, .height = options.height }, .background = options.background, .animations = .init(a) };
        errdefer window.frames.deinit();
        window.surface = try backend.open(a, options, .{ .context = window, .event = receive, .drag_region = dragRegion });
        errdefer window.surface.?.deinit();
        window.dimensions = window.surface.?.size();
        // Ownership of value transfers only here, after native allocation. No
        // further fallible work may follow a successfully created root entity.
        window.root = (try owner.createInScope(scope, T, value)).token();
        return window;
    }
    pub fn deinit(w: *Window) void {
        w.closed = true;
        if (w.surface) |surface| surface.deinit();
        w.frames.deinit();
        w.animations.deinit();
        w.app.destroyScope(w.scope) catch {};
        w.allocator.destroy(w);
    }
    pub fn draw(w: *Window) !bool {
        if (w.closed or !w.dirty) return false;
        const staging = try w.frames.begin();
        errdefer staging.discard();
        try w.animations.beginFrame(w.time);
        errdefer w.animations.discardFrame();
        staging.timeline = &w.animations;
        staging.time = w.time;
        staging.viewport = w.dimensions;
        const root = try w.render_root(&w.app, w.root, staging);
        try staging.setRoot(root);
        const surface = w.surface.?;
        const metrics = surface.measurer();
        const layout = try flex.calculate(staging.allocator(), staging, root, .{ .viewport = w.dimensions }, metrics);
        staging.bounds = layout.bounds;
        if (w.pointer_position) |position| staging.hovered_node = hitTest(staging, modalRoot(staging) orelse root.index, position, .{ .width = w.dimensions.width, .height = w.dimensions.height });
        var next_focus = reconcile(&w.frames.committed, staging, w.focus) orelse nextFocus(staging, null, false);
        var next_restore = reconcile(&w.frames.committed, staging, w.restore_focus);
        if (modalRoot(&w.frames.committed) == null and modalRoot(staging) != null) next_restore = reconcile(&w.frames.committed, staging, w.focus);
        if (modalRoot(&w.frames.committed) != null and modalRoot(staging) == null) {
            next_focus = next_restore orelse next_focus;
            next_restore = null;
        }
        if (modalRoot(staging)) |modal| if (next_focus) |focused| {
            if (!descendant(staging, focused, modal)) next_focus = nextFocus(staging, null, false);
        };
        for (staging.nodes.items, 0..) |value, i| {
            if ((!value.autofocus and value.focus_request == 0) or !value.focusable) continue;
            if (modalRoot(staging)) |modal| if (!descendant(staging, @intCast(i), modal)) continue;
            if (reconcile(staging, &w.frames.committed, @intCast(i))) |old| {
                if (value.focus_request != 0 and value.focus_request != w.frames.committed.nodes.items[old].focus_request) next_focus = @intCast(i);
            } else next_focus = @intCast(i);
        }
        staging.focused_node = if (w.active) next_focus else null;
        var painter = try Painter.init(staging.allocator(), .{ .width = w.dimensions.width, .height = w.dimensions.height });
        try @import("../graphics/tree_paint.zig").paint(staging, &layout, &painter, metrics);
        staging.scene = try painter.finish(w.background);
        if (!try surface.present(staging.scene)) {
            staging.discard();
            w.animations.discardFrame();
            return false;
        }
        // All validation and submission encoding succeeded. No fallible work
        // remains between target reconciliation and the CPU generation swap.
        w.focus = next_focus;
        w.restore_focus = next_restore;
        w.capture = reconcile(&w.frames.committed, staging, w.capture);
        if (modalRoot(staging)) |modal| if (w.capture) |captured| {
            if (!descendant(staging, captured, modal)) w.capture = null;
        };
        w.pressed = reconcile(&w.frames.committed, staging, w.pressed);
        w.frames.commitPrepared();
        surface.setTextInput(w.frames.committed.text_input);
        w.animations.commitFrame();
        w.animating = w.animations.active(w.time);
        w.deadline = w.frames.committed.next_deadline;
        w.dirty = false;
        w.frame_count += 1;
        return true;
    }
    pub fn snapshot(w: *Window, path: []const u8) !void {
        _ = try w.draw();
        if (w.frames.committed.root == null) return error.NoCommittedFrame;
        try w.surface.?.snapshot(w.frames.committed.scene, path);
    }
    fn receive(raw: *anyopaque, input: platform.Input) !void {
        const w: *Window = @ptrCast(@alignCast(raw));
        if (input == .focus and w.app.transactionActive()) {
            w.pending_native_focus = input.focus;
            w.pending_native_blur = w.pending_native_blur or !input.focus;
            w.dirty = true;
            wake();
            return;
        }
        try w.dispatch(input);
    }
    pub fn flushNativeFocus(w: *Window) !void {
        const focused = w.pending_native_focus orelse return;
        w.pending_native_focus = null;
        const blurred = w.pending_native_blur;
        w.pending_native_blur = false;
        if (blurred) try w.dispatch(.{ .focus = false });
        if (focused or !blurred) try w.dispatch(.{ .focus = focused });
    }
    fn dragRegion(raw: *anyopaque, point: g.Point) bool {
        const w: *Window = @ptrCast(@alignCast(raw));
        const frame = &w.frames.committed;
        if (w.closed or frame.root == null or modalRoot(frame) != null) return false;
        var current: ?u32 = hitTest(frame, frame.root.?.index, point, .{ .width = w.dimensions.width, .height = w.dimensions.height });
        while (current) |i| : (current = frame.nodes.items[i].parent) {
            const node = frame.nodes.items[i];
            if (node.on_input != null or node.focusable or node.kind == .button) return false;
            if (node.drag_region) return true;
        }
        return false;
    }
    pub fn dispatch(w: *Window, input: platform.Input) !void {
        if (w.closed) return;
        errdefer w.dirty = true;
        switch (input) {
            .close => if (w.frames.committed.root == null) {
                w.acceptClose();
                return;
            },
            .resize => |size| {
                if (!std.math.isFinite(size.width) or !std.math.isFinite(size.height) or size.width < 0 or size.height < 0) return error.InvalidWindowSize;
                w.dimensions = size;
                w.dirty = true;
                return;
            },
            .focus => |focused| {
                if (w.active != focused) w.dirty = true;
                w.active = focused;
                if (!focused) {
                    w.capture = null;
                    w.pressed = null;
                    w.pointer_position = null;
                }
            },
            else => {},
        }
        if (w.frames.committed.root == null) return;
        try w.frames.beginDispatch();
        defer w.frames.endDispatch();
        try w.app.beginTransaction();
        defer w.app.endTransaction();
        const frame = &w.frames.committed;
        if (input == .edit or input == .unmark) if (w.focus != frame.focused_node) return error.StaleTextSnapshot;
        if (input == .edit) try input.edit.validate(frame.text_input orelse return error.NoTextInputTarget);
        if (input == .unmark) if (frame.text_input) |snapshot_value| {
            if (snapshot_value.revision != input.unmark) return error.StaleTextSnapshot;
        } else return error.NoTextInputTarget;
        const point: ?g.Point = switch (input) {
            .pointer_down, .pointer_up, .pointer_move => |p| p.position,
            .scroll => |s| s.position,
            else => null,
        };
        const route_root = modalRoot(frame) orelse frame.root.?.index;
        const hit = if (point) |p| hitTest(frame, route_root, p, .{ .width = w.dimensions.width, .height = w.dimensions.height }) else null;
        if (point) |position| {
            w.pointer_position = position;
            if (frame.hovered_node != hit) w.dirty = true;
        }
        const target = if (input == .close) frame.root.?.index else if (point != null) w.capture orelse hit orelse route_root else w.focus orelse route_root;
        if (input == .pointer_down) {
            w.pressed = buttonTarget(frame, hit);
            var candidate: ?u32 = target;
            while (candidate) |i| : (candidate = frame.nodes.items[i].parent) if (frame.nodes.items[i].focusable) {
                if (w.focus != i) w.dirty = true;
                w.focus = i;
                break;
            };
        }
        var path: [129]u32 = undefined;
        var count: usize = 0;
        var current: ?u32 = target;
        while (current) |i| : (current = frame.nodes.items[i].parent) {
            if (count == path.len) return error.EventDepthExceeded;
            path[count] = i;
            count += 1;
        }
        var event: events.Event(events.Input) = .{ .data = input, ._surface = w.surface, ._window_size = w.dimensions };
        var cursor = count;
        while (cursor > 0) {
            cursor -= 1;
            const i = path[cursor];
            event.phase = .capture;
            event.bounds = frame.bounds[i];
            if (frame.nodes.items[i].on_capture) |handler| try handler.dispatch(&w.app, &event);
            w.requests(&event, i);
            if (event.stopped) break;
        }
        if (!event.stopped) for (path[0..count], 0..) |i, n| {
            event.phase = if (n == 0) .target else .bubble;
            event.bounds = frame.bounds[i];
            if (frame.nodes.items[i].on_input) |handler| try handler.dispatch(&w.app, &event);
            w.requests(&event, i);
            if (event.stopped) break;
        };
        if (!event.prevented) switch (input) {
            .close => w.acceptClose(),
            .pointer_up => |p| {
                const button = buttonTarget(frame, hit);
                if (p.button == .primary and button != null and w.pressed == button) try w.click(button.?, p.position);
            },
            .key_down => |key| {
                if (key.key == .tab) {
                    w.focus = nextFocus(frame, w.focus, key.modifiers.shift);
                    w.dirty = true;
                }
                if (key.key == .enter or key.key == .space) if (w.focus) |i| try w.click(i, .{});
            },
            else => {},
        };
        if (input == .pointer_up) {
            w.capture = null;
            w.pressed = null;
        }
    }
    fn acceptClose(w: *Window) void {
        w.closed = true;
        if (w.surface) |surface| surface.acceptClose();
    }
    fn requests(w: *Window, e: *events.Event(events.Input), index: u32) void {
        if (e.focus_requested) {
            if (w.focus != index) w.dirty = true;
            w.focus = index;
            e.focus_requested = false;
        }
        if (e.capture_requested) {
            w.capture = index;
            e.capture_requested = false;
        }
        if (e.release_requested) {
            w.capture = null;
            e.release_requested = false;
        }
    }
    fn click(w: *Window, index: u32, point: g.Point) !void {
        const node = w.frames.committed.nodes.items[index];
        if (node.kind == .button) if (node.kind.button.on_click) |handler| {
            var e: events.Event(events.Click) = .{ .data = .{ .position = point }, .bounds = w.frames.committed.bounds[index], ._surface = w.surface, ._window_size = w.dimensions };
            try handler.dispatch(&w.app, &e);
        };
    }
};
fn buttonTarget(frame: *const tree.Frame, hit: ?u32) ?u32 {
    var current = hit;
    while (current) |index| : (current = frame.nodes.items[index].parent) if (frame.nodes.items[index].kind == .button) return index;
    return null;
}
fn contains(r: g.Rect, p: g.Point) bool {
    return p.x >= r.x and p.y >= r.y and p.x < r.x + r.width and p.y < r.y + r.height;
}
fn hitTest(frame: *const tree.Frame, index: u32, point: g.Point, inherited_clip: g.Rect) ?u32 {
    const node = frame.nodes.items[index];
    const bounds = frame.bounds[index];
    const clip = if (node.style.overflow == .hidden) inherited_clip.intersection(bounds) else inherited_clip;
    if (!contains(clip, point)) return null;
    var n = node.children.len;
    while (n > 0) {
        n -= 1;
        if (hitTest(frame, node.children[n], point, clip)) |found| return found;
    }
    if (contains(bounds, point)) return index;
    return null;
}
fn pathEqual(a: *const tree.Frame, ai: u32, b: *const tree.Frame, bi: u32) bool {
    const an = a.nodes.items[ai];
    const bn = b.nodes.items[bi];
    if (an.key) |key| {
        if (bn.key == null or !tree.keysEqual(key, bn.key.?)) return false;
    } else {
        if (bn.key != null or ordinal(a, ai) != ordinal(b, bi)) return false;
    }
    if (an.parent) |ap| {
        if (bn.parent) |bp| return pathEqual(a, ap, b, bp);
        return false;
    }
    return bn.parent == null;
}
fn ordinal(frame: *const tree.Frame, index: u32) usize {
    if (frame.nodes.items[index].parent) |parent| for (frame.nodes.items[parent].children, 0..) |child, n| {
        if (child == index) return n;
    };
    return 0;
}
fn reconcile(old: *const tree.Frame, new: *const tree.Frame, index: ?u32) ?u32 {
    const previous = index orelse return null;
    for (new.nodes.items, 0..) |_, i| if (pathEqual(old, previous, new, @intCast(i))) return @intCast(i);
    return null;
}
fn nextFocus(frame: *const tree.Frame, current: ?u32, reverse: bool) ?u32 {
    var order: [1024]u32 = undefined;
    var count: usize = 0;
    focusOrder(frame, modalRoot(frame) orelse frame.root.?.index, &order, &count);
    if (count == 0) return null;
    if (current) |c| for (order[0..count], 0..) |i, n| if (i == c) return order[if (reverse) (n + count - 1) % count else (n + 1) % count];
    return order[if (reverse) count - 1 else 0];
}
fn modalRoot(frame: *const tree.Frame) ?u32 {
    var result: ?u32 = null;
    if (frame.root) |root| findModal(frame, root.index, &result);
    return result;
}
fn findModal(frame: *const tree.Frame, index: u32, result: *?u32) void {
    if (frame.nodes.items[index].modal) result.* = index;
    for (frame.nodes.items[index].children) |child| findModal(frame, child, result);
}
fn descendant(frame: *const tree.Frame, index: u32, ancestor: u32) bool {
    var current: ?u32 = index;
    while (current) |i| : (current = frame.nodes.items[i].parent) if (i == ancestor) return true;
    return false;
}
fn focusOrder(frame: *const tree.Frame, index: u32, order: []u32, count: *usize) void {
    if (frame.nodes.items[index].focusable and count.* < order.len) {
        order[count.*] = index;
        count.* += 1;
    }
    for (frame.nodes.items[index].children) |child| focusOrder(frame, child, order, count);
}
pub fn pump(timeout: f64) !void {
    if (native_enabled) try backend.pump(timeout) else return error.NativeNotEnabled;
}
pub fn wake() void {
    if (native_enabled) backend.wake();
}
pub fn now() f64 {
    return if (native_enabled) backend.now() else 0;
}
