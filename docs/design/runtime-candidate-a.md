# Runtime candidate A: one transactional owner per window

## Problem and grounding

The current `App` owns a stable entity store and releases borrows at transaction boundaries. `Frames` can preserve a committed tree while another tree is built. Layout and Metal are tested independently, but nothing owns their combined lifetime. `ClickHandler` resolves an entity safely, while there is no hit-test dispatcher or native window. The missing module should own that integration, rather than make applications coordinate those pieces.

This candidate preserves the supplied specification, direct Zig system bindings, const rendering, and the existing GPU-independent test target. Both architect seats inherit the same model, so model diversity is reduced.

## Usage first

An ordinary application imports one package and owns no GPU object:

```zig
var app = try ui.App.init(.{ .allocator = init.gpa });
defer app.deinit();
const window = try app.openWindow(Counter, .{
    .title = "Counter", .width = 420, .height = 260,
}, .{});
try app.run();
```

The existing entity method shape remains unchanged:

```zig
pub fn render(self: *const Counter, u: *ui.Ui) !ui.Element {
    return u.column(.{ .gap = 12, .padding = ui.Insets.all(24) }, &.{
        try u.textFmt("Count: {d}", .{self.count}),
        try u.button(.{ .label = "Increment", .on_click = u.onClick(increment) }),
    });
}
fn increment(self: *Counter, _: *ui.Event(ui.Click), cx: *ui.Context(Counter)) void {
    self.count += 1;
    cx.notify();
}
```

A custom editor still uses the same window owner. Its element requests layout, prepares visible rows/hit regions during prepaint, and records clipped text/selection commands during paint. It registers an entity-bound text-input provider; it receives no native window, Metal encoder, or pointer to a prior render stack.

The app's build selects `.native = true` on the package dependency. Headless tests omit that option. The Zig application source above stays the same.

## Shape

```zig
pub fn App.openWindow(comptime T: type, options: WindowOptions, value: T) !WindowHandle;
pub fn App.run() !void;
pub const WindowHandle = struct { app_id: u32, slot: u32, generation: u32 };
const WindowState = struct {
    scope: Scope, root_entity: AnyEntity, root_view: ViewAdapter,
    frames: PreparedFrames, focus: FocusStore, pointer: PointerCapture,
    scheduler: Scheduler, animations: AnimationStore,
    surface: Surface, error_handler: ?WindowErrorHandler,
};
const PreparedFrame = struct {
    tree: Frame, layout: LayoutResult, hits: HitIndex,
    scene: Scene, dependencies: DependencySet, input: ?TextInputSnapshot,
};
```

`WindowState` is a stable allocation owned by its generational app window slot. It owns one coherent frame transaction, persistent focus/capture/animation state, and one opaque system surface. The native adapter owns its OS objects and renderer. No application callback sequences native drawing operations.

`PreparedFrames` replaces the current tree-only commit with committed/staging ownership for tree, layout, hit data, scene, dependency reads, and cleanup hooks together. Their arrays belong to that frame's arena. GPU-owned upload buffers and textures retain their existing independent submission lifetimes.

The internal `Surface` interface hides system state behind an opaque context and a small function table: request a frame at a deadline, submit a scene, request close, and destroy. Text metrics are another callback supplied by the surface's text engine. A default native driver is installed lazily by the first `openWindow`; `App.init` remains GPU-free. A private app driver owns the OS loop and all native surfaces. This is type erasure for a real varying dependency, not a public plugin-registration step.

## Native selection without contaminating headless tests

The package build emits one `native_enabled` option and adds system framework links only when enabled. `openWindow` is a generic method whose native driver is instantiated only when called. The core `State` stores an erased driver and erased window records, so importing `App` does not import Metal types.

Calling `openWindow` in a build without native capability produces a descriptive compile error explaining the package option. There is no fake backend returning successful windows and no public runtime `installPlatform` ritual. `run` calls the already-created driver's loop; it reports `NoWindows` if no driver/window exists.

For Linux/Windows native builds, select the matching system adapter once implemented. Until then, requesting such a native build fails explicitly. The same entity/tree/layout module remains available to portable headless tests.

## Frame transaction and error contract

1. Dispatch an owned input event against the committed hit tree while holding a dispatch lease.
2. Release entity borrows and drain queued effects; mark dependent windows dirty.
3. Build the new tree under a const root-entity read, then validate keys/contracts.
4. Measure, arrange, prepaint, and paint into the same staging arena.
5. Finish all fallible CPU preparation, including scene validation and native submission encoding.
6. Submit successfully, then commit by a nonfallible swap. No event can interleave on the UI thread.
7. Retire the old frame after its dispatch leases end; GPU buffers retire through GPU completion.

The current `Frames.commit` needs a prepare/validate operation followed by a nonfallible swap; it cannot perform a newly fallible validation after GPU submission. Metal's current combined draw function may remain initially if every possible CPU failure occurs before submission and the subsequent CPU commit cannot fail.

On staging/encoding failure, discard staging and report the error while keeping committed data and displayed pixels. An unavailable drawable returns a deferred/occluded result, not a successful presentation. Async GPU errors are a separate device/submission failure; report them and invalidate for recovery rather than pretending the CPU rollback undoes a submitted GPU command.

## Events, focus, and native text input

Hit data stores node indices into the committed frame. Dispatch constructs its root-to-target path and invokes generated entity-bound adapters in capture, target, and bubble order. Restore propagation/default/capture controls only with that actual dispatcher. Nested native callbacks enqueue owned events while a dispatch/frame transaction is active.

Logical keys resolve to persistent, generational focus identities. Equality uses the complete keyed path and key values; a hash alone is insufficient. Capture survives pointer movement outside bounds until release, cancellation, or owner destruction. Tab traversal and modal scopes use the committed focus order.

Text input is a distinct semantic channel. A focused provider supplies an owned/reused UTF-8 snapshot with document revision, selection, marked range, and caret geometry. Native queries translate UTF-16 against that exact snapshot. Replacement events carry its revision; stale replacements are refused or explicitly reconciled by the editing model. Cocoa callbacks never retain a borrowed entity pointer. The custom editor owns text, history, composition, and selection; the framework owns native input delivery and coordinate conversion.

## Scheduler and animation

Each window has one dirty flag and at most one scheduled frame request. Notifications are collected while updates run; dependency invalidation and observer delivery happen after the outer borrow ends. The committed dependency set records the root and every `Ui.watch` read. Updating that set is part of frame commit, so a failed render does not install half a dependency graph.

Use an injected monotonic clock and one window-owned animation store. A const view records keyed animation targets in staging and samples the current animation snapshot. Commit installs target changes after rendering has returned. A display/timer callback advances active tracks and requests the next frame; the callback disappears when tracks settle. Pointer hover alone does not create a permanent timer. Reduced motion snaps to targets, and closing the window cancels callbacks before releasing state.

Initial tracks should cover scalar/color interpolation, easing, interruptible springs, and presence. Layout transitions consume old/new committed rectangles. The same controlled clock drives headless animation tests; wall-clock sleeps are unnecessary.

## Module map and implementation sequence

1. `app/window.zig` owns prepared frames and generic root adapters; `graphics/painter.zig` converts built-in/custom elements to ordered scene commands.
2. `platform/macos/window.zig` implements direct Zig AppKit/CAMetalLayer callbacks; its surface uses the existing CoreText/Metal modules.
3. `event/dispatch.zig`, `hit_test.zig`, and `focus.zig` own routing and persistent input state. Extend typed handlers without native selectors leaking upward.
4. `app/scheduler.zig` and `animation/timeline.zig` own deadlines, coalescing, and deterministic animation tracks.
5. Entity observations/tasks enter through owned UI-thread messages. Component and editor packages depend only on the verified public framework.

Verify counter open/click/resize/close, failed staging retention, focus across rebuilds, capture release on destruction, IME snapshot revision checks, idle no-frame behavior, deterministic animations, and safe close with pending GPU work. Then drive an editor custom element through this same path.

## Tradeoffs and alternatives

This window-owned transaction concentrates knowledge and keeps the ordinary interface deep: `openWindow` and `run` hide lifecycle, scheduling, text metrics, scene preparation, and presentation. We accept one erased internal surface/driver seam and a native build option in exchange for a genuinely GPU-free core target.

A retained app-wide manager with separate tree/layout/scene managers can share caches earlier, but splits a window's commit and failure rules across multiple owners. A public runtime platform-installation interface keeps linking flexible but makes every application coordinate framework setup. Native types directly embedded in `App.State` are simpler initially but contaminate headless imports and future platform selection. These alternatives lose on ownership locality or caller load.

## Reconciliation and next step

This is a candidate sketch, not an implementation claim. The parent must synthesize it with candidate B and record accepted deviations. Start with `PreparedFrame` plus the painter, then a real native counter through `App.openWindow`; do not add another independently managed immediate UI path.
