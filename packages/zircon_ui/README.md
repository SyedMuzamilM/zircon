# Zircon UI

An independent Zig UI framework. Ordinary applications own entities and views; the framework owns windows, input, layout, text and GPU resources.

```zig
const ui = @import("zircon_ui");
var app = try ui.App.init(.{ .allocator = allocator });
defer app.deinit();
_ = try app.openWindow(Counter, .{ .title = "Counter" }, .{});
try app.run();
```

A view implements `pub fn render(self: *const Self, builder: *ui.Ui) !ui.Element`. Use `column`, `row`, `stack`, `div`, `text`, `textFmt`, `button`, `custom`, `view` and `watch`. Styles use typed dimensions, colors and font styles. Native consumers configure the dependency with `.native = true`; the default package remains portable and uses an in-memory window adapter.

## Entity ownership and effects

`createEntity` creates application-owned state; `createInScope` and `Context.createChild` give explicit scope/parent ownership. Handles are non-owning, typed and generational. Root views belong to their window's scope. Children are destroyed before their owners. Optional entity cleanup has signature `deinit(*Self, std.mem.Allocator) void`.

`App.read` callbacks receive `*const Self`. `App.update` receives `(*Self, *Context(Self), ...)`. Access results cannot borrow pointers or slices; copy owned snapshots into caller-provided outputs. Conflicting borrows, expired contexts, stale identities and wrong-thread calls return errors. Destructors must not reenter the application.

Call `cx.notify()` after a change. Notifications coalesce after the outer transaction releases its borrows. `Ui.view` and `Ui.watch` collect committed dependency versions. Windows redraw when a committed dependency changes; failed staging leaves the prior dependency list in force.

`cx.observe(target, callback)` invokes `callback(*Self, *Context(Self), Entity(Target)) !void` after changes. `cx.subscribe(target, EventType, callback)` receives a typed event pointer in addition to its source. `cx.emit(event)` queues an event owned until delivery. Pointer-free payloads copy; owned payloads provide `clone(Allocator)!Self` and `deinit(*Self, Allocator)`. Generational `Subscription` handles support explicit unsubscribe; owner/source destruction disables delivery. `flushEffects` and `step` report deferred callback failures. A settlement wave is limited to 4,096 deliveries, reported as `EffectCycle`; this is overload protection, not graph-cycle detection.

## Frames and input

A successful frame commits tree, layout, scene, handlers, dependencies, animations and native text-input target together. All fallible preparation happens before native submission and the nonfallible CPU swap. A failed render/layout/paint keeps the previous committed frame. Cleanup hooks run in reverse order before arena reset. Metal independently leases submitted buffers until GPU completion. A later GPU/device failure cannot undo an already submitted frame.

`Ui.onClick` and `Ui.onInput` bind entity identities rather than render-stack pointers. `Ui.onClickWith` and `Ui.onInputWith` copy pointer-free typed callback payloads into frame storage. `Ui.listen` attaches capture/bubble handlers and focusability to any element. The dispatcher holds the committed tree and one outer application transaction throughout capture, target, bubble and default handling. Events expose propagation/default controls, focus/pointer capture requests, committed bounds, text metrics and clipboard access. Tab traversal and button keyboard activation share the same dispatcher. Logical keyed paths reconcile focus/capture after rebuilds. `Ui.autofocus` focuses a newly entering logical element. `Ui.modal` traps focus/Tab and pointer routing in its subtree and restores previous focus on dismissal. A close request reaches the root and can be prevented before native closure. Handlers use `App.requestCloseWindow` to defer a programmatic close until their borrow ends. `Ui.viewport` exposes logical window dimensions during rendering.

`App.step(seconds)` and `App.dispatch(window, input)` drive the same runtime in deterministic tests. The older `testing.Harness` remains a smaller entity/tree-only test tool. It does not imply native rendering.

## Custom elements and controls

`Ui.custom(T, value, style)` owns a frame-local value and generated adapter. T supplies `LayoutState`, `PrepaintState`, `requestLayout(*Self,*LayoutCx)!LayoutResult(LayoutState)`, `prepaint(*Self,*PrepaintCx,Rect,*LayoutState)!PrepaintState` and `paint(*Self,*PaintCx,Rect,*LayoutState,*PrepaintState)!void`. Optional `deinit(*Self)void` releases retained resources at frame retirement. Ownership of the custom value transfers only when construction succeeds; the caller retains cleanup responsibility on error. Phase storage belongs to the frame. Painter records ordered clipped rectangles/text with inherited opacity.

A focused custom element publishes `PrepaintCx.setTextInput(snapshot)`. Snapshots copy UTF-8 context and carry revision, selection/marked ranges, caret geometry, byte base and UTF-16 base. Native replacement ranges become absolute document byte ranges. Models validate the exact revision and refuse stale edits. Native stale refusal requests a fresh frame and does not terminate the event loop. Selector tests cover composition and range conversion; a real OS input-method acceptance journey remains to be done.

`controls.TextInput` is a persistent single-line editable view with selection, dragging, clipboard and composition. `controls.Scroll` and `visibleRows` provide bounded viewport math for custom scrolling content. Text movement currently uses code-point boundaries, not full grapheme segmentation. Typed `Keymap(Action)` resolves physical shortcuts to application commands; applications can dispatch the same commands from menus/palettes.

## Animation and jobs

`Ui.animate`, `animateColor`, `animateRect` and `presence` sample keyed scalar channels, tweens/easing and analytic springs. Render records targets in staging; commit installs them and prunes unseen tracks. Discard preserves previous targets. Interrupted springs preserve velocity. The window schedules ticks only while tracks remain active, renders the final sample and then idles. `App.setReducedMotion` snaps decorative motion. Headless tests advance an explicit monotonic clock.

`cx.spawn(Job, owned_job, callback)` binds a worker to the entity. Job supplies `Output`, `run(*Job,*Cancellation)!Output`, `discard(*Job,Output)void` and optional `deinit(*Job,Allocator)void`. The completion callback receives `(*Self,*Context(Self),anyerror!Output)!void` on the UI thread and borrows output; the queue always discards it afterward. Copy to retain. Worker input/output must not borrow entity state. Owner destruction cooperatively cancels work and suppresses stale completion. Shutdown joins workers before releasing remaining app state. A worker ignoring cancellation can delay shutdown. `tasks.Queue` exposes the lower-level independent executor.

## Layout and native limits

Flex supports rows/columns, layering through stacks, padding, positive margins, gaps, grow/shrink with min/max freezing, alignment and logical pixel/rem/viewport/percentage dimensions. It does not implement wrapping, grid or baseline alignment. FixedMetrics is a deterministic test measurer; native layout uses CoreText with glyph-based caret/index conversion.

The renderer implements rounded quads, clipped text, painter order, PNG snapshots and three leased buffers. The active monochrome glyph atlas is 4 MiB; old generations can remain in flight. The shaped-text cache retains at most512 entries and an estimated4 MiB, with64 fonts. Large transient lines can exceed that cache estimate. These policies are not a process-memory cap. Emoji coverage is monochrome; shaders compile at renderer creation; recycling a busy GPU buffer can wait.

Images/SVG/path effects, native menus/dialogs, full accessibility, advanced layout and additional operating-system adapters are not yet implemented. See the repository status for the current editor and verification coverage.
