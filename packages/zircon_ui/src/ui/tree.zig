//! A frame owns nodes, strings, child lists, handlers and cleanup hooks.
//! Two frames allow failed staging work to leave the committed tree untouched.
const std = @import("std");
const animation_timeline = @import("../animation/timeline.zig");
const app_app = @import("../app/app.zig");
const entity_entity = @import("../entity/entity.zig");
const graphics_scene = @import("../graphics/scene.zig");
const geometry = @import("../layout/geometry.zig");
const interface = @import("../platform/interface.zig");
const adapter = @import("adapter.zig");
const custom_module = @import("custom.zig");
const elements = @import("element.zig");
const style_module = @import("style.zig");
const Style = style_module.Style;
const ClickHandler = adapter.ClickHandler;
var next_epoch = std.atomic.Value(u64).init(1);
pub const Node = struct {
    parent: ?u32 = null,
    children: []const u32 = &.{},
    style: Style = .{},
    key: ?elements.Key = null,
    on_input: ?adapter.InputHandler = null,
    on_capture: ?adapter.InputHandler = null,
    tooltip: ?[]const u8 = null,
    tooltip_colors: ?[3]geometry.Color = null,
    focusable: bool = false,
    autofocus: bool = false,
    focus_request: u64 = 0,
    modal: bool = false,
    drag_region: bool = false,
    cache: bool = false,
    kind: union(enum) { container, custom: custom_module.Custom, text: []const u8, button: struct { label: []const u8, on_click: ?ClickHandler } },
};
pub const Cleanup = struct { object: *anyopaque, destroy: *const fn (*anyopaque) void };
pub const Dependency = struct { entity: entity_entity.Token, version: u64 };
pub const Frame = struct {
    /// Budget for an arena after retirement. Active frames may exceed it; a
    /// temporary large text/selection frame must not permanently grow the pool.
    pub const retained_arena_limit = 8 * 1024 * 1024;
    arena: std.heap.ArenaAllocator,
    nodes: std.ArrayList(Node) = .empty,
    cleanups: std.ArrayList(Cleanup) = .empty,
    dependencies: std.ArrayList(Dependency) = .empty,
    app: ?*app_app.App = null,
    epoch: u64,
    root: ?elements.Element = null,
    retiring: bool = false,
    fluent_error: ?anyerror = null,
    bounds: []const geometry.Rect = &.{},
    scene: graphics_scene.Frame = .{ .items = &.{}, .background = .black, .animations = &.{} },
    timeline: ?*animation_timeline.Timeline = null,
    time: f64 = 0,
    next_deadline: ?f64 = null,
    viewport: geometry.Size = .{ .width = 0, .height = 0 },
    text_input: ?interface.TextSnapshot = null,
    accessibility: std.ArrayList(interface.AccessibilityTree.Node) = .empty,
    focused_node: ?u32 = null,
    retained_focus: bool = false,
    hovered_node: ?u32 = null,
    hover_started: f64 = 0,
    tooltip_delay: f64 = 0.4,
    tooltips_enabled: bool = true,
    pub fn init(a: std.mem.Allocator) !Frame {
        return .{ .arena = .init(a), .epoch = try epoch() };
    }
    pub fn deinit(frame: *Frame) void {
        frame.retire();
        frame.arena.deinit();
        frame.* = undefined;
    }
    pub fn reset(frame: *Frame) !void {
        const next = try epoch();
        frame.retire();
        frame.fluent_error = null;
        _ = frame.arena.reset(.{ .retain_with_limit = retained_arena_limit });
        frame.nodes = .empty;
        frame.cleanups = .empty;
        frame.dependencies = .empty;
        frame.app = null;
        frame.root = null;
        frame.epoch = next;
        frame.retiring = false;
        frame.bounds = &.{};
        frame.scene = .{ .items = &.{}, .background = .black, .animations = &.{} };
        frame.timeline = null;
        frame.time = 0;
        frame.text_input = null;
        frame.accessibility = .empty;
        frame.focused_node = null;
        frame.retained_focus = false;
        frame.hovered_node = null;
        frame.hover_started = 0;
        frame.tooltip_delay = 0.4;
        frame.tooltips_enabled = true;
        frame.next_deadline = null;
    }
    pub fn discard(frame: *Frame) void {
        frame.retire();
        _ = frame.arena.reset(.retain_capacity);
        frame.nodes = .empty;
        frame.cleanups = .empty;
        frame.dependencies = .empty;
        frame.app = null;
        frame.root = null;
        frame.bounds = &.{};
        frame.scene = .{ .items = &.{}, .background = .black, .animations = &.{} };
        frame.timeline = null;
        frame.time = 0;
        frame.text_input = null;
        frame.accessibility = .empty;
        frame.focused_node = null;
        frame.retained_focus = false;
        frame.next_deadline = null;
    }
    fn retire(frame: *Frame) void {
        frame.retiring = true;
        var n = frame.cleanups.items.len;
        while (n > 0) {
            n -= 1;
            const hook = frame.cleanups.items[n];
            hook.destroy(hook.object);
        }
        frame.cleanups.clearRetainingCapacity();
    }
    pub fn allocator(frame: *Frame) std.mem.Allocator {
        return frame.arena.allocator();
    }
    pub fn cleanup(frame: *Frame, entry: Cleanup) !void {
        if (frame.retiring) return error.InvalidFrame;
        try frame.cleanups.append(frame.allocator(), entry);
    }
    pub fn watch(frame: *Frame, token: entity_entity.Token, version: u64) !void {
        for (frame.dependencies.items) |*dependency| if (std.meta.eql(dependency.entity, token)) {
            dependency.version = version;
            return;
        };
        try frame.dependencies.append(frame.allocator(), .{ .entity = token, .version = version });
    }
    pub fn get(frame: *const Frame, handle: elements.Element) !*const Node {
        if (frame.retiring or handle.frame_epoch != frame.epoch) return error.InvalidFrame;
        if (handle.index >= frame.nodes.items.len) return error.InvalidElement;
        return &frame.nodes.items[handle.index];
    }
    pub fn append(frame: *Frame, node: Node) !elements.Element {
        if (frame.retiring) return error.InvalidFrame;
        if (frame.nodes.items.len >= std.math.maxInt(u32)) return error.ElementCapacityExceeded;
        try frame.nodes.append(frame.allocator(), node);
        return .{ .index = @intCast(frame.nodes.items.len - 1), .frame_epoch = frame.epoch };
    }
    pub fn setRoot(frame: *Frame, root: elements.Element) !void {
        if (frame.fluent_error) |err| return err;
        if ((try frame.get(root)).parent != null) return error.InvalidRoot;
        try frame.validateKeys();
        frame.root = root;
    }
    pub fn prepareChildren(frame: *Frame, children: []const elements.Element) ![]const u32 {
        for (children, 0..) |child, i| {
            if ((try frame.get(child)).parent != null) return error.ElementAlreadyParented;
            for (children[0..i]) |previous| if (previous.index == child.index) return error.DuplicateChild;
        }
        const indices = try frame.allocator().alloc(u32, children.len);
        for (children, 0..) |child, i| indices[i] = child.index;
        return indices;
    }
    fn keyScope(frame: *const Frame, index: u32) ?u32 {
        var parent = frame.nodes.items[index].parent;
        while (parent) |p| {
            if (frame.nodes.items[p].key != null) return p;
            parent = frame.nodes.items[p].parent;
        }
        return null;
    }
    fn validateKeys(frame: *const Frame) !void {
        for (frame.nodes.items, 0..) |node, i| if (node.key) |key| {
            for (frame.nodes.items[0..i], 0..) |other, j| if (other.key) |other_key| if (keysEqual(key, other_key) and frame.keyScope(@intCast(i)) == frame.keyScope(@intCast(j))) return error.DuplicateElementKey;
        };
    }
};
pub const Frames = struct {
    committed: Frame,
    staging: Frame,
    dispatch_depth: usize = 0,
    pub fn init(a: std.mem.Allocator) !Frames {
        var first = try Frame.init(a);
        errdefer first.deinit();
        return .{ .committed = first, .staging = try Frame.init(a) };
    }
    pub fn deinit(frames: *Frames) void {
        std.debug.assert(frames.dispatch_depth == 0);
        frames.staging.deinit();
        frames.committed.deinit();
    }
    pub fn begin(frames: *Frames) !*Frame {
        if (frames.dispatch_depth != 0) return error.DispatchActive;
        try frames.staging.reset();
        return &frames.staging;
    }
    pub fn commit(frames: *Frames, root: elements.Element) !void {
        if (frames.dispatch_depth != 0) return error.DispatchActive;
        try frames.staging.setRoot(root);
        frames.commitPrepared();
    }
    /// Validation and all fallible preparation must precede native submission.
    pub fn commitPrepared(frames: *Frames) void {
        std.debug.assert(frames.dispatch_depth == 0 and frames.staging.root != null);
        std.mem.swap(Frame, &frames.committed, &frames.staging);
    }
    pub fn beginDispatch(frames: *Frames) !void {
        if (frames.committed.root == null) return error.NoCommittedFrame;
        frames.dispatch_depth += 1;
    }
    pub fn endDispatch(frames: *Frames) void {
        std.debug.assert(frames.dispatch_depth > 0);
        frames.dispatch_depth -= 1;
    }
};
pub fn keysEqual(a: elements.Key, b: elements.Key) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .string => |s| std.mem.eql(u8, s, b.string),
        .number => |n| n == b.number,
    };
}
fn epoch() !u64 {
    var current = next_epoch.load(.monotonic);
    while (true) {
        if (current == std.math.maxInt(u64)) return error.FrameEpochExhausted;
        if (next_epoch.cmpxchgWeak(current, current + 1, .monotonic, .monotonic)) |actual| current = actual else return current;
    }
}
