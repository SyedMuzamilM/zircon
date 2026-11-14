# Zircon UI API reference

Zircon UI is our Zig UI framework in [`packages/zircon_ui`](../packages/zircon_ui). Applications import it with `const ui = @import("zircon_ui");`. Its public exports are defined in [`src/root.zig`](../packages/zircon_ui/src/root.zig).

The package owns windows, entity lifetimes, input dispatch, layout, text measurement, and rendering. The Zircon editor in [`apps/zircon`](../apps/zircon/src/main.zig) is an application built with it. Editor documents, Git, language servers, extensions, and Markdown belong to separate packages.

This reference describes the working tree on November 8, 2026. The package declares version `0.1.0` and requires Zig `0.17.1`. The [original specification](specification/framework-api-v0.1.md) records the intended design. Its examples are not the current API contract.

[Build an app with Zircon UI](zircon-ui-usage.md) contains setup, a complete counter, and commands to run it.

## Locations

| Location | Contents |
| --- | --- |
| [`packages/zircon_ui/src/root.zig`](../packages/zircon_ui/src/root.zig) | Public imports and namespaces |
| [`packages/zircon_ui/build.zig`](../packages/zircon_ui/build.zig) | Module registration, native option, system libraries, and package tests |
| [`examples/counter/main.zig`](../examples/counter/main.zig) | Small tree inspection example without a display |
| [`examples/counter_native/main.zig`](../examples/counter_native/main.zig) | Native counter with a spring animation |
| [`packages/zircon_ui/tests`](../packages/zircon_ui/tests) | Executable examples of ownership, input, frames, controls, and native rendering |
| [`packages/zircon_editor/src/canvas.zig`](../packages/zircon_editor/src/canvas.zig) | Custom editor element with layout, text, painting, and virtualization |
| [`apps/zircon/src/shell.zig`](../apps/zircon/src/shell.zig) | Application composition, child entities, input fields, and commands |

## Application and windows

`App` is defined in [`app/app.zig`](../packages/zircon_ui/src/app/app.zig). Window options and native input types come from [`platform/interface.zig`](../packages/zircon_ui/src/platform/interface.zig).

| API | Behavior |
| --- | --- |
| `App.init(.{ .allocator = allocator })`, `app.deinit()` | Create and release the application, its entities, windows, and workers |
| `app.openWindow(T, options, value)` | Create a window whose root entity is an initial value of type `T`. Returns `WindowHandle` |
| `app.openChildWindow(parent, T, options, value)` | Create a window above its parent. Parent closure closes children |
| `app.windowEntity(T, handle)` | Return the root's typed `Entity(T)` handle |
| `app.raiseWindow(handle)` | Raise an existing window |
| `app.requestCloseWindow(handle)` | Queue closure until active callbacks release their borrows |
| `app.closeWindow(handle)` | Close a window directly outside conflicting active borrows |
| `app.run()` | Run the event loop until the windows close |
| `app.step(time)` | Process pending work and draw dirty windows at an explicit time in seconds. Returns the number drawn |
| `app.currentTime()` | Return the time of the latest `step`, initially zero. Services share this clock with deterministic headless tests |
| `app.dispatch(handle, input)` | Dispatch an `Input` through the committed window tree |
| `app.setTypography(value)` | Apply `ui.typography.Typography` settings |
| `app.setReducedMotion(bool)` | Snap decorative animations when reduced motion is enabled |
| `app.window(handle)` | Return the lower-level window, including its surface and committed frames |

`WindowOptions` has `title`, `width`, `height`, `visible`, `chrome`, and `background`. Dimensions are logical pixels. `.chrome = .integrated` retains the native traffic lights with a full-size content view and transparent titlebar. The application reserves space for the traffic lights. `Ui.dragRegion(element)` marks draggable content.

The lower-level window surface has `choosePath(allocator, .file)` and `choosePath(allocator, .folder)`. The macOS adapter uses `NSOpenPanel`. Cancellation returns `null`; a selected path is caller-owned. This is not a top-level `App` dialog API.

## Entities, contexts, and ownership

`Entity(T)` is a typed, non-owning, generational handle. A `Scope` or parent entity owns the state. `Context(T)` is valid only during its callback.

| API | Behavior |
| --- | --- |
| `app.createEntity(T, value)` | Create application-owned state |
| `app.createScope()`, `app.createInScope(scope, T, value)` | Create a scope and state owned by that scope |
| `cx.createChild(T, value)` | Create state owned by the current entity |
| `app.read(entity, reader, args)` or `cx.read(...)` | Call `reader(*const T, ...)` under a shared borrow |
| `app.update(entity, operation, args)` or `cx.update(...)` | Call `operation(*T, *ui.Context(T), ...)` under an exclusive borrow |
| `cx.notify()` | Mark the current entity changed. Repeated notifications coalesce after the outer transaction |
| `app.destroyEntity(entity)`, `app.destroyScope(scope)`, `cx.destroy(entity)` | Request destruction. Active callbacks defer actual cleanup |
| `app.version(entity)` | Return the entity's notification version |
| `app.beginTransaction()`, `app.endTransaction()` | Group nested operations into one settlement boundary |

Read and update results cannot contain borrowed pointers or slices. A reader can return a scalar or copy a snapshot into a caller-owned output argument. Optional entity cleanup has the signature `pub fn deinit(self: *T, allocator: std.mem.Allocator) void`.

Children are destroyed before their owners. Destructors cannot reenter the app. Stale handles, conflicting borrows, expired contexts, and access from the wrong thread fail runtime checks. `App`, `Entity`, and `Context` operations belong on the UI thread, except for the static `App.wake()` operation described below.

Implementation: [`entity/entity.zig`](../packages/zircon_ui/src/entity/entity.zig), [`entity/store.zig`](../packages/zircon_ui/src/entity/store.zig), and [`entity/scope.zig`](../packages/zircon_ui/src/entity/scope.zig). Examples: [entity tests](../packages/zircon_ui/tests/entity_tests.zig).

## Views and elements

Application views use `const f = b.fluent();` and return chains ending in `.build()`. See [fluent composition](zircon-ui-composition.md) for styling, child entities, focus, capture, modal controls and ownership. The eager operations below are the underlying framework primitives and custom-element construction API.

A view implements this contract:

```zig
pub fn render(self: *const T, builder: *ui.Ui) !ui.Element
```

The [compact composition guide](zircon-ui-composition.md) documents tuple children, fallible modifiers, inline button metadata and callback payload inference.

Rendering reads persistent state and creates frame-owned elements. `Element` is a frame-local handle, not persistent state. Text and child slices passed to the builder are copied into the frame.

| `Ui` methods | Purpose |
| --- | --- |
| `column(style, children)`, `row(style, children)`, `stack(style, children)` | Arrange child elements vertically, horizontally, or in layers |
| `div(style, children)` | Create a container using the style's direction |
| `text(bytes)`, `textFmt(format, args)` | Create UTF-8 text |
| `button(options)` | Create a focusable button with `label`, optional `key`, click/input/capture handlers, focus options, `style`, `children`, `tooltip`, and `tooltip_colors` |
| `styled(element, style)` | Replace an element's style |
| `key(ElementKey, element)` | Give an element a logical key for identity across rebuilds |
| `view(entity)` | Render a child entity and record its dependency version |
| `watch(entity, reader, args)` | Read another entity and record its dependency version |
| `custom(T, value, style)` | Create a custom element using generated adapters |
| `allocator()` | Return the frame allocator |
| `requestFrameAfter(seconds)` | Request one future frame using the current frame clock. The earliest requested deadline wins. Rejects nonpositive, nonfinite or overflowing delays |
| `viewport()` | Return the logical window size available to rendering |

`ElementKey` accepts `.string` or `.number` keys. Logical paths reconcile focus and pointer capture between committed frames. An element can belong to only one parent.

A successful frame commits the tree, layout, scene, handlers, dependencies, animation state, and native text-input target together. A failed preparation keeps the previous frame. This rollback does not undo an already submitted GPU frame.

Frame deadlines commit with that same transaction. A failed render cannot replace the previous deadline. Use `requestFrameAfter` for delayed UI-owned work that must wake an otherwise idle native event loop. Request a new deadline only while work is pending; an idle view does not need a repeating timer. `App.run` also processes close requests queued by task completions before sleeping again.

Implementation: [`ui/ui.zig`](../packages/zircon_ui/src/ui/ui.zig), [`ui/element.zig`](../packages/zircon_ui/src/ui/element.zig), and [`ui/tree.zig`](../packages/zircon_ui/src/ui/tree.zig). Examples: [frame tests](../packages/zircon_ui/tests/frame_tests.zig).

## Styles and layout

[`Style`](../packages/zircon_ui/src/ui/style.zig) has typed fields rather than CSS strings.

| Fields or types | Supported values |
| --- | --- |
| `width`, `height`, and their `min_` and `max_` variants | `Length`: `.auto`, `.px`, `.percent`, `.rem`, `.viewport_width`, `.viewport_height` |
| `direction` | `.row`, `.column`, `.stack` |
| `padding`, `margin` | `Insets`, including `Insets.all(value)` |
| `gap`, `flex_grow`, `flex_shrink` | Nonnegative numbers |
| `align_items` | `.start`, `.center`, `.end`, `.stretch` |
| `justify_content` | `.start`, `.center`, `.end`, `.space_between` |
| `background`, `hover_background` | Optional `Color`, including `Color.rgb(0xRRGGBB)` |
| `radius`, `opacity`, `overflow`, `scroll_y` | Rounded corners, inherited opacity, `.visible` or `.hidden` overflow, and vertical scroll offset |
| `text` | `TextStyle` with `size`, `mono`, and `color` |

Geometry exports are `Point`, `Size`, `Rect`, `Insets`, and `Color`. The `layout` namespace also exports `Style`, `Length`, `Insets`, `Constraints`, `LayoutResult`, `calculate`, `Measurer`, and `FixedMetrics`. Native text measurement uses CoreText. `FixedMetrics` provides deterministic test measurements.

The flex implementation supports grow/shrink and min/max constraints. Wrapping, grid, and baseline alignment are absent. Editor soft wrapping is implemented in the editor package rather than the framework's flex layout.

## Input, focus, and commands

| API | Behavior |
| --- | --- |
| `b.onClick(callback)`, `b.onInput(callback)` | Bind a callback to the rendering entity's identity |
| `b.onClickWith(callback, value)`, `b.onInputWith(callback, value)` | Copy a pointer-free typed payload into frame storage |
| `b.listen(element, options)` | Set `on_input`, `on_capture`, and `focusable` on an element |
| `b.autofocus(element)` | Focus a logical element when it first enters the committed tree |
| `b.requestFocus(element, generation)` | Request focus when the supplied generation changes |
| `b.modal(element)` | Restrict pointer routing and keyboard traversal to a subtree, restoring focus on dismissal |
| `ui.Keymap(Action).init(bindings)` | Construct a typed command map. Duplicate chords fail |
| `map.resolve(input)` | Resolve a key-down event to an application-defined action |

Click callbacks receive `(*T, *ui.Event(ui.Click), *ui.Context(T))`. Input callbacks receive `(*T, *ui.Event(ui.Input), *ui.Context(T))`. The `With` variants append the typed payload as the last parameter. Callbacks can return `void` or an error union with a `void` payload.

`Event(T)` exposes `data`, `phase`, and committed `bounds`. Its methods include `stopPropagation`, `preventDefault`, `focus`, `capturePointer`, `releasePointer`, `textMetrics`, `windowSize`, `readClipboard`, and `writeClipboard`.

Dispatch proceeds through capture, target, bubble, and default handling. Built-in defaults include Tab traversal and keyboard button activation. A close-request event can prevent native closure. `Input`, `Key`, `Modifiers`, and `Chord` are public exports. `Key` has a limited physical-key vocabulary; `Keymap` resolves single chords rather than multi-stroke sequences.

Implementation: [`event/event.zig`](../packages/zircon_ui/src/event/event.zig), [`event/actions.zig`](../packages/zircon_ui/src/event/actions.zig), and [`ui/adapter.zig`](../packages/zircon_ui/src/ui/adapter.zig). Examples: [window tests](../packages/zircon_ui/tests/window_tests.zig) and [control tests](../packages/zircon_ui/tests/control_tests.zig).

## Observations and typed events

| API | Callback or effect |
| --- | --- |
| `cx.observe(target, callback)` | `callback(*T, *ui.Context(T), ui.Entity(Target)) !void` after target notifications |
| `cx.subscribe(target, EventType, callback)` | The same owner/context/source arguments, followed by `*const EventType` |
| `cx.emit(event)` | Queue an event from the current entity |
| `app.unsubscribe(subscription)` | Disable a generational `Subscription` |
| `app.flushEffects()` | Settle deferred callbacks and report their failures |

`App.observe`, `App.subscribe`, and `App.emit` also accept an explicit owner or source. Destroying the owner or source disables delivery. Pointer-free event payloads copy directly. Owned payloads provide `clone(Allocator) !Self` and `deinit(*Self, Allocator) void`.

One settlement wave permits 4,096 deliveries before `EffectCycle`. This is an overload limit, not graph-cycle detection. Examples: [reactivity tests](../packages/zircon_ui/tests/reactive_tests.zig).

## Controls, text, and scrolling

| Export | Current scope |
| --- | --- |
| `controls.TextInput` | Persistent single-line view with selection, dragging, clipboard, composition, appearance, and an optional leading icon |
| `controls.Scroll` | `offset` state with `clamp`, `wheel`, and `reveal` methods |
| `controls.visibleRows(count, height, offset, viewport, overscan)` | Visible range and top offset for fixed-height virtual rows |
| `controls.UniformList` / `controls.uniformList` | Fixed-height virtual list; paints visible rows plus overscan without per-item nodes |
| `controls.VariableList` / `controls.variableList` | Variable-height virtual list using caller-supplied prefix/index functions |
| `controls.icons` | Named icons and drawing helpers generated from repository SVG assets |
| `controls.Svg` / `graphics.images.Image.loadSvg` | Native macOS SVG rasterization with retained image transforms and scene animation |
| `controls.metrics` | Shared control dimensions |
| `typography` | UI/code font choices, installed font names, and `Typography` settings |
| `TextRange`, `TextSnapshot`, `TextEdit` | UTF-8 byte ranges, revisioned surrounding text, and replacement edits |

`TextInput.init(allocator, text)` creates the value. Its entity destructor frees its text. `TextInput.copy` copies bytes into a caller-owned output. `TextInput.setAppearance` is an update callback. The application composes text inputs through `b.view(entity)`.

Custom editable elements publish a focused `TextSnapshot` with `PrepaintCx.setTextInput`. The platform converts native UTF-16 positions to document byte ranges. The model rejects stale edit revisions. Selection and movement currently follow code-point boundaries rather than complete grapheme clusters.

Implementation: [`controls/text_input.zig`](../packages/zircon_ui/src/controls/text_input.zig), [`controls/scroll.zig`](../packages/zircon_ui/src/controls/scroll.zig), and [`text/typography.zig`](../packages/zircon_ui/src/text/typography.zig).

## Custom elements, painting, and images

`Ui.fluent()` provides GPUI-style element chains over the existing frame-owned nodes. The [composition guide](zircon-ui-composition.md#gpui-style-element-chains) documents constructors, typed style utilities, children, callbacks, build/error behavior and frame scope. It does not introduce deferred ownership for custom elements.

`App.init` accepts an optional `icon: Image` and retains its own reference. `WindowOptions.icon` accepts an `images.View` borrowed during creation. The native macOS adapter copies it, tags it as sRGB, and publishes the application-wide Dock icon after the window's first successful presentation. Window failure or frame discard preserves the previous icon. Distribution resources and Linux/Windows adapters remain open. See [application icon ownership and current scope](progress/2026-11-08-application-icons.md).

The `Ui.custom` contract is defined in [`ui/custom.zig`](../packages/zircon_ui/src/ui/custom.zig). A custom type declares `LayoutState` and `PrepaintState`, and supplies these methods:

```zig
pub fn requestLayout(self: *T, cx: *ui.LayoutCx) !ui.LayoutResult(LayoutState)
pub fn prepaint(self: *T, cx: *ui.PrepaintCx, bounds: ui.Rect, layout: *LayoutState) !PrepaintState
pub fn paint(self: *T, cx: *ui.PaintCx, bounds: ui.Rect, layout: *LayoutState, prepared: *PrepaintState) !void
```

These are signatures, not a complete custom element. Phase state belongs to the frame. Optional `deinit(*T) void` releases retained resources when that frame retires. A successful `custom` call takes ownership of its value. On error, cleanup remains the caller's responsibility.

`PaintCx.painter` is a `graphics.Painter`. It records ordered `fillRect`, `fillLinearGradient`, layered `shadowRect`, `strokeRect`, `strokeLine`, `drawText`, `drawImage`, transformed images and scene-animated images with clipping and opacity. `graphics.Scene` and `graphics.paintTree` expose lower-level scene construction. `PrepaintCx.requestFrameAfter(seconds)` schedules a future redraw, such as a caret-blink boundary. Scene animation tracks update image transforms during presentation without rebuilding the UI tree.

`graphics.images.Image.fromRgba` copies straight RGBA pixels and premultiplies alpha. `Image.load` decodes encoded images through macOS ImageIO and uses the first frame; `Image.loadSvg` rasterizes AppKit SVG data into the same retained format. Images are immutable retained values with `clone` and `deinit`, used on their creator thread. `drawImage(image, bounds, fit)` accepts `.contain`, `.cover`, or `.stretch`. The custom element retains its image until frame retirement; GPU submission separately retains textures in flight.

Decoded assets are limited to 64 MiB and 16,384 pixels per dimension. Cache and retired-frame budgets do not impose a whole-process memory cap. Examples: [painter tests](../packages/zircon_ui/tests/painter_tests.zig), [image tests](../packages/zircon_ui/tests/image_tests.zig), and the [editor canvas](../packages/zircon_editor/src/canvas.zig).

## Animation and background work

`b.animate(key, target, transition)` samples a scalar channel. `animateColor` and `animateRect` sample four scalar channels each. `presence` returns `visible` and `opacity` for entry/exit composition. Transitions are `.instant`, `.tween`, or `.spring`, defined in [`animation/timeline.zig`](../packages/zircon_ui/src/animation/timeline.zig). Color and rectangle helpers expand their key to `key * 4` through `key * 4 + 3`; overlapping scalar keys share tracks within the same entity.

Animation targets commit with the frame. Failed frames preserve the previous targets. Active tracks schedule ticks until settled. Interrupted springs preserve velocity.

`cx.spawn(Job, owned_job, callback)` starts an entity-owned worker. `App.spawn` also accepts an explicit owner. The job contract is:

```zig
pub const Output = /* application-defined type */;
pub fn run(self: *Job, cancel: *ui.tasks.Cancellation) !Output
pub fn discard(self: *Job, output: Output) void
// Optional:
pub fn deinit(self: *Job, allocator: std.mem.Allocator) void
```

The completion callback receives `(*T, *ui.Context(T), anyerror!Output) !void` on the UI thread. The queue discards the output after the callback, so retained results require a copy. Worker inputs and outputs cannot borrow entity state. Owner destruction requests cooperative cancellation and suppresses stale completion. Shutdown joins workers. A worker that ignores cancellation can delay shutdown.

`app.cancelTask(handle)` requests cancellation. `app.tasksPending()` reports outstanding work. `tasks.Queue` exposes the independent executor.

`app.watchExternal(owner, callback)` registers a UI-thread inbox drain with callback `(*T, *ui.Context(T)) !void`. A producer publishes owned data and calls thread-safe `ui.App.wake()`. The producer must stop and join before its inbox storage is destroyed. Examples: [owned task tests](../packages/zircon_ui/tests/owned_task_tests.zig) and [external inbox tests](../packages/zircon_ui/tests/external_tests.zig).

## Platforms and verification

The package defaults to `.native = false`, using an in-memory window adapter without a display or GPU. `.native = true` currently requires macOS and links AppKit, Metal, QuartzCore, CoreText, CoreGraphics, ImageIO, CoreFoundation, Foundation, and `objc`. These bindings are written in Zig.

Linux portable cross-compilation does not provide a Linux desktop UI. Windows and Linux native adapters are absent.

| Existing check | Coverage |
| --- | --- |
| `./tools/zig build test` | Portable framework tests through `App.step`, dispatch, and lower-level modules |
| `./tools/zig build check` | Repository portable suites, Zig formatting, and expected compile failures |
| `./tools/zig build test-native` | Actual macOS window/input, CoreText, Metal, and image checks |
| `./tools/zig build test-native-fresh --summary all` | Fresh sequential native framework, editor, and settings execution |
| `./tools/zig build test-build -Dtarget=aarch64-linux-gnu` | Compile portable tests for Linux |

`testing.Harness` is a smaller entity/tree tool with `init`, `render`, `flush`, and `deinit`. It does not run native rendering. `testing.native` provides `objc`, `pump`, and `now` only in native builds. [Native verification](native-verification.md) distinguishes window-bound synthetic input from foreground routing and OS input-method acceptance.

## Remaining framework work

These are framework gaps, separate from the [editor backlog](editor-todo.md). The [implementation status](status.md) records broader coverage. No comparative speed or memory advantage over Zed has been measured.

| Area | Present behavior | Remaining work and completion evidence |
| --- | --- | --- |
| Accessibility | Focusable controls and keyboard traversal | OS accessibility tree, roles, names, values, actions, and screen-reader journeys |
| Text correctness | Revisioned edits, native selector coverage, code-point movement | Real OS IME acceptance, grapheme-aware movement/deletion, broader bidi behavior, and color emoji |
| Controls | Buttons, a single-line input, scroll math, fixed/variable virtual lists, icons, SVG elements, and custom elements | Toggles, menus, and richer text controls with keyboard and accessibility contracts |
| Layout | Flex subset, stacks, clipping, and scrolling | Flex wrapping, grid, and baseline alignment with measurement/hit-testing regressions |
| Graphics | Quads, gradients, layered shadows, round-capped lines, text, images, generated icons, runtime SVG rasterization, transforms, and scene animation | General vector path tessellation, color glyphs, and GPU/device recovery tests |
| Native integration | macOS windows, integrated chrome, child windows, clipboard, and file/folder selection | Native application menus, save dialogs, and a consistent public dialog API |
| Commands | Typed single-chord and context-aware multi-stroke keymaps | Broader physical-key vocabulary, timeout policy, and editor integration |
| Platforms | macOS native adapter and portable headless runtime | Linux/Windows native windows, input, text, clipboard, and rendering adapters |
| Validation and performance | Portable and native suites, bounded caches, and frame rollback | Cancellation/load stress, whole-process resource measurements, and reproducible results using the [benchmark method](benchmarks/method.md) |
| Package adoption | Local path dependency, source examples, and this API map | Release/distribution policy, API compatibility policy, and repeatable standalone consumer checks |

The usage guide includes a [suggested order for further work](zircon-ui-usage.md#extend-the-framework). That order is a recommendation, not a recorded release commitment.
