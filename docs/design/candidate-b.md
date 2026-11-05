> Historical design exploration. Superseded by the [user-supplied specification](../specification/framework-api-v0.1.md).

# Candidate B: retained nodes with explicit invalidation

This is an independent design sketch, not an implemented framework. It uses no NanoUI or GPUI source or dependency. Both design seats inherit the same model settings, so this is independent reasoning with reduced model diversity.

## Problem

Zircon needs a reusable native UI package, then an editor that imports that package. The document model and filesystem code can survive the rejected NanoUI implementation. The framework must own windowing, layout, input, text and rendering without absorbing editor behavior. macOS arm64 and Zig 0.17 are the first supported implementation target. Smaller binaries, lower memory use and better performance than Zed remain hypotheses until comparable measurements exist.

## Usage first

A counter demonstrates that the framework is independently useful:

```zig
const ui = @import("zircon_ui");

var app = try ui.App.init(allocator, .{ .name = "Counter" });
defer app.deinit();
var counter = Counter{ .value = 0 };
const window = try app.open(.{ .title = "Counter", .size = .{ 420, 300 } });
const label = try window.label(.{ .text = "0", .font = .body });
const increment = try window.button("Increment", .init(&counter, Counter.increment));
try window.setRoot(try window.column(.{ .gap = 12 }, &.{ label, increment }));
try app.run();
```

A callback changes application state and updates the relevant retained node:

```zig
fn increment(s: *Counter, event: ui.Activation) !void {
    s.value += 1;
    try event.window.setText(s.label, event.format("{d}", .{s.value}));
}
```

The editor is an application-owned custom element. Its node remains stable while text changes:

```zig
const editor = try window.custom(.{
    .state = &workspace.editor,
    .measure = Editor.measure,
    .paint = Editor.paint,
    .event = Editor.event,
    .text_input = Editor.textInput,
});
try window.setRoot(try window.column(.{}, &.{ toolbar, tabs, editor, status }));
// After an edit, invalidate the custom node rather than recreating its tree.
window.invalidate(editor, .content);
```

The framework accepts custom drawing through a scoped `Canvas`; the editor never receives an Objective-C object, Metal encoder or C transport struct. `Canvas.text` shapes text and returns logical metrics used by drawing and hit testing. Its reusable `TextLayout` is a framework handle, not a CoreText pointer.

## Shape

```zig
pub const Node = packed struct { slot: u32, generation: u32 };
pub const TextLayout = packed struct { slot: u32, generation: u32 };
pub const Invalidation = enum { content, layout };
pub const Event = union(enum) {
    pointer: PointerEvent,
    scroll: ScrollEvent,
    key: KeyEvent,
    action: Action,
    resize: Size,
};
pub const TextEdit = union(enum) {
    replace: Replacement,
    compose: Composition,
    commit_composition,
    set_selection: Selection,
};
pub const TextInput = struct {
    // Borrowed UTF-8 text and selection, valid during this callback only.
    read: *const fn (*anyopaque) TextSnapshot,
    edit: *const fn (*anyopaque, TextEdit) anyerror!void,
    caret_rect: *const fn (*anyopaque) Rect,
};
pub const Canvas = struct {
    pub fn rect(c: *Canvas, bounds: Rect, style: BoxStyle) !void;
    pub fn text(c: *Canvas, layout: TextLayout, at: Point, color: Color) !void;
    pub fn clipped(c: *Canvas, rect: Rect, draw: anytype) !void;
};
```

- `App` owns the native event loop and windows. Each `Window` owns its node arena, focus path, pointer capture, text layouts and scene buffers. App state remains caller-owned and must outlive registered callbacks.
- A node arena stores tagged node data with generational handles. Removed handles cannot silently refer to newly allocated nodes. Parents own child handles; inserting a node into two parents is refused. `remove` recursively releases its subtree.
- Retained widgets own their display data. String setters copy into the window's allocator before replacing old strings. A failed update preserves the previous usable tree. Event callback borrows cannot escape dispatch.
- Layout uses one measure and one arrange traversal. Initially support rows, columns, padding, gaps, fixed dimensions and flex grow. Do not promise CSS flexbox compatibility. Custom elements receive their final bounds.
- Each node has content and layout versions. Layout invalidation propagates to ancestors; content invalidation dirties drawing. Input dispatch uses arranged rectangles and the focus path. Pointer capture keeps drags on the originating node.
- Scene building records colored quads, clipped glyph quads and their ordered batches. The first version rebuilds the scene on any invalidation, while retaining the layout and text caches. More granular scene caching is optional later and does not change callers.
- The editor owns document bytes, history, selections, scrolling and syntax tokens. It submits only visible lines. It may cache `TextLayout` handles keyed by document line version and font. The framework owns shaping, rasterization, glyph storage and GPU lifetime.

This interface is deeper than a public frame pipeline. Callers create nodes, change content and receive events. They do not sequence measurement, hit testing, GPU submission or input-method state synchronization themselves. Explicit setters cost more than rebuilding a small view, but make idle work and ownership obvious.

## Modules and platform seam

```text
packages/zircon_ui/
  build.zig, build.zig.zon
  src/root.zig             public App, Window, Node, Canvas, event/text contracts
  src/window.zig           tree lifetime, invalidation, dispatch and frame scheduling
  src/tree.zig             node arena and row/column layout
  src/scene.zig            clipping and ordered drawing commands
  src/text.zig             text-layout cache and generational handles
  src/platform/macos.m     AppKit, CoreText, Metal and C bridge implementation
  src/platform/bridge.h    private validated C ABI
examples/counter.zig       standalone framework consumer
src/editor/               document/editing behavior
src/workspace/            file identities, tabs and disk operations
src/ui/                   editor custom element and chrome composition
```

The C seam transports immutable byte slices, geometry, event values and scene arrays. Zig owns application and framework state; Objective-C owns OS objects. The backend copies any bytes it needs after a C call. AppKit calls Zig only on the main thread. A frame's scene memory remains leased until the backend has copied its instances into a reusable Metal buffer. GPU completion controls buffer reuse, not a synchronous wait after each frame.

AppKit implements `NSTextInputClient`, forwards committed and marked text, and queries the focused `TextInput` interface. The backend converts UTF-16 ranges to byte ranges against the exact snapshot it queried; invalid or stale ranges are refused. Composition is one editor transaction from its original selection through commit or cancellation. Caret geometry is converted to screen coordinates for candidate placement. Key shortcuts and text composition are separate dispatch paths.

CoreText shapes runs with font fallback. Each cached layout retains the exact fallback fonts needed for glyph rasterization. Glyph keys include font identity, size, scale and glyph id. A fixed atlas has a generation; eviction invalidates layouts containing atlas locations, while text layouts may retain independent advances. Selection and pointer hit testing reuse the same shaping positions as paint. The first editor is left-to-right, single-selection and unwrapped; Unicode grapheme navigation and bidirectional editing must either be implemented or reported as limitations.

## First implementation and accepted tradeoffs

Build the standalone counter through this public package first, then implement the editor custom node. Start with a small persistent node arena, full scene rebuilds on changes, one native window, solid rectangles, rounded boxes and text. Native file dialogs, clipboard and guarded close belong to `Window` facilities; filesystem policy stays in Zircon.

- Accept a retained tree and explicit updates in exchange for stable handles and zero tree allocation during idle.
- Accept full scene rebuilds on invalidation in exchange for one coherent rendering path; retained layout and shaped text prevent the most expensive repeated work.
- Accept explicit cache budgets in exchange for occasional rerasterization. Initial defaults can cap shaped layouts at 4 MiB, glyph bitmap storage at 8 MiB and instance buffers at 8 MiB. Report exhaustion without corrupting the last scene.
- Accept macOS-only native support initially in exchange for testing one complete platform implementation. A second platform must satisfy the existing private seam without adding editor conditions.
- Accept custom element callbacks for the editor in exchange for keeping document and display-map policy out of the general toolkit.

## Verification and measurement

Test the node interface for lifetime, stale handles, reparenting refusal, resize layout, clipping, focus and pointer capture. Drive the counter and editor with the same framework events used by AppKit. Test typing, selection, undo, save, file conflict refusal, mouse dragging and composition replacement. Add offscreen rendering with actual CoreText and Metal; compare geometry and inspect screenshots at multiple scales. Run a real native journey before claiming native input is verified.

Measure release binary bytes, resident and physical footprint after opening the same file/project, idle CPU, cold startup, warm frame CPU time and GPU command completion time. Use a fixed corpus, identical viewport/scale, repeated samples and the same machine. Separate model-only edits from end-to-end latency. Record cache budgets, file sizes, build mode and whether GPU resources are included. Do not extrapolate a counter benchmark to Zed parity or claim a speedup without an equivalent measured baseline.

## Alternatives rejected and unresolved risks

An immediate-mode UI is simpler for tiny views, but repeatedly reconstructs widget descriptions and makes stable input ownership depend on caller-supplied keys. A public render pipeline exposes too much ordering and GPU lifetime knowledge. A native-controls-only framework hides OS behavior well but cannot demonstrate Zircon-owned text drawing and Metal rendering. A general entity/dependency graph adds ownership and scheduling machinery before the counter or editor requires it.

CoreText fallback, marked-text cancellation, AppKit accessibility and GPU resource exhaustion are the largest risks. Keep them in the framework tests and platform adapter, not duplicated in the editor. The first implementation step is the node arena and counter window, followed immediately by text input and an offscreen frame.
