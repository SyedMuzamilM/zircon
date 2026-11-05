# Zircon UI

A framework in Zig with explicit ownership. The verified first milestone is a headless entity runtime. It does not load a window system, text engine, or GPU.

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
