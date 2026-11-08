//! Frame-transactional scalar animation. Render samples a staging timeline;
//! commit installs its targets and prunes unseen keys. Discard leaves the
//! committed animation unchanged. All times are monotonic seconds supplied by
//! the window scheduler, so tests and native windows use the same equations.

const std = @import("std");
pub const Easing = enum {
    linear,
    ease_in,
    ease_out,
    ease_in_out,
};
pub const Tween = struct { duration: f64 = 0.18, easing: Easing = .ease_in_out };
pub const Spring = struct { stiffness: f64 = 220, damping: f64 = 28, mass: f64 = 1 };
pub const Transition = union(enum) { instant, tween: Tween, spring: Spring };

const Sample = struct { value: f64, velocity: f64 = 0, settled: bool };
const Track = struct {
    from: f64,
    target: f64,
    velocity: f64 = 0,
    started: f64,
    transition: Transition,

    fn at(track: Track, now: f64) Sample {
        const elapsed = @max(0, now - track.started);
        switch (track.transition) {
            .instant => return .{ .value = track.target, .settled = true },
            .tween => |tween| {
                if (tween.duration == 0 or elapsed >= tween.duration) return .{ .value = track.target, .settled = true };
                const p = elapsed / tween.duration;
                const eased = ease(tween.easing, p);
                return .{ .value = track.from + (track.target - track.from) * eased.value, .velocity = (track.target - track.from) * eased.derivative / tween.duration, .settled = track.from == track.target };
            },
            .spring => |spring| {
                const displacement = track.from - track.target;
                const alpha = spring.damping / (2 * spring.mass);
                const frequency_squared = spring.stiffness / spring.mass;
                const discriminant = alpha * alpha - frequency_squared;
                var y: f64 = undefined;
                var velocity: f64 = undefined;
                if (@abs(discriminant) <= 1e-10 * @max(1, frequency_squared)) {
                    // Repeated root: y=(a+bt)e^(-alpha*t).
                    const a = displacement;
                    const b = track.velocity + alpha * a;
                    const envelope = @exp(-alpha * elapsed);
                    y = (a + b * elapsed) * envelope;
                    velocity = (b - alpha * (a + b * elapsed)) * envelope;
                } else if (discriminant < 0) {
                    const omega = @sqrt(-discriminant);
                    const a = displacement;
                    const b = (track.velocity + alpha * a) / omega;
                    const envelope = @exp(-alpha * elapsed);
                    const cosine = @cos(omega * elapsed);
                    const sine = @sin(omega * elapsed);
                    y = envelope * (a * cosine + b * sine);
                    velocity = envelope * ((-a * omega * sine + b * omega * cosine) - alpha * (a * cosine + b * sine));
                } else {
                    const root = @sqrt(discriminant);
                    // This form avoids cancellation for heavily damped springs.
                    const slow = -frequency_squared / (alpha + root);
                    const fast = -alpha - root;
                    const a = (track.velocity - fast * displacement) / (slow - fast);
                    const b = displacement - a;
                    const first = a * @exp(slow * elapsed);
                    const second = b * @exp(fast * elapsed);
                    y = first + second;
                    velocity = slow * first + fast * second;
                }
                // Check both position and velocity. Merely crossing the target
                // must not stop an underdamped spring mid-oscillation.
                const settled = @abs(y) <= 0.001 and @abs(velocity) <= 0.001;
                return if (settled) .{ .value = track.target, .settled = true } else .{ .value = track.target + y, .velocity = velocity, .settled = false };
            },
        }
    }
};

pub const Timeline = struct {
    allocator: std.mem.Allocator,
    reduced_motion: bool = false,
    tracks: std.AutoHashMapUnmanaged(u128, Track) = .empty,
    staging: std.AutoHashMapUnmanaged(u128, Track) = .empty,
    frame_time: ?f64 = null,
    last_commit: f64 = 0,

    pub fn init(allocator: std.mem.Allocator) Timeline {
        return .{ .allocator = allocator };
    }
    pub fn deinit(timeline: *Timeline) void {
        timeline.staging.deinit(timeline.allocator);
        timeline.tracks.deinit(timeline.allocator);
        timeline.* = undefined;
    }
    pub fn beginFrame(timeline: *Timeline, now: f64) !void {
        if (timeline.frame_time != null) return error.AnimationFrameActive;
        if (!std.math.isFinite(now) or now < timeline.last_commit) return error.InvalidAnimationTime;
        timeline.staging.clearRetainingCapacity();
        timeline.frame_time = now;
    }
    /// A key identifies one scalar channel. Reusing it with a different target
    /// twice in one frame is an error, rather than render-order dependent state.
    pub fn sample(timeline: *Timeline, key: u128, target: f32, transition: Transition, now: f64) !f32 {
        const frame_time = timeline.frame_time orelse return error.NoAnimationFrame;
        if (!std.math.isFinite(now) or frame_time != now) return error.InvalidAnimationTime;
        if (!std.math.isFinite(target)) return error.InvalidAnimation;
        try validate(transition);
        if (timeline.staging.get(key)) |track| {
            if (track.target != target) return error.DuplicateAnimationKey;
            return finiteValue(track.at(now).value);
        }
        const previous = timeline.tracks.get(key);
        var track: Track = if (previous) |old| old else .{ .from = target, .target = target, .started = now, .transition = .instant };
        if (timeline.reduced_motion) {
            track = .{ .from = target, .target = target, .started = now, .transition = .instant };
        } else if (track.target != target) {
            const current = track.at(now);
            track = .{ .from = current.value, .target = target, .velocity = current.velocity, .started = now, .transition = transition };
        }
        const value = try finiteValue(track.at(now).value);
        try timeline.staging.put(timeline.allocator, key, track);
        return value;
    }
    /// No allocation or validation occurs after the window submits its scene.
    pub fn commitFrame(timeline: *Timeline) void {
        std.debug.assert(timeline.frame_time != null);
        std.mem.swap(@TypeOf(timeline.tracks), &timeline.tracks, &timeline.staging);
        timeline.last_commit = timeline.frame_time.?;
        timeline.frame_time = null;
        timeline.staging.clearRetainingCapacity();
    }
    pub fn discardFrame(timeline: *Timeline) void {
        timeline.frame_time = null;
        timeline.staging.clearRetainingCapacity();
    }
    pub fn active(timeline: *const Timeline, now: f64) bool {
        if (timeline.reduced_motion or !std.math.isFinite(now)) return false;
        var tracks = timeline.tracks.valueIterator();
        while (tracks.next()) |track| if (!track.at(now).settled) return true;
        return false;
    }
    pub fn remove(timeline: *Timeline, key: u128) void {
        _ = timeline.tracks.remove(key);
        _ = timeline.staging.remove(key);
    }
    pub fn count(timeline: *const Timeline) usize {
        return timeline.tracks.count();
    }
};

fn validate(transition: Transition) !void {
    switch (transition) {
        .instant => {},
        .tween => |tween| if (!std.math.isFinite(tween.duration) or tween.duration < 0) return error.InvalidAnimation,
        .spring => |spring| {
            if (!std.math.isFinite(spring.stiffness) or spring.stiffness <= 0 or !std.math.isFinite(spring.mass) or spring.mass <= 0 or !std.math.isFinite(spring.damping) or spring.damping < 0) return error.InvalidAnimation;
            // Ratio overflow or underflow would make the analytic solution
            // undefined. Reject it at this public parameter seam.
            const squared = spring.stiffness / spring.mass;
            const alpha = spring.damping / (2 * spring.mass);
            if (!std.math.isFinite(squared) or squared <= 0 or !std.math.isFinite(alpha) or !std.math.isFinite(alpha * alpha)) return error.InvalidAnimation;
        },
    }
}
fn finiteValue(value: f64) !f32 {
    if (!std.math.isFinite(value) or @abs(value) > std.math.floatMax(f32)) return error.AnimationOverflow;
    return @floatCast(value);
}
fn ease(easing: Easing, p: f64) struct { value: f64, derivative: f64 } {
    return switch (easing) {
        .linear => .{ .value = p, .derivative = 1 },
        .ease_in => .{ .value = p * p * p, .derivative = 3 * p * p },
        .ease_out => .{ .value = 1 - (1 - p) * (1 - p) * (1 - p), .derivative = 3 * (1 - p) * (1 - p) },
        .ease_in_out => if (p < 0.5) .{ .value = 4 * p * p * p, .derivative = 12 * p * p } else .{ .value = 1 - 4 * (1 - p) * (1 - p) * (1 - p), .derivative = 12 * (1 - p) * (1 - p) },
    };
}
