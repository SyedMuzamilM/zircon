//! Editor caret appearance and visual timing.

const std = @import("std");
const ui = @import("zircon_ui");
pub const Shape = enum { bar, block, underline, hollow };

pub const Config = struct {
    shape: Shape = .bar,
    unfocused_shape: ?Shape = .hollow,
    blink: bool = true,
    blink_interval: f64 = 0.5,
    pause_after_input: f64 = 0.5,
    bar_width: f32 = 2,
    underline_height: f32 = 2,
    hollow_stroke: f32 = 1.5,
    corner_radius: f32 = 1,
    color: ?ui.Color = null,
    smooth: bool = false,
    smooth_duration: f64 = 0.055,

    pub fn validate(self: Config) !void {
        inline for (.{ self.blink_interval, self.bar_width, self.underline_height, self.hollow_stroke, self.smooth_duration }) |value| {
            if (!std.math.isFinite(value) or value <= 0) return error.InvalidEditorOptions;
        }
        inline for (.{ self.pause_after_input, self.corner_radius }) |value| {
            if (!std.math.isFinite(value) or value < 0) return error.InvalidEditorOptions;
        }
        if (!std.math.isFinite(self.pause_after_input + 2 * self.blink_interval)) return error.InvalidEditorOptions;
        if (self.color) |color| try (ui.TextStyle{ .color = color }).validate();
    }

    pub fn shapeForFocus(self: Config, active_shape: Shape, focused: bool) ?Shape {
        if (focused) return active_shape;
        return if (active_shape == .block or active_shape == .hollow) self.unfocused_shape else null;
    }
};

const BlinkState = struct {
    last_activity: f64 = 0,
    activity_pending: bool = true,

    fn sync(self: *BlinkState, now: f64, activity: bool) void {
        if (activity or self.activity_pending or now < self.last_activity) self.last_activity = now;
        self.activity_pending = false;
    }

    fn phase(self: BlinkState, config: Config, now: f64) f64 {
        return now - self.last_activity - config.pause_after_input;
    }

    pub fn visible(self: BlinkState, config: Config, now: f64, shape: Shape) bool {
        if (!config.blink or shape == .hollow) return true;
        const elapsed = self.phase(config, now);
        return elapsed < 0 or @mod(elapsed, config.blink_interval * 2) < config.blink_interval;
    }

    pub fn nextWake(self: BlinkState, config: Config, now: f64, shape: Shape) ?f64 {
        if (!config.blink or shape == .hollow) return null;
        const elapsed = self.phase(config, now);
        const delay = config.blink_interval - if (elapsed < 0) elapsed else @mod(elapsed, config.blink_interval);
        return @max(0.001, delay);
    }
};

const SmoothState = struct {
    current: ui.Rect,
    target: ui.Rect,
    time: f64,

    fn step(self: *SmoothState, target: ui.Rect, now: f64, duration: f64, moved: bool) ?ui.Rect {
        const previous = self.time;
        const was_moving = !std.meta.eql(self.current, self.target);
        const animate = moved or std.meta.eql(target, self.target);
        self.time = now;
        self.target = target;
        if (animate and !std.meta.eql(self.current, target) and
            @abs(target.x - self.current.x) <= 600 and @abs(target.y - self.current.y) <= 600)
        {
            const max_step: f64 = if (was_moving) 0.05 else 1.0 / 120.0;
            const dt = std.math.clamp(now - previous, 0, max_step);
            const alpha: f32 = @floatCast(1 - @exp(-dt / @max(0.001, duration * 0.35)));
            inline for (.{ "x", "y", "width", "height" }) |field| {
                @field(self.current, field) += (@field(target, field) - @field(self.current, field)) * alpha;
            }
            if (@abs(target.x - self.current.x) >= 0.35 or @abs(target.y - self.current.y) >= 0.35 or
                @abs(target.width - self.current.width) >= 0.35 or @abs(target.height - self.current.height) >= 0.35)
                return self.current;
        }
        self.current = target;
        return null;
    }
};

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    refs: usize = 1,
    blink: BlinkState = .{},
    smooth: ?SmoothState = null,
    position: ?Position = null,
    viewport: ?Viewport = null,

    pub const Position = struct { head: usize, revision: u64, shape: Shape };
    pub const Viewport = struct { bounds: ui.Rect, scroll: f32, horizontal: f32, line_height: f32, gutter: f32 };

    pub fn init(a: std.mem.Allocator) !*Runtime {
        const self = try a.create(Runtime);
        self.* = .{ .allocator = a };
        return self;
    }

    pub fn retain(self: *Runtime) *Runtime {
        self.refs += 1;
        return self;
    }

    pub fn release(self: *Runtime) void {
        self.refs -= 1;
        if (self.refs == 0) self.allocator.destroy(self);
    }

    pub fn pause(self: *Runtime) void {
        self.blink.activity_pending = true;
    }

    pub fn sync(self: *Runtime, position: Position, viewport: Viewport, now: f64, retained_focus: bool) bool {
        const previous = self.position;
        self.blink.sync(now, !retained_focus or !std.meta.eql(previous, @as(?Position, position)));
        if (!retained_focus or previous == null or previous.?.shape != position.shape or
            !std.meta.eql(self.viewport, @as(?Viewport, viewport)))
            self.smooth = null;
        self.position = position;
        self.viewport = viewport;
        return if (previous) |prior| prior.head != position.head else false;
    }

    pub fn glide(self: *Runtime, target: ?ui.Rect, now: f64, duration: f64, moved: bool) ?ui.Rect {
        const rect = target orelse {
            self.smooth = null;
            return null;
        };
        if (self.smooth) |*state| return state.step(rect, now, duration, moved);
        self.smooth = .{ .current = rect, .target = rect, .time = now };
        return null;
    }
};

pub const Layout = struct {
    shape: Shape,
    cell: ui.Rect,
    color: ui.Color,
    config: Config,

    pub fn rect(self: Layout) ui.Rect {
        var bounds = self.cell;
        switch (self.shape) {
            .bar => {
                const inset = std.math.clamp((bounds.height - 1) / 2, 0, 2);
                bounds.y += inset;
                bounds.height -= 2 * inset;
                bounds.width = self.config.bar_width;
            },
            .underline => {
                const height = @min(bounds.height, self.config.underline_height);
                bounds.y += bounds.height - height;
                bounds.height = height;
            },
            .block, .hollow => {},
        }
        return bounds;
    }

    pub fn paint(self: Layout, painter: *ui.graphics.Painter, bounds: ui.Rect) !void {
        const half = @min(bounds.width, bounds.height) / 2;
        if (self.shape == .hollow) {
            try painter.strokeRect(bounds, self.color, @min(self.config.hollow_stroke, half));
        } else {
            try painter.fillRect(.{ .bounds = bounds, .color = self.color, .radius = @min(self.config.corner_radius, half) });
        }
    }
};
