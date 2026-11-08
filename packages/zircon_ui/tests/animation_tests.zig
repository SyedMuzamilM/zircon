const std = @import("std");
const zircon_ui = @import("zircon_ui");
const animation = zircon_ui.animation;
const t = std.testing;
const Timeline = animation.Timeline;
const Transition = animation.Transition;

fn frame(timeline: *Timeline, now: f64, target: f32, transition: Transition) !f32 {
    try timeline.beginFrame(now);
    errdefer timeline.discardFrame();
    const value = try timeline.sample(1, target, transition, now);
    timeline.commitFrame();
    return value;
}
const linear: Transition = .{ .tween = .{ .duration = 1, .easing = .linear } };

test "tweens sample an injected clock and stop scheduling at their target" {
    var timeline = Timeline.init(t.allocator);
    defer timeline.deinit();
    try t.expectEqual(@as(f32, 10), try frame(&timeline, 0, 10, linear));
    try t.expect(!timeline.active(0));
    try t.expectEqual(@as(f32, 10), try frame(&timeline, 1, 30, linear));
    try t.expect(timeline.active(1));
    try t.expectEqual(@as(f32, 15), try frame(&timeline, 1.25, 30, linear));
    try t.expectEqual(@as(f32, 30), try frame(&timeline, 2, 30, linear));
    try t.expect(!timeline.active(2));
}

test "easing and zero duration have observable deterministic values" {
    var timeline = Timeline.init(t.allocator);
    defer timeline.deinit();
    const eased: Transition = .{ .tween = .{ .duration = 1, .easing = .ease_in } };
    _ = try frame(&timeline, 0, 0, eased);
    _ = try frame(&timeline, 0, 8, eased);
    try t.expectApproxEqAbs(@as(f32, 1), try frame(&timeline, 0.5, 8, eased), 0.0001);
    try t.expectEqual(@as(f32, 12), try frame(&timeline, 1, 12, .{ .tween = .{ .duration = 0 } }));
    try t.expect(!timeline.active(1));
}

test "interrupted tween starts at its sampled position without a jump" {
    var timeline = Timeline.init(t.allocator);
    defer timeline.deinit();
    _ = try frame(&timeline, 0, 0, linear);
    _ = try frame(&timeline, 0, 100, linear);
    try t.expectEqual(@as(f32, 40), try frame(&timeline, 0.4, 200, linear));
    try t.expectEqual(@as(f32, 120), try frame(&timeline, 0.9, 200, linear));
}

test "springs converge for under critical and over damping independently of frame count" {
    for ([_]f64{ 5, 20, 40 }) |damping| {
        var sparse = Timeline.init(t.allocator);
        defer sparse.deinit();
        var dense = Timeline.init(t.allocator);
        defer dense.deinit();
        const spring: Transition = .{ .spring = .{ .stiffness = 100, .damping = damping } };
        _ = try frame(&sparse, 0, 0, spring);
        _ = try frame(&dense, 0, 0, spring);
        _ = try frame(&sparse, 0, 10, spring);
        _ = try frame(&dense, 0, 10, spring);
        for (1..101) |step| _ = try frame(&dense, @as(f64, @floatFromInt(step)) / 100, 10, spring);
        const direct = try frame(&sparse, 1, 10, spring);
        try t.expectApproxEqAbs(direct, try frame(&dense, 1, 10, spring), 0.00001);
        try t.expectEqual(@as(f32, 10), try frame(&sparse, 20, 10, spring));
        try t.expect(!sparse.active(20));
    }
}

test "spring interruption preserves velocity at the new target" {
    var timeline = Timeline.init(t.allocator);
    defer timeline.deinit();
    const spring: Transition = .{ .spring = .{ .stiffness = 100, .damping = 10 } };
    _ = try frame(&timeline, 0, 0, spring);
    _ = try frame(&timeline, 0, 100, spring);
    const before = try frame(&timeline, 0.05, 100, spring);
    const at_switch = try frame(&timeline, 0.05, -100, spring);
    try t.expectEqual(before, at_switch);
    // Initial velocity continues right briefly after the target moves left.
    // A spring reset to zero velocity would immediately move left instead.
    const after = try frame(&timeline, 0.0501, -100, spring);
    try t.expect(after > at_switch);
}

test "discarded animation targets never replace the committed target" {
    var timeline = Timeline.init(t.allocator);
    defer timeline.deinit();
    _ = try frame(&timeline, 0, 0, linear);
    _ = try frame(&timeline, 0, 10, linear);
    try timeline.beginFrame(0.5);
    try t.expectEqual(@as(f32, 5), try timeline.sample(1, 1000, linear, 0.5));
    timeline.discardFrame();
    try t.expectEqual(@as(f32, 7.5), try frame(&timeline, 0.75, 10, linear));
    try t.expectEqual(@as(f32, 10), try frame(&timeline, 1, 10, linear));
}

test "reduced motion snaps active and new tracks without timers" {
    var timeline = Timeline.init(t.allocator);
    defer timeline.deinit();
    _ = try frame(&timeline, 0, 0, linear);
    _ = try frame(&timeline, 0, 10, linear);
    timeline.reduced_motion = true;
    try t.expect(!timeline.active(0.25));
    try t.expectEqual(@as(f32, 10), try frame(&timeline, 0.25, 10, linear));
    try t.expectEqual(@as(f32, 50), try frame(&timeline, 0.5, 50, linear));
    timeline.reduced_motion = false;
    try t.expect(!timeline.active(0.5));
}

test "successful frames prune absent keys while discarded frames retain them" {
    var timeline = Timeline.init(t.allocator);
    defer timeline.deinit();
    _ = try frame(&timeline, 0, 10, linear);
    try timeline.beginFrame(1);
    timeline.discardFrame();
    try t.expectEqual(@as(usize, 1), timeline.count());
    try timeline.beginFrame(1);
    timeline.commitFrame();
    try t.expectEqual(@as(usize, 0), timeline.count());
}

test "animation rejects invalid inputs without mutating committed state" {
    var timeline = Timeline.init(t.allocator);
    defer timeline.deinit();
    try t.expectError(error.NoAnimationFrame, timeline.sample(1, 1, linear, 0));
    try t.expectError(error.InvalidAnimationTime, timeline.beginFrame(std.math.nan(f64)));
    try t.expectError(error.InvalidAnimationTime, timeline.beginFrame(-1));
    try timeline.beginFrame(0);
    defer timeline.discardFrame();
    try t.expectError(error.AnimationFrameActive, timeline.beginFrame(0));
    try t.expectError(error.InvalidAnimationTime, timeline.sample(1, 1, linear, 1));
    try t.expectError(error.InvalidAnimation, timeline.sample(1, std.math.inf(f32), linear, 0));
    try t.expectError(error.InvalidAnimation, timeline.sample(1, 1, .{ .tween = .{ .duration = -1 } }, 0));
    try t.expectError(error.InvalidAnimation, timeline.sample(1, 1, .{ .spring = .{ .mass = 0 } }, 0));
    _ = try timeline.sample(1, 1, linear, 0);
    try t.expectError(error.DuplicateAnimationKey, timeline.sample(1, 2, linear, 0));
}
