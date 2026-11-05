# Zircon UI

A framework in Zig with explicit ownership. The verified foundations are a headless entity runtime and declarative frame builder. It does not load a window system, text engine, or GPU.

```zig
const ui = @import("zircon_ui");
var app = try ui.App.init(.{ .allocator = allocator, .renderer = .headless });
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

A view implements `pub fn render(self: *const Self, ui: *zircon_ui.Ui) !zircon_ui.Element`. `Ui.column`, `row`, `div`, `text`, `textFmt`, and `button` build indexed trees. Strings and child slices are copied into the staging arena. `ui.onClick(Self.method)` records the owner handle and a generated typed adapter, never a pointer to the render stack.

`testing.Harness.render(entity)` performs a borrowed const render and commits only after successful tree validation. A failed render discards staging storage and preserves the committed tree and its handlers. Element epochs reject foreign or retired handles; keys compare by type and value inside their containing keyed scope. No layout or native drawing is implied by constructing a tree.

Frames invoke registered cleanup hooks in reverse registration order before resetting their arena. Registering a hook transfers cleanup responsibility only on success. Dispatch pins the committed tree; replacing it during active dispatch returns `DispatchActive`.

The root `check` target includes compile-failure fixtures for mutable render methods, invalid click-handler signatures, and borrowed access results. The headless counter example builds and inspects the same tree that a later native window will lay out and paint.
