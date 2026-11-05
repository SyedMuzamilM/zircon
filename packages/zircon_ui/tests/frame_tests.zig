const std = @import("std");
const ui = @import("zircon_ui");
const t = std.testing;
test "retiring a temporary large frame releases capacity above the pool budget" {
    var harness = try ui.testing.Harness.init(t.allocator);
    defer harness.deinit();
    const frame = &harness.frames.staging;
    const limit = @TypeOf(frame.*).retained_arena_limit;
    const bytes = try frame.allocator().alloc(u8, limit * 2);
    @memset(bytes, 0);
    try t.expect(frame.arena.queryCapacity() > limit);
    try frame.reset();
    try t.expect(frame.arena.queryCapacity() <= limit);
}
const Counter = struct {
    count: u32 = 0,
    fail_render: bool = false,
    pub fn render(self: *const Counter, builder: *ui.Ui) !ui.Element {
        const count = try builder.textFmt("Count: {d}", .{self.count});
        const button = try builder.key(.{ .string = "increment" }, try builder.button(.{ .label = "Increment", .on_click = builder.onClick(increment) }));
        if (self.fail_render) return error.DeliberateRenderFailure;
        return builder.column(.{ .gap = 12, .padding = ui.Insets.all(24) }, &.{ count, button });
    }
    fn increment(self: *Counter, event: *ui.Event(ui.Click), cx: *ui.Context(Counter)) !void {
        _ = event;
        self.count += 1;
        cx.notify();
    }
    fn setFailure(self: *Counter, cx: *ui.Context(Counter), fail: bool) void {
        self.fail_render = fail;
        cx.notify();
    }
    fn value(self: *const Counter) u32 {
        return self.count;
    }
};
test "const entity rendering builds inspectable frame-owned trees and typed handlers" {
    var harness = try ui.testing.Harness.init(t.allocator);
    defer harness.deinit();
    const counter = try harness.app.createEntity(Counter, .{});
    try harness.render(counter);
    const frame = &harness.frames.committed;
    const root = try frame.get(frame.root.?);
    try t.expect(root.kind == .container);
    try t.expectEqual(@as(usize, 2), root.children.len);
    try t.expectEqualStrings("Count: 0", frame.nodes.items[root.children[0]].kind.text);
    const button = frame.nodes.items[root.children[1]].kind.button;
    var event: ui.Event(ui.Click) = .{ .data = .{} };
    try button.on_click.?.dispatch(&harness.app, &event);
    try t.expectEqual(@as(u32, 1), try harness.app.read(counter, Counter.value, .{}));
    try harness.render(counter);
    try t.expectEqualStrings("Count: 1", harness.frames.committed.nodes.items[0].kind.text);
}
test "failed staging keeps the committed tree and handler alive" {
    var h = try ui.testing.Harness.init(t.allocator);
    defer h.deinit();
    const counter = try h.app.createEntity(Counter, .{});
    try h.render(counter);
    const root = h.frames.committed.root.?;
    const epoch = root.frame_epoch;
    const handler = h.frames.committed.nodes.items[1].kind.button.on_click.?;
    try h.app.update(counter, Counter.setFailure, .{true});
    try t.expectError(error.DeliberateRenderFailure, h.render(counter));
    try t.expectEqual(epoch, h.frames.committed.epoch);
    _ = try h.frames.committed.get(root);
    var event: ui.Event(ui.Click) = .{ .data = .{} };
    try handler.dispatch(&h.app, &event);
    try t.expectEqual(@as(u32, 1), try h.app.read(counter, Counter.value, .{}));
}
test "element epochs reject retired and foreign frame handles" {
    var h = try ui.testing.Harness.init(t.allocator);
    defer h.deinit();
    const counter = try h.app.createEntity(Counter, .{});
    try h.render(counter);
    const old = h.frames.committed.root.?;
    try t.expectError(error.InvalidFrame, h.frames.staging.get(old));
    try h.render(counter);
    try t.expectError(error.InvalidFrame, h.frames.committed.get(old));
    const old_arena = &h.frames.staging;
    try old_arena.reset();
    try t.expectError(error.InvalidFrame, old_arena.get(old));
}
test "active dispatch pins the committed frame and prevents replacement" {
    var h = try ui.testing.Harness.init(t.allocator);
    defer h.deinit();
    const counter = try h.app.createEntity(Counter, .{});
    try h.render(counter);
    try h.frames.beginDispatch();
    defer h.frames.endDispatch();
    try t.expectError(error.DispatchActive, h.render(counter));
}
test "tree copies text, logical keys and child handles before caller memory changes" {
    var h = try ui.testing.Harness.init(t.allocator);
    defer h.deinit();
    const entity = try h.app.createEntity(Counter, .{});
    var builder: ui.Ui = .{ .frame = try h.frames.begin(), .owner = entity.token() };
    var text = [_]u8{ 'h', 'e', 'l', 'l', 'o' };
    const node = try builder.key(.{ .string = &text }, try builder.text(&text));
    var children = [_]ui.Element{node};
    const parent = try builder.column(.{}, &children);
    @memset(&text, 'x');
    children[0] = parent;
    const stored = try builder.frame.get(node);
    try t.expectEqualStrings("hello", stored.kind.text);
    try t.expectEqualStrings("hello", stored.key.?.string);
    try t.expectEqual(node.index, (try builder.frame.get(parent)).children[0]);
}
test "tree rejects multiple parents duplicate children and duplicate keys" {
    var h = try ui.testing.Harness.init(t.allocator);
    defer h.deinit();
    const entity = try h.app.createEntity(Counter, .{});
    var builder: ui.Ui = .{ .frame = try h.frames.begin(), .owner = entity.token() };
    const node = try builder.text("child");
    try t.expectError(error.DuplicateChild, builder.column(.{}, &.{ node, node }));
    _ = try builder.column(.{}, &.{node});
    try t.expectError(error.ElementAlreadyParented, builder.column(.{}, &.{node}));
    const a = try builder.key(.{ .number = 7 }, try builder.text("a"));
    const b = try builder.key(.{ .number = 7 }, try builder.text("b"));
    const root = try builder.column(.{}, &.{ a, b });
    try t.expectError(error.DuplicateElementKey, h.frames.commit(root));
}
test "identical keys in separate keyed scopes are legal and string/number keys differ" {
    var h = try ui.testing.Harness.init(t.allocator);
    defer h.deinit();
    const entity = try h.app.createEntity(Counter, .{});
    var builder: ui.Ui = .{ .frame = try h.frames.begin(), .owner = entity.token() };
    const a = try builder.key(.{ .number = 1 }, try builder.text("a"));
    const left = try builder.key(.{ .string = "left" }, try builder.column(.{}, &.{a}));
    const b = try builder.key(.{ .number = 1 }, try builder.text("b"));
    const right = try builder.key(.{ .string = "right" }, try builder.column(.{}, &.{b}));
    try h.frames.commit(try builder.row(.{}, &.{ left, right }));
}
test "frame cleanup hooks run once in reverse order on retirement and failure" {
    var h = try ui.testing.Harness.init(t.allocator);
    defer h.deinit();
    var log: std.ArrayList(u8) = .empty;
    defer log.deinit(t.allocator);
    try log.ensureTotalCapacity(t.allocator, 3);
    const Resource = struct {
        value: u8,
        log: *std.ArrayList(u8),
        fn cleanup(raw: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.log.appendAssumeCapacity(self.value);
        }
    };
    var a: Resource = .{ .value = 'a', .log = &log };
    var b: Resource = .{ .value = 'b', .log = &log };
    const staging = try h.frames.begin();
    try staging.cleanup(.{ .object = &a, .destroy = Resource.cleanup });
    try staging.cleanup(.{ .object = &b, .destroy = Resource.cleanup });
    staging.discard();
    try t.expectEqualStrings("ba", log.items);
    staging.discard();
    try t.expectEqualStrings("ba", log.items);
}
test "a committed frame's typed handler cannot access a destroyed entity" {
    var h = try ui.testing.Harness.init(t.allocator);
    defer h.deinit();
    const entity = try h.app.createEntity(Counter, .{});
    try h.render(entity);
    const handler = h.frames.committed.nodes.items[1].kind.button.on_click.?;
    try h.app.destroyEntity(entity);
    var event: ui.Event(ui.Click) = .{ .data = .{} };
    try t.expectError(error.EntityNotFound, handler.dispatch(&h.app, &event));
}
test "invalid dimensions and malformed UTF8 fail at the builder seam" {
    var h = try ui.testing.Harness.init(t.allocator);
    defer h.deinit();
    const entity = try h.app.createEntity(Counter, .{});
    var builder: ui.Ui = .{ .frame = try h.frames.begin(), .owner = entity.token() };
    try t.expectError(error.InvalidStyle, builder.column(.{ .gap = -1 }, &.{}));
    try t.expectError(error.InvalidStyle, builder.column(.{ .width = .{ .px = std.math.nan(f32) } }, &.{}));
    try t.expectError(error.InvalidUtf8, builder.text("\xff"));
}
test "frame construction allocation failures clean all owned storage" {
    try t.checkAllAllocationFailures(t.allocator, allocationCase, .{});
}
fn allocationCase(a: std.mem.Allocator) !void {
    var h = try ui.testing.Harness.init(a);
    defer h.deinit();
    const entity = try h.app.createEntity(Counter, .{});
    try h.render(entity);
}

test "allocation failure in a new staging arena preserves the previous successful frame" {
    var failure = std.testing.FailingAllocator.init(t.allocator, .{});
    var h = try ui.testing.Harness.init(failure.allocator());
    defer h.deinit();
    const entity = try h.app.createEntity(Counter, .{});
    try h.render(entity);
    const committed = h.frames.committed.root.?;
    failure.fail_index = failure.alloc_index;
    try t.expectError(error.OutOfMemory, h.render(entity));
    try t.expectEqual(committed.frame_epoch, h.frames.committed.epoch);
    _ = try h.frames.committed.get(committed);
}
