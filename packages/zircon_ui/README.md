# Zircon UI

A framework in Zig with explicit ownership. The public package currently provides a headless entity runtime, declarative frame builder, and layout. This core loads no native window system, text engine, or GPU. The text/Metal modules are tested separately; see the [implementation status](../../docs/status.md).

```zig
const ui = @import("zircon_ui");
var app = try ui.App.init(.{ .allocator = allocator });
defer app.deinit();
const counter = try app.createEntity(Counter, .{});
try app.update(counter, Counter.increment, .{});
const value = try app.read(counter, Counter.value, .{});
```

An update method receives `(*Self, *ui.Context(Self), ...)`; a read receives `(*const Self, ...)`. Call `cx.notify()` after a change. `takeFrameRequest()` consumes a coalesced invalidation request, rather than drawing synchronously.

Entities are non-owning generational handles. Application, explicit scope, or parent entity owns each stable object. `createChild` transfers ownership to the current entity. Destroying an owner releases its children first. Optional entity cleanup has signature `pub fn deinit(self: *Self, allocator: std.mem.Allocator) void`.

Callbacks cannot retain entity pointers. Access results must be pointer-free values; copy strings or other owned snapshots into a caller-owned output argument. Conflicting access returns `BorrowConflict`, and callbacks release borrows even on error. A copied context expires when its callback returns. `Context.destroy` defers destruction until the outer transaction ends. Calls from another thread return `WrongThread`.

Generation-exhausted slots are retired. Ownership depth is capped at 128 to bound recursive destruction. Destructors may release their own resources but cannot reenter the application.

The full planned API is in the repository specification. Windows, rendering, observers, typed subscriptions, and workers are later milestones and are not implied by the entity API.

## Frame-local rendering

Typed event payloads and direct handler calls work. Propagation controls, hit testing, and automatic input dispatch will be added with the dispatcher. `App.init` currently accepts only an allocator; I/O scheduling and renderer selection are not exposed yet.

A view implements `pub fn render(self: *const Self, ui: *zircon_ui.Ui) !zircon_ui.Element`. `Ui.column`, `row`, `div`, `text`, `textFmt`, and `button` build indexed trees. Strings and child slices are copied into the staging arena. `ui.onClick(Self.method)` records the owner handle and a generated typed adapter, never a pointer to the render stack.

`testing.Harness.render(entity)` performs a borrowed const render and commits only after successful tree validation. A failed render discards staging storage and preserves the committed tree and its handlers. Element epochs reject foreign or retired handles; keys compare by type and value inside their containing keyed scope. No layout or native drawing is implied by constructing a tree.

Frames invoke registered cleanup hooks in reverse registration order before resetting their arena. Registering a hook transfers cleanup responsibility only on success. Dispatch pins the committed tree; replacing it during active dispatch returns `DispatchActive`.

The root `check` target includes compile-failure fixtures for mutable render methods, invalid click-handler signatures, and borrowed access results. The headless counter example builds and inspects the same tree that a later native window will lay out and paint.

## Flex layout subset

`layout.calculate(allocator, committed_frame, root, constraints, measurer)` produces owned bounds for one frame epoch. `deinit` the result. Rows/columns support padding, positive margins, gaps, flex grow/shrink, min/max freezing, cross-axis alignment, and main-axis justification. Dimensions support logical pixels, rem, viewport units, and percentages against the available parent content box. Intrinsic auto/percentage cycles do not implement browser CSS semantics. Flex wrapping, grid, and baseline alignment are not implemented.

Inject text metrics through `layout.Measurer`. `layout.FixedMetrics` is a deterministic headless-test adapter, not a font shaper. Production layout will use the native shaping module. Invalid/nonfinite dimensions, invalid measurements, arithmetic overflow, excessive depth, and allocation failures return errors. A layout result cannot be reused with another frame epoch.

## Native graphics layer

The macOS shaping and offscreen Metal backend are independently implemented in Zig. `platform/macos/objc.zig` calls the system runtime directly. `text/shaping.zig` owns CoreText layouts and UTF-8/UTF-16 conversion. `graphics/backends/metal.zig` owns glyph rasterization, ordered instanced drawing, clipping, and GPU buffer leases. The `.metal` file is GPU shader source. There are no `.h`, `.c`, or `.m` implementation files and no NanoUI/GPUI dependency.

Run the separate `./tools/zig build test-native` target from the repository root on a Mac with Metal. Tests decode a real rendered PNG and assert pixel colors for clipping, painter order, and rounded corners. They also exercise three leased buffers and synchronous snapshots. Core checks do not import the native-test root or load these frameworks.

The layout cache has at most 512 entries and a 4 MiB estimated-cost budget; 64 font slots are retained. Oversized lines are transient and may exceed that cache budget. The active glyph atlas is 4 MiB; older atlas generations may remain alive while the GPU references them. Instance capacity is bounded and reported separately. These are resource policies, not measurements of whole-process memory.

Current native limits include monochrome color-emoji coverage, runtime shader compilation, and a possible wait when recycling a busy GPU buffer. The native window/event loop and integration of layout/paint with the high-level `App.openWindow` API are not implemented yet. No Zed performance comparison is claimed.
