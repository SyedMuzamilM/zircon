# Runtime candidate B: backend-neutral windows with an injected platform

This is a design candidate, not an implemented API. It follows the supplied specification and the existing entity/frame ownership rules. Both design seats use the inherited model, so model diversity is reduced.

## Usage first

Ordinary applications keep the specified entry point:

```zig
const ui = @import("zircon_ui");
var app = try ui.App.init(.{ .allocator = init.gpa, .io = init.io });
defer app.deinit();
const window = try app.openWindow(Counter, .{
    .title = "Counter", .width = 420, .height = 280,
}, .{});
try app.run();
```

`Counter.render(*const Counter, *Ui) !Element` and `ui.onClick(Counter.increment)` stay unchanged. A callback mutates its entity through `Context(Counter)` and calls `notify()`. No application code selects a Metal device or receives an Objective-C object.

A second caller, the editor, registers an application-owned custom element:

```zig
return ui.custom(CodeEditor, .{ .document = self.document });
// The custom element's phases use layout, text geometry, and Painter.
// Its text-input adapter resolves the owner entity when handling an edit.
```

The headless harness exercises the same window runtime with a real in-memory platform adapter:

```zig
var harness = try ui.testing.Harness.init(allocator);
const window = try harness.app.openWindow(Counter, options, .{});
try harness.click(window, .{ .string = "increment" });
try harness.advance(0.25); // Deterministic animation clock.
```

## Shape

`App` owns backend-neutral `WindowRecord` objects in stable storage. The native adapter owns only OS objects and rendering resources. The window manager owns frame transactions, routing, focus, text-input targets, and animation state. That makes the headless adapter useful without recreating application behavior in a test-only renderer.

```zig
pub const WindowHandle = struct { app_id: u32, slot: u32, generation: u32 };
const WindowRecord = struct {
    scope: Scope,
    root: AnyView,                // Entity identity plus generated const-render adapter.
    frames: Frames,
    committed: FrameOutput,       // Layout, hit index, scene, input snapshot, dependencies.
    staging: FrameOutput,
    focus: FocusStore,
    capture: PointerCapture,
    animations: AnimationStore,
    backend: BackendWindow,       // Private opaque cookie and operation table.
    dirty: DirtyReasons,
};
const Backend = struct {
    context: *anyopaque,
    ops: *const BackendOps,
};
const BackendOps = struct {
    open: *const fn (*anyopaque, WindowToken, WindowOptions) anyerror!BackendWindow,
    run: *const fn (*anyopaque, RuntimeSink) anyerror!void,
    wake: *const fn (*anyopaque, ?Deadline) void,
    prepare: *const fn (*anyopaque, BackendWindow, Scene) anyerror!Submission,
    present: *const fn (*anyopaque, Submission) void,
    close: *const fn (*anyopaque, BackendWindow) void,
    deinit: *const fn (*anyopaque) void,
};
```

The table is internal. It transports framework values, not AppKit selectors, native texture handles, or C wire structs. Direct Zig bindings implement the macOS adapter. A small private assembly module supplies the default backend factory; native artifacts bind macOS, portable tests bind headless. The core `App` implementation stores an injected `Backend` value and contains no conditional native fields or Objective-C imports.

Backend creation is lazy at the first window. `App.init` remains useful for entity-only clients. Window construction creates its ownership scope/root and native surface transactionally; on failure it releases every already-created part. A copied handle never owns a window. Generations prevent a stale handle from closing a replacement window.

This accepts runtime dispatch at OS/window submission seams. Entities, layout traversal, and generated view/custom-element adapters retain their existing direct or specialized calls; there is no virtual call per glyph.

## Frame and dispatch ownership

1. Resolve an incoming event against the committed hit index and logical focus path. Pin the committed frame for the entire dispatch, including capture, target, bubble, and default handling.
2. Open one application transaction around that entire dispatch. Existing per-handler `App.update` calls nest inside it. Release entity borrows before observers run; defer entity/window destruction until the event path is finished.
3. Drain notifications/effects and mark dependent windows dirty. Repeated notifications schedule one wake, not one immediate redraw each.
4. Build the next const-render tree in staging; collect watched entity versions there. Layout, prepaint, scene, accessibility data, and text-input snapshots all belong to that same staging generation.
5. Prepare GPU submission while the committed output remains untouched. Preparation copies CPU drawing data and obtains GPU resource leases; a preparation error keeps the previous CPU output and scene valid.
6. When preparation succeeds and dispatch pins are zero, commit tree/output/dependencies together and present. Retire the previous CPU frame only after no dispatch borrows it. GPU resources remain leased until submission completion.

The CPU commit can be atomic; physical presentation cannot be rolled back if the device later reports an asynchronous failure. Such a failure marks the window dirty and enters the documented device/resource recovery policy. It must not be reported as a successful rendered frame.

`Frames` currently swaps only trees. Add an enclosing generation-owned `FrameOutput` transaction rather than separately swapping layout and scene arrays after committing the tree. A failed staging frame must not accidentally replace its old dependency list or native text-input target.

## Input, custom elements, and animation

Focus and pointer capture use window-owned generational identities resolved from complete keyed ancestor paths, with key equality checks. They never store a pointer into an old node arena. Reconcile those identities at a successful frame commit; disappearing targets release capture/focus safely.

Typed event adapters store an entity token and compiled method adapter. Propagation controls are real dispatcher state, valid only through one event. Semantic actions are independent of physical shortcuts, and menus use the same action path. Default text insertion follows shortcut handling only when the event remains unconsumed.

The custom-element adapter owns typed layout/prepaint phase storage in its frame arena and registers cleanup hooks where needed. Editor-specific documents/selections stay outside the framework. A custom element supplies framework hit regions, paint commands, and an entity-bound text-input target through that interface.

The native input adapter translates UTF-16 ranges against the exact committed UTF-8 snapshot queried by the OS. It sends replacement/composition commands with that snapshot revision. Stale snapshots are refreshed or refused before applying an edit. Candidate-window geometry is obtained from the committed custom-element target.

Animation is persistent window UI state keyed by logical identity. `Ui.animate(key, target, transition)` reads/resamples that store without mutating the view entity. Springs preserve current velocity on interruption; tweens restart from the sampled value. The scheduler requests display-paced ticks only while an animation, caret blink, or other deadline exists. Reduced motion jumps decorative transitions to their destination. Headless tests advance the same clock explicitly.

## Module ownership

- `app/window.zig`: stable window records, frame transactions, scoped roots, close policy.
- `app/scheduler.zig`: dirty windows, coalesced wakes, deadlines and animation ticks.
- `event/`: committed-tree routes, typed actions, focus, capture, default handling.
- `ui/adapter.zig`: generated view/handler/custom-element contracts.
- `graphics/painter.zig`: platform-neutral ordered scene building and clipping.
- `platform/interface.zig`: private backend operations and semantic native events.
- `platform/macos/`: direct Zig AppKit objects/input and Metal surface presentation.
- `testing/headless.zig`: in-memory adapter, deterministic clock, synthetic input.

## Tradeoffs and alternatives

Runtime backend injection adds a small operation table and requires careful private build assembly. It hides native lifetimes behind one seam and lets tests run the same window/event policy. A compile-time native-specialized `App.State` is simpler to assemble initially but makes native/headless differences appear in the owner of entities and transactions. A native adapter that owns frame policy duplicates that policy when another platform arrives. A public backend argument pushes platform setup into ordinary callers and loses the desired `App.openWindow` interface.

## First implementation unit and reconciliation

Implement generation-owned `FrameOutput` plus the headless window manager first, proving failed render/layout/paint keeps committed handlers and geometry. Then connect the direct Zig macOS adapter to those callbacks and run a native counter journey before adding controls or editor UI. This candidate makes no implementation or performance claims; synthesis and accepted deviations belong in the parent's final runtime design.
