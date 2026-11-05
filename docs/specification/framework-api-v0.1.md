# ZigGPUI — Full Framework API & Architecture Specification

Proposed architecture · Version 0.1

Goal: Design a fast, GPU-accelerated, cross-platform UI framework written in Zig, inspired by the architecture of Zed's GPUI, but with an API, ownership model, and runtime designed specifically for Zig.

I'm going to call the proposed framework ZigGPUI throughout this specification. The name is a placeholder.

This design targets Zig 0.17.1, the stable release announced on November 3, 2026. The code examples define a proposed API—not an existing implementation—and the lower-level signatures will need compiler validation as the implementation develops.&#x20;

[image](https://www.google.com/s2/favicons?domain=https://ziglang.org\&sz=32)

ziglang.org



## 1. The fundamental design decisions

Zed's GPUI constructs transient element trees from persistent entities, then performs layout, prepaint, and painting. Its context system provides controlled access to state, observers, events, and windows. These are the architectural features worth preserving.&#x20;

[image](https://www.google.com/s2/favicons?domain=https://github.com\&sz=32)

GitHub+1



For ZigGPUI, I recommend the following decisions:

| Concern           | Proposed design                                               |
| ----------------- | ------------------------------------------------------------- |
| Programming model | Hybrid declarative / retained                                 |
| State management  | Typed, generational entities                                  |
| UI representation | Frame-local element trees                                     |
| Interface system  | `comptime` contracts and generated type-erased vtables        |
| Memory            | Explicit allocators, frame arenas, persistent resource stores |
| Change detection  | Explicit notifications and dependency tracking                |
| Event handling    | Capture, target, bubble, and typed actions                    |
| Layout            | Flexbox first, Grid later                                     |
| GPU renderer      | Batched display-list renderer                                 |
| Text              | Shaping, glyph caching, selection, and IME                    |
| Async tasks       | Background workers posting commands to the UI thread          |
| Cross-platform    | Platform abstraction with interchangeable backends            |

The single most important distinction is that entities, element trees, and GPU resources have different lifetimes.

Persistent application state

Entity store · Documents · View models · Subscriptions

Temporary element tree

Render → Layout → Hit testing → Paint

GPU scene and resource cache

Draw commands · Glyph atlases · Textures · Pipelines

An entity may survive thousands of frames. An element usually survives only one frame. A GPU texture may survive many frames and must not be destroyed while the GPU is still using it.

This separation should influence every public API.

## 2. Public API: what application developers should write

The primary API should feel like Zig: explicit, typed, readable, and reasonably compact.

Here is the proposed complete counter application.

```

const std = @import("std");
const gpui = @import("ziggpui");

pub fn main(init: std.process.Init) !void {
    var app = try gpui.App.init(.{
        .allocator = init.gpa,
        .io = init.io,
        .renderer = .auto,
    });
    defer app.deinit();

    _ = try app.openWindow(Counter, .{
        .title = "ZigGPUI Counter",
        .width = 420,
        .height = 260,
    }, .{});

    try app.run();
}

const Counter = struct {
    count: i32 = 0,

    pub fn render(
        self: *const Counter,
        ui: *gpui.Ui,
    ) !gpui.Element {
        return try ui.column(.{
            .gap = 12,
            .padding = gpui.Insets.all(24),
        }, &.{
            try ui.textFmt(
                "Count: {d}",
                .{self.count},
            ),
            try ui.button(.{
                .label = "Increment",
                .on_click = ui.onClick(
                    Counter.increment,
                ),
            }),
        });
    }

    fn increment(
        self: *Counter,
        event: *gpui.Event(gpui.Click),
        cx: *gpui.Context(Counter),
    ) !void {
        _ = event;

        self.count += 1;
        cx.notify();
    }
};

```

This is the API I would want an ordinary Zig developer to learn first.

There are several deliberate choices here:

- `render` receives `*const Counter`, so rendering cannot directly modify the view's state.
- `Ui` handles allocation of temporary elements.
- `onClick` binds a method to the current entity using a typed adapter.
- The callback updates the persistent entity through a controlled context.
- `notify()` requests rendering work; it does not synchronously redraw the window.

The framework should not require users to manually initialize a GPU device, configure render passes, or implement an event loop for ordinary applications.

## 3. Core public modules and types

I would define the public module hierarchy as follows.

```
ziggpui
│
├── App
├── Window
├── WindowHandle
├── Entity(T)
├── Context(T)
├── Ui
├── Element
│
├── ui
│   ├── div
│   ├── column
│   ├── row
│   ├── text
│   ├── image
│   ├── button
│   ├── scroll
│   └── custom
│
├── layout
│   ├── Style
│   ├── Length
│   ├── Insets
│   ├── Constraints
│   └── LayoutResult
│
├── event
│   ├── Event(T)
│   ├── Handler(T)
│   ├── PointerEvent
│   ├── KeyEvent
│   ├── FocusEvent
│   └── Action
│
├── graphics
│   ├── Color
│   ├── Painter
│   ├── Scene
│   ├── ImageHandle
│   └── Renderer
│
├── text
│   ├── Font
│   ├── TextRun
│   ├── TextLayout
│   └── TextInput
│
└── runtime
    ├── Scheduler
    ├── Task
    ├── Dispatcher
    └── Platform
```

Application developers would normally import only `ziggpui` and use re-exported types. The internal modules remain available for advanced applications.

### The proposed API surface

These are the main operations I would expose.

| Type         | Public functions                                                        |
| ------------ | ----------------------------------------------------------------------- |
| `App`        | `init`, `deinit`, `run`, `openWindow`, `createEntity`, `update`, `read` |
| `Window`     | `setTitle`, `requestFrame`, `setFocus`, `setCursor`, `close`            |
| `Context(T)` | `notify`, `emit`, `observe`, `subscribe`, `createChild`, `spawn`        |
| `Ui`         | `div`, `row`, `column`, `text`, `button`, `custom`, `view`, `watch`     |
| `Event(T)`   | `stopPropagation`, `preventDefault`, `capturePointer`                   |
| `Painter`    | `fillRect`, `strokeRect`, `drawText`, `drawImage`, `pushClip`           |

The low-level renderer and platform APIs should be separate from these developer-facing operations.

## 4. `comptime` interfaces: Zig's alternative to Rust traits

Zig doesn't have Rust's trait system, but its compile-time generics are well suited to this problem.

I would use compile-time interface contracts combined with generated runtime dispatch tables.

This gives us two advantages: custom view implementations are validated during compilation, and the runtime can store different element types in a single tree.

### 4.1 The View contract

Any struct implementing the following method can function as a renderable view:

```
pub fn render(
    self: *const Self,
    ui: *gpui.Ui,
) !gpui.Element
```

There should be no need for a separate `implements View` declaration.

The framework can check for the declaration:

```

pub fn requireView(comptime T: type) void {
    if (!@hasDecl(T, "render")) {
        @compileError(
            @typeName(T) ++
            " must implement render()",
        );
    }
}

```

This is the initial structural check. The production adapter should additionally inspect the function's parameter and return types and reject incompatible signatures with descriptive compile errors.

For example, calling:

```
try app.openWindow(MyView, options, .{});
```

would instantiate a generic adapter for `MyView`. Invalid render methods would fail during compilation rather than when the window is created.

### 4.2 The custom Element contract

Custom elements need more control than ordinary views.

I would define the following contract:

```
const MyElement = struct {
    pub const LayoutState = struct {
        // State created during layout.
    };

    pub const PrepaintState = struct {
        // State created during prepaint.
    };

    pub fn requestLayout(...) !gpui.LayoutResult;
    pub fn prepaint(...) !PrepaintState;
    pub fn paint(...) !void;
};
```

The full intended signatures are:

```
pub fn requestLayout(
    self: *Self,
    cx: *gpui.LayoutCx,
) !gpui.LayoutResult;

pub fn prepaint(
    self: *Self,
    cx: *gpui.PrepaintCx,
    bounds: gpui.Rect,
    layout_state: *LayoutState,
) !PrepaintState;

pub fn paint(
    self: *Self,
    cx: *gpui.PaintCx,
    bounds: gpui.Rect,
    layout_state: *LayoutState,
    prepaint_state: *PrepaintState,
) !void;
```

`LayoutResult` contains a layout-node identifier and element-specific layout state. The element adapter stores both phase states in frame-owned memory.

This separation is intentional:

| Phase           | Responsibility                                                            |
| --------------- | ------------------------------------------------------------------------- |
| `requestLayout` | Establish size constraints and child layout requirements                  |
| `prepaint`      | Resolve final bounds, hit regions, focus, clipping and accessibility data |
| `paint`         | Append drawing commands to the scene                                      |

The custom-element system is critical for code editors, terminals, charts, virtualized lists, and other complex components.

### 4.3 Compile-time vtable generation

ZigGPUI should use type erasure internally, not expose dynamic dispatch everywhere.

A simplified element vtable would be:

```

const ElementVTable = struct {
    request_layout: *const fn (
        ptr: *anyopaque,
        cx: *LayoutCx,
    ) anyerror!LayoutId,

    prepaint: *const fn (
        ptr: *anyopaque,
        cx: *PrepaintCx,
    ) anyerror!void,

    paint: *const fn (
        ptr: *anyopaque,
        cx: *PaintCx,
    ) anyerror!void,

    deinit: *const fn (
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
    ) void,
};

```

The real vtable would also carry or reference the typed layout/prepaint state storage.

For every custom type `T`, a compile-time adapter would generate functions that cast the erased pointer back to `*T` and invoke the appropriate methods.

Conceptually:

```
pub fn elementAdapter(comptime T: type) type {
    return struct {
        fn paint(
            opaque: *anyopaque,
            cx: *PaintCx,
        ) anyerror!void {
            const self: *T =
                @ptrCast(@alignCast(opaque));

            try self.paintImpl(cx);
        }
    };
}
```

This short example illustrates type erasure; it is not the full three-phase adapter.

The actual implementation would validate the layout and paint signatures, enforce correct phase order, and store the generated function pointers in a single vtable per concrete type.

Design rule: use `comptime` to generate adapters, not to build an enormous compile-time component framework. Excessive specialization could increase compilation time and binary size.

## 5. Entity system: persistent, type-safe application state

This is the core of the framework.

I would not expose raw pointers as entity identities. Instead, each entity would be represented by a typed, generational handle.

### 5.1 Entity handle

```

pub fn Entity(comptime T: type) type {
    return struct {
        app_id: u32,
        slot: u32,
        generation: u32,

        pub const State = T;
    };
}

```

For example:

```
const editor: gpui.Entity(Editor) = ...;
const sidebar: gpui.Entity(Sidebar) = ...;
```

The type parameter prevents accidentally passing an editor entity to a function expecting a sidebar entity.

The application identifier, slot, generation, and runtime type metadata are checked when a handle is resolved.

### 5.2 Entity store internals

Internally, I would use a slab-style registry.

```
const EntitySlot = struct {
    generation: u32,
    type_tag: TypeTag,
    pointer: ?*anyopaque,
    vtable: *const EntityVTable,
    owner_scope: ScopeId,
    borrow_state: BorrowState,
    version: u64,
};
```

Entity objects should be allocated in stable storage.

Why stable storage matters: a callback receives a temporary `*T` reference. Growing the slot array must not move the underlying `T` while that reference is active.

An entity slot refers to the allocated object; it does not directly contain the object.

The `EntityVTable` handles type-specific destruction and optional lifecycle operations.

### 5.3 Entity ownership in Zig

This is where I would intentionally differ from Rust GPUI.

Zig does not automatically run destructors when arbitrary struct values are copied or leave scope. Therefore, an `Entity(T)` handle should be non-owning.

Ownership should belong to explicit scopes:

- Application scope: shared global entities.
- Window scope: the root entity and window-owned state.
- Entity scope: child entities owned by another entity.

A `Context(T)` could create a child entity like this:

```
const child = try cx.createChild(
    DocumentView,
    .{ .document_id = 42 },
);
```

When the owner entity is destroyed, its owned children are destroyed recursively.

Other components may hold `Entity(DocumentView)` handles, but those handles do not prolong its lifetime.

A stale handle should produce `error.EntityNotFound`, not access freed memory.

The runtime must also handle generation wraparound safely, such as by retiring slots that can no longer be safely reused.

### 5.4 Reading and updating entities

I would offer callback-based access to avoid exposing long-lived pointers.

```
try app.update(
    editor,
    Editor.insertText,
    .{"Hello"},
);
```

The corresponding method could be:

```
fn insertText(
    self: *Editor,
    cx: *gpui.Context(Editor),
    text: []const u8,
) !void {
    try self.document.insert(text);
    cx.notify();
}
```

This is a proposed generic dispatcher: the framework resolves the entity, borrows it mutably, calls `insertText`, and releases the borrow when the method returns.

For reading:

```
const length = try app.read(
    editor,
    Editor.getLength,
    .{},
);
```

With:

```
fn getLength(self: *const Editor) usize {
    return self.document.length();
}
```

Returned values must not contain references into the entity unless the framework explicitly controls their lifetime. For the primary API, I would require returned snapshots or values owned by the caller.

### 5.5 Runtime borrowing rules

Because Zig does not have a Rust borrow checker, ZigGPUI should enforce entity access rules at runtime.

I would use:

- Multiple simultaneous immutable reads.
- Only one mutable borrow at a time.
- No mutable borrow while readers are active.
- No reentrant update of the same entity.
- No retaining entity pointers after an access callback returns.

Violations should return `error.BorrowConflict` from fallible access APIs and emit useful diagnostics in debug builds.

The public `Context(T)` is valid only during its callback. It must not be retained by background tasks.

## 6. State change notifications and reactive rendering

Not every state mutation needs to redraw the entire application.

I would provide two mechanisms.

Explicit notification is the simplest:

```
self.count += 1;
cx.notify();
```

The framework marks the entity as changed and schedules the views that depend on it.

Tracked reads handle dependencies between entities:

```
const name = try ui.watch(
    user_entity,
    User.displayName,
    .{},
);
```

This call reads the user's name and registers the current view as dependent on that entity.

When the user entity notifies, the dependent view becomes dirty.

### Observer API

I would distinguish between observing state changes and subscribing to specific events.

```
try cx.observe(
    document_entity,
    Editor.documentChanged,
);
```

For typed events:

```
try cx.subscribe(
    document_entity,
    DocumentSaved,
    Editor.onDocumentSaved,
);
```

Notifications represent invalidation; events represent something that happened.

For example, changing document contents should notify observers, while successfully saving a document may emit a `DocumentSaved` event.

### Transaction processing

I would make mutations transactional at the event-loop level.

Event handler updates one or more entities

Changes and notifications are collected

Observer effects execute in a controlled queue

Dependent views and windows become dirty

One coalesced frame is scheduled

This prevents three consecutive `notify()` calls from necessarily causing three rendered frames.

Notifications should be processed after the current mutable borrow is released. Observer callbacks must never receive a pointer into an entity that is still being mutably accessed.

The initial version should support explicit notifications and view-level dependency tracking. Fine-grained property tracking can come later.

## 7. Element trees and UI construction

For the UI layer, I would avoid exposing heap-allocated polymorphic objects to application developers.

Instead, `Ui` should operate as a frame-local builder.

### 7.1 Element handles

The public `Element` can be a small handle:

```
pub const Element = struct {
    index: u32,
    frame_epoch: u64,
};
```

The actual element data lives inside the current frame's arena.

For example:

```
const heading = try ui.text("Settings");

const save = try ui.button(.{
    .label = "Save",
    .on_click = ui.onClick(Settings.save),
});

return try ui.column(.{
    .gap = 16,
}, &.{ heading, save });
```

The `column` method copies the supplied child handles into its frame-owned storage. This is important because `&.{ heading, save }` is a temporary slice.

A frame epoch lets the runtime detect handles accidentally reused in a later frame.

### 7.2 Internal representation

I would use an indexed tree with separate arrays for frequently accessed data.

A simplified version:

```

pub const Node = struct {
    parent: ?NodeId,
    first_child: ?NodeId,
    next_sibling: ?NodeId,

    kind: NodeKind,
    style_id: StyleId,
    element_id: ?ElementId,

    flags: NodeFlags,
};

pub const NodeKind = union(enum) {
    container: ContainerData,
    text: TextData,
    image: ImageData,
    custom: CustomElementData,
};

```

An indexed tree offers benefits over independently allocated nodes:

- Better memory locality.
- Cheap parent and child traversal.
- Compact hit-testing information.
- No pointer instability when internal arrays grow.
- Easier serialization for debugging and inspection.

Element payloads and specialized state can be stored separately.

### 7.3 Stable element identity

An element needs two different identifiers.

`NodeId` identifies a node during the current frame.

`ElementId` identifies a logical element across frames.

For example:

```
try ui.key(
    .{ .string = "search-input" },
    try ui.textInput(.{
        .placeholder = "Search...",
    }),
);
```

The frame-local `NodeId` changes when the tree is rebuilt, but the logical identity remains stable.

This allows the framework to preserve focus, scroll position, animation state, and text-editing state when a view is reconstructed.

For repeated elements, identities should be based on stable application keys, not just child position.

I would define logical identity using the containing keyed scope, key type, and key value. Hashes can accelerate lookup, but equality checks should prevent collisions from confusing two elements.

Important: persistent application data should live in entities. Stable element identity should preserve small UI-specific state, not become a second competing application-state system.

## 8. Memory ownership and lifetimes

This requires a formal contract.

Memory lifetime model

| Application allocator | Entities, subscriptions, assets, caches, platform objects |
| --------------------- | --------------------------------------------------------- |
| Window scope          | Root entity, focus state, window resources                |
| Frame arena           | Elements, styles, handlers, temporary text                |
| GPU lifetime          | Textures, upload buffers, in-flight commands              |

### 8.1 Double-buffered frame storage

A single arena cleared at the start of every frame is not sufficient.

The framework may still need the previous frame's handlers and hit-testing tree while constructing the next frame.

I would give each window a committed frame and a staging frame.

```
Committed frame N
   ├── Element tree
   ├── Event handlers
   ├── Hit-test data
   └── Focus/accessibility data

Staging frame N+1
   ├── New element tree
   ├── New layout
   ├── New event handlers
   └── New scene
```

The process would be:

1. Dispatch incoming input against committed frame N.
2. Build frame N+1 in a separate arena.
3. Perform layout and prepaint.
4. Construct the new GPU scene.
5. If construction succeeds, atomically commit the new frame.
6. Retire frame N only when no CPU-side dispatch operation references it.
7. Reset the retired arena after executing any necessary cleanup hooks.

This also provides a useful failure policy: if rendering frame N+1 fails due to allocation or another recoverable error, the previous valid frame can remain displayed.

### 8.2 Arena destruction is not object destruction

Zig's arena reset frees storage, but it does not automatically call custom deinitializers.

This matters for frame nodes containing references to external resources.

I would maintain a cleanup list:

```
const FrameCleanup = struct {
    object: *anyopaque,
    destroy: *const fn (*anyopaque) void,
};
```

Before resetting a frame arena, the runtime invokes the cleanup hooks for objects requiring explicit release.

Objects containing only plain data need no such hook.

### 8.3 Lifetime guarantees

The public documentation should clearly state:

- `*Ui`, `*Context(T)`, and `*Painter` are temporary and must not be retained.
- `Element` is valid only during its originating frame.
- `Entity(T)` can be stored persistently but does not keep its target alive.
- Persistent data cannot borrow slices from a frame arena.
- Frame callbacks cannot capture pointers to temporary render data.
- GPU resources are released only after relevant GPU submissions complete.

Zig cannot statically prove every one of these rules. The implementation must combine API design, runtime validation, debug checks, and tests.

## 9. Event dispatch system

I would implement a DOM-like propagation model, with GPUI-style semantic actions layered on top.

### 9.1 Event types

The low-level event types should include:

```
pub const PointerEvent = struct {
    pointer_id: u32,
    position: Point,
    button: MouseButton,
    modifiers: Modifiers,
};

pub const KeyEvent = struct {
    key: Key,
    modifiers: Modifiers,
    repeat: bool,
};

pub const ScrollEvent = struct {
    position: Point,
    delta: Vector2,
    phase: ScrollPhase,
};
```

Keyboard text composition should be handled separately from physical key events, so IME and complex input methods work correctly.

### 9.2 Typed event wrapper

I would make propagation controls part of a typed event:

```

pub fn Event(comptime T: type) type {
    return struct {
        data: T,
        control: *DispatchControl,

        pub fn stopPropagation(
            self: *@This(),
        ) void {
            self.control.stop_propagation = true;
        }

        pub fn preventDefault(
            self: *@This(),
        ) void {
            self.control.prevent_default = true;
        }
    };
}

```

The framework owns `DispatchControl`; application handlers must not retain it after dispatch.

### 9.3 Dispatch phases

Example: clicking a button inside a panel

Window root

1 capture / 5 bubble

Panel

2 capture / 4 bubble

3 · Button target

For a pointer click:

1. Hit-test the committed frame, respecting clipping, z-order, transforms, and pointer-event policies.
2. Build a path from root to target.
3. Execute capture handlers from root toward the target.
4. Execute the target handler.
5. Execute bubble handlers from target toward the root.
6. Perform the default action if it was not prevented.

`stopPropagation()` stops movement to additional nodes. `preventDefault()` suppresses the default behavior, but does not automatically stop propagation.

Callbacks should be able to update entities during event dispatch, but those changes must not replace or free the active dispatch tree until dispatch is complete.

Entity destruction requested from a handler should be deferred until it is safe to finalize.

### 9.4 Handlers without unsafe captures

The ergonomic API would be:

```
.on_click = ui.onClick(Counter.increment)
```

Internally, `ui.onClick` knows which entity is rendering the view.

It stores:

```
Owner entity handle
Event type metadata
Generated method adapter
Optional owned callback payload
```

It does not store a raw `*Counter` or a pointer to the render stack.

At dispatch time, the runtime resolves the entity handle and invokes the compiled adapter using a temporary `Context(Counter)`.

This is important for both safety and performance.

## 10. Keyboard actions and focus

I would implement keyboard actions as first-class application concepts, not just key-down callbacks.

Zed's GPUI uses context-sensitive actions and key dispatch extensively, which is particularly useful for editors.&#x20;

[image](https://www.google.com/s2/favicons?domain=https://github.com\&sz=32)

GitHub



For example:

```

const SaveDocument = struct {};
const Undo = struct {};
const Find = struct {};

pub fn configure(app: *gpui.App) !void {
    try app.bindKey(.{
        .context = "editor",
        .key = "Primary+S",
        .action = SaveDocument{},
    });

    try app.bindKey(.{
        .context = "editor",
        .key = "Primary+Z",
        .action = Undo{},
    });
}

```

`Primary` would resolve to the platform's conventional command modifier.

A view registers the corresponding typed action handler:

```
ui.onAction(
    SaveDocument,
    Editor.saveDocument,
);
```

I would keep the action system independent of physical key combinations. That allows actions to be triggered by keyboard shortcuts, menu items, buttons, command palettes, or programmatic dispatch.

Focus should be a persistent per-window state machine using generational `FocusId` handles, rather than relying on pointers into the current element tree.

The framework should also support pointer capture, focus scopes, tab traversal, modal focus trapping, and keyboard accessibility.

## 11. Layout and styling API

I would make styling familiar to developers who know CSS, but represent it using Zig structures rather than strings.

### 11.1 Style structure

A proposed style definition:

```

pub const Style = struct {
    display: Display = .flex,
    direction: Direction = .column,

    width: Length = .auto,
    height: Length = .auto,

    min_width: Length = .auto,
    min_height: Length = .auto,
    max_width: Length = .auto,
    max_height: Length = .auto,

    padding: Insets = .{},
    margin: Insets = .{},
    gap: f32 = 0,

    align_items: Align = .stretch,
    justify_content: Justify = .start,

    flex_grow: f32 = 0,
    flex_shrink: f32 = 1,

    background: ?Color = null,
    border: Border = .{},
    radius: f32 = 0,
    opacity: f32 = 1,
};

```

### 11.2 Dimensions

Use a typed union for flexible dimensions:

```
pub const Length = union(enum) {
    auto,
    px: f32,
    percent: f32,
    rem: f32,
    viewport_width: f32,
    viewport_height: f32,
};
```

All layout dimensions should initially be expressed in logical pixels. Device-pixel conversion belongs in the rendering layer.

Percentage and intrinsic sizing must have clearly specified behavior for unresolved or indefinite parent sizes.

### 11.3 Example UI

```

return try ui.row(.{
    .gap = 16,
    .padding = gpui.Insets.all(20),
    .background = gpui.Color.rgb(0x121212),
}, &.{
    try ui.column(.{
        .width = .{ .px = 240 },
        .gap = 8,
    }, &.{
        try ui.text("Files"),
        try ui.view(sidebar_entity),
    }),

    try ui.view(editor_entity),
});

```

The styling model should support themes and reusable style values.

For example:

```
const Theme = struct {
    background: gpui.Color,
    foreground: gpui.Color,
    accent: gpui.Color,
    border: gpui.Color,
};
```

I would avoid making Tailwind-style methods the only way to construct styles. They could be provided later as an optional convenience layer.

### 11.4 Layout engine implementation

The first implementation should prioritize:

- Flex direction, grow, shrink, alignment and gaps.
- Fixed, percentage, auto and intrinsic dimensions.
- Min/max constraints.
- Padding, margin and borders.
- Nested scrolling containers.
- Text measurement.
- Absolute positioning and overlays.

CSS Grid, complex intrinsic sizing, and advanced transforms can come later.

The initial layout engine could be a native Zig implementation of a deliberately limited flexbox subset. It would be unrealistic to promise complete browser layout behavior immediately.

## 12. GPU rendering architecture

The renderer should operate on a platform-independent scene.

```
Elements
    ↓
Layout and paint
    ↓
Scene / Display List
    ↓
Draw command processing
    ↓
Batch and upload preparation
    ↓
Graphics backend
    ↓
GPU
```

### 12.1 Scene and draw commands

I would model the render output as a sequential command stream:

```

pub const DrawCommand = union(enum) {
    quad: QuadCommand,
    glyph_run: GlyphRunCommand,
    image: ImageCommand,
    path: PathCommand,

    push_clip: ClipCommand,
    pop_clip,

    push_transform: Transform,
    pop_transform,
};

```

The drawing API for custom elements might look like:

```
cx.painter.fillRect(.{
    .bounds = bounds,
    .color = gpui.Color.rgb(0x202020),
    .radius = 8,
});

try cx.painter.drawText(.{
    .text = "Hello Zig",
    .position = .{ .x = 12, .y = 16 },
    .font_size = 16,
    .color = gpui.Color.white,
});
```

`drawText` must use a shaped text run internally, not draw one character at a time without shaping.

### 12.2 Batching strategy

The renderer should group compatible draws while preserving painter's order.

My initial approach:

| Primitive          | GPU representation                           |
| ------------------ | -------------------------------------------- |
| Rectangles         | Instanced quads                              |
| Rounded rectangles | Analytic corner shader                       |
| Borders            | Quad parameters or geometry                  |
| Glyphs             | Texture-atlas-backed quads                   |
| Images             | Textured quads                               |
| Paths              | Tessellated geometry or specialized renderer |
| Shadows            | Analytic shader or cached effects            |

Batching must respect ordering, blending, clipping and overlapping content. Sorting every draw by texture is not always safe because it can change the appearance.

### 12.3 Backend abstraction

I would define a small internal backend interface:

```
pub const GraphicsBackend = struct {
    pub fn createSurface(...) !Surface;
    pub fn createBuffer(...) !Buffer;
    pub fn createTexture(...) !Texture;
    pub fn beginFrame(...) !Frame;
    pub fn submit(...) !void;
    pub fn present(...) !void;
};
```

This is an interface sketch, not an implementable standalone struct.

The real backend would use generated function tables or platform-specific implementations behind opaque handles.

Target rendering backends

macOS

Metal

Windows

Direct3D 12

Linux

Vulkan

I would start with Metal if macOS is the first development platform. Implementing all three GPU backends simultaneously would slow down architectural validation considerably.

The renderer must manage GPU resource lifetimes using submission completion or fence information. It cannot destroy a texture just because the application removed its image element.

## 13. Text rendering and text input

For an editor-capable framework, text is one of the most technically demanding subsystems.

It needs a dedicated engine rather than simply rasterizing Unicode code points.

I would separate it into three components.

Text shaping: Convert Unicode text into positioned glyph runs using font selection, shaping, bidirectional text handling, and grapheme segmentation. HarfBuzz, FreeType, and Unicode libraries are potential building blocks.

Text layout: Measure and wrap shaped runs, resolve line heights, selection regions, hit-testing positions, and cursor positions.

Text rendering: Cache glyph bitmaps or other glyph representations in atlases and submit efficient draw commands.

The public API could include:

```
const layout = try ui.textLayout(.{
    .text = document_text,
    .font_size = 14,
    .max_width = 600,
    .wrap = .word,
});

const selection = layout.selectionRects(
    start_position,
    end_position,
);
```

Text editing requires additional persistent state: selections, composition ranges, undo information, and scroll position.

I would make text-input integration a dedicated platform capability rather than assuming all editing can be implemented using keyboard events alone.

Accessibility, IME, bidirectional text, emoji, and font fallback should be included in the architectural design from the beginning, even if their full implementations are delivered later.

## 14. Asynchronous operations and background tasks

A desktop framework needs asynchronous work for file operations, networking, language servers, image decoding, and background indexing.

With Zig 0.17, I would integrate with `std.Io` rather than designing the framework around an outdated or independent asynchronous model.&#x20;

[image](https://www.google.com/s2/favicons?domain=https://ziglang.org\&sz=32)

The Zig Programming Language+1



### The thread ownership model

All entity mutations and UI rendering should occur on the UI thread in version 0.1.

Workers can process data elsewhere, but they cannot directly mutate application entities.

They send typed messages back to the application.

A proposed API:

```
const LoadResult = struct {
    document_id: u64,
    contents: []u8,
};

const task = try cx.spawn(.{
    .work = loadDocument,
    .on_complete = Editor.documentLoaded,
});
```

The actual task API must specify how input arguments, returned allocations, cancellation, and error results are owned.

Internally:

```
UI thread
   │
   ├── Spawn background work
   │           │
   │           ▼
   │       Worker
   │           │
   │       Process data
   │           │
   │       Owned result
   │           │
   ▼           ▼
UI message queue
   │
   ▼
Validate entity handle
   │
   ▼
Invoke completion handler
   │
   ▼
Update state and notify
```

### Task lifetime rules

I would use explicit task scopes.

A task created for a window or entity should normally be cancelled when its owner is destroyed.

Tasks that intentionally outlive a window should be attached to the application scope.

Since Zig has no automatic `Send` trait, generic compile-time checks cannot prove arbitrary captured values are safe to move between threads. I would require explicitly owned messages, avoid borrowing UI-thread objects, and provide narrowly typed APIs for crossing the thread boundary.

Task cancellation should be cooperative. The framework must not assume an OS operation can be terminated instantly.

## 15. Error handling

This part should feel distinctly Zig-native.

Constructing a UI tree, creating GPU resources, and opening windows can all fail. I would not hide these failures behind panics.

Public functions should use error unions where appropriate.

```
pub const UiError = error{
    OutOfMemory,
    InvalidElement,
    InvalidStyle,
    InvalidFrame,
};

pub const EntityError = error{
    EntityNotFound,
    WrongApplication,
    BorrowConflict,
};
```

I would also define policies for rendering failures.

| Failure                          | Proposed behavior                                |
| -------------------------------- | ------------------------------------------------ |
| Temporary frame allocation fails | Keep previous valid frame, report error          |
| Entity handle is stale           | Return `EntityNotFound`                          |
| Invalid frame element            | Return error; detailed debug diagnostic          |
| GPU device is lost               | Recreate device/resources if supported           |
| Window creation fails            | Return error to caller                           |
| Background task fails            | Deliver typed result/error to completion handler |
| Invalid custom-element phase     | Treat as a framework invariant violation         |

The runtime should support a window-level error handler for situations where a rendering failure is recoverable but needs application-specific reporting.

Memory corruption and violated internal invariants should not be silently ignored.

## 16. Full lifecycle of a frame

Here is how I would connect the systems.

1\. Platform event

Mouse, keyboard, resize, task completion

2\. Event dispatch

Hit testing, focus path, callbacks

3\. Entity transaction

Mutations, events, notifications

4\. Render dirty views

Build frame-local element tree

5\. Layout and prepaint

Bounds, clipping, hitboxes, accessibility

6\. Paint and GPU submission

Display list, batching, present

7\. Commit and retire

Swap frames, cleanup when safe

### The scheduler

The scheduler should be event-driven, not a busy loop that redraws continuously.

A window becomes dirty when its state changes, it is resized, its content needs an animation frame, or a platform resource changes.

For version 0.1, I would redraw an entire dirty window. That is simpler to make correct.

Later versions could cache retained render fragments for independent views and reuse unchanged scene segments. This optimization requires careful tracking of layout dependencies, clipping, z-order, text resources, and invalidation regions.

I would not attempt sophisticated incremental scene reuse before the basic renderer is working correctly.

## 17. Advanced components the architecture should support

Once the core is stable, the public API can expand without requiring major changes to the entity and element systems.

| Component            | Proposed API             |
| -------------------- | ------------------------ |
| Scroll container     | `ui.scroll(...)`         |
| Virtualized list     | `ui.virtualList(...)`    |
| Text input           | `ui.textInput(...)`      |
| Image                | `ui.image(...)`          |
| Overlay/popover      | `ui.portal(...)`         |
| Animation            | `ui.animate(...)`        |
| Canvas               | `ui.custom(Canvas, ...)` |
| External entity view | `ui.view(entity)`        |
| Theme                | `ui.theme()`             |
| Accessibility        | `ui.accessibility(...)`  |

I would place interactive controls in a separate component package built on the core framework.

That lets the framework remain useful for teams that want to implement their own design systems.

## 18. Internal project structure

I would organize the implementation into a small core and independently testable subsystems.

```
ziggpui/
│
├── build.zig
├── build.zig.zon
│
├── src/
│   ├── root.zig
│   │
│   ├── app/
│   │   ├── app.zig
│   │   ├── window.zig
│   │   └── scheduler.zig
│   │
│   ├── entity/
│   │   ├── entity.zig
│   │   ├── store.zig
│   │   ├── borrow.zig
│   │   ├── scope.zig
│   │   └── observer.zig
│   │
│   ├── ui/
│   │   ├── ui.zig
│   │   ├── element.zig
│   │   ├── adapter.zig
│   │   ├── tree.zig
│   │   ├── style.zig
│   │   └── components/
│   │
│   ├── layout/
│   │   ├── flex.zig
│   │   ├── measure.zig
│   │   └── geometry.zig
│   │
│   ├── event/
│   │   ├── dispatch.zig
│   │   ├── hit_test.zig
│   │   ├── focus.zig
│   │   ├── action.zig
│   │   └── keyboard.zig
│   │
│   ├── graphics/
│   │   ├── scene.zig
│   │   ├── renderer.zig
│   │   ├── atlas.zig
│   │   └── backends/
│   │       ├── metal.zig
│   │       ├── vulkan.zig
│   │       └── d3d12.zig
│   │
│   ├── text/
│   │   ├── shaping.zig
│   │   ├── layout.zig
│   │   └── input.zig
│   │
│   ├── platform/
│   │   ├── macos/
│   │   ├── windows/
│   │   └── linux/
│   │
│   ├── runtime/
│   │   ├── tasks.zig
│   │   ├── queue.zig
│   │   └── executor.zig
│   │
│   └── testing/
│       ├── harness.zig
│       └── headless.zig
│
├── examples/
│   ├── counter/
│   ├── todo/
│   ├── text_editor/
│   └── custom_canvas/
│
└── tests/
    ├── entity_tests.zig
    ├── layout_tests.zig
    ├── event_tests.zig
    ├── lifetime_tests.zig
    └── renderer_tests.zig
```

I would also keep GPU shaders, platform interface definitions, and generated resources in dedicated directories once the backends are implemented.

## 19. Testing strategy

A framework like this needs much more than unit tests for buttons.

I would build a headless test runtime early, capable of constructing views and dispatching synthetic input without opening an actual operating-system window.

The highest-priority tests would include:

| Area          | Critical invariant                                              |
| ------------- | --------------------------------------------------------------- |
| Entity store  | Destroyed handles cannot access reused slots                    |
| Borrowing     | Conflicting entity access is rejected                           |
| Ownership     | Destroying an owner releases all owned children                 |
| Events        | Capture, target, bubble, and cancellation obey documented order |
| Frame storage | No handler is invoked after its arena is retired                |
| Layout        | Identical constraints produce deterministic geometry            |
| Focus         | Focus remains stable across element-tree rebuilds               |
| Renderer      | Draw command ordering and clipping remain correct               |
| GPU lifecycle | Resources aren't released while submissions use them            |
| Async         | Cancelled tasks cannot update destroyed entities                |

I would include fuzz tests for entity handle reuse, tree construction, layout constraints, and event routing.

For the renderer, golden-image testing across known scenes is also useful, although platform differences in fonts and rasterization require carefully controlled reference environments.

## 20. What I would actually implement, in order

The entire design is large, but its foundations can be built incrementally.

1

Entity runtime and test harness

Generational registry, typed read/update, scope ownership, borrow checking, and lifecycle tests.

Deliverable: reliable persistent state without any GPU dependencies.

2

Frame-local UI builder

`Ui`, `Element`, compile-time view contracts, frame arenas, tree construction, and basic styling.

Deliverable: applications that produce inspectable element trees.

3

Layout, rendering and native window

Flex layout, native window creation, one GPU backend, rectangles, and basic shaped text.

Deliverable: a visible UI with text and layout.

4

Interactive application runtime

Hit testing, event propagation, handlers, notifications, focus, buttons, and keyboard actions.

Deliverable: a working counter and settings application.

5

Editor-grade capabilities

Text input, IME, selection, scrolling, virtualization, asynchronous tasks, and accessibility.

Deliverable: a small, functional text editor.

6

Optimization and additional platforms

Scene caching, profiling, GPU batching improvements, and additional platform backends.

Deliverable: a measured, portable framework suitable for larger applications.

## 21. Decisions I would lock in before writing code

These are the architectural choices most likely to cause expensive rewrites if left unresolved.

| Decision                                       | My recommended answer                         |
| ---------------------------------------------- | --------------------------------------------- |
| Does `Element` own its memory?                 | No, the frame owns it                         |
| Does `Entity(T)` own its state?                | No, an explicit scope owns it                 |
| Can views mutate state during rendering?       | No                                            |
| Can callbacks capture pointers from render?    | No                                            |
| Are notifications synchronous redraws?         | No, they schedule work                        |
| Can workers access entities directly?          | No, use owned messages                        |
| Are custom elements type-erased?               | Yes, using comptime-generated adapters        |
| Is rendering backend-specific?                 | No, the scene is platform-neutral             |
| Should all views be diffed like a virtual DOM? | No, start with explicit invalidation          |
| Should widgets live inside the core?           | Only essential primitives                     |
| Should errors be visible?                      | Yes, through Zig error unions and diagnostics |

One additional point: GPUI's crate is licensed under Apache 2.0, but if you copy or adapt actual implementation code, you need to comply with the license and applicable notices. A Zig-native design inspired by its publicly documented architecture is a different approach from mechanically porting its Rust implementation.&#x20;

[image](https://www.google.com/s2/favicons?domain=https://github.com\&sz=32)

GitHub



## Final recommendation: the API I would standardize

The core programming model should revolve around only six operations:

```
// Persistent state
const entity = try cx.createChild(T, value);

// Read
const result = try cx.read(entity, T.reader, .{});

// Update
try cx.update(entity, T.operation, .{});

// Declare UI
const element = try ui.column(style, children);

// Bind an event
const handler = ui.onClick(T.handleClick);

// Request rerendering
cx.notify();
```

Everything else should build on these foundations.

I would prioritize three characteristics above all others:

First, explicit ownership. ZigGPUI should make it difficult to accidentally retain invalid pointers, leak entities, or free memory while an event or GPU command still needs it.

Second, lightweight application code. Ordinary developers should be able to construct sophisticated UI trees using readable Zig struct literals, without learning the entire renderer and runtime.

Third, extensibility without overhead. Advanced developers should be able to implement their own elements, text renderers, layouts, virtualized lists, or GPU-backed components using compile-time interfaces.

The first serious benchmark for this architecture should be a small editor—not just a counter. An editor exercises persistent state, custom painting, keyboard input, text measurement, scrolling, focus, and frequent incremental updates.

If those systems work together cleanly, we have the foundations of a genuinely useful Zig-native alternative inspired by Zed's GPUI.

Core references: [Zed GPUI source](https://github.com/zed-industries/zed/tree/main/crates/gpui?utm_source=chatgpt.com) · [GPUI element lifecycle](https://github.com/zed-industries/zed/blob/main/crates/gpui/src/element.rs?utm_source=chatgpt.com) · [GPUI contexts](https://github.com/zed-industries/zed/blob/main/crates/gpui/docs/contexts.md?utm_source=chatgpt.com) · [Zig 0.17.1 language reference](https://ziglang.org/documentation/0.17.1/?utm_source=chatgpt.com)