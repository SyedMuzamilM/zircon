# Window runtime design

The controlling specification is [framework-api-v0.1.md](../specification/framework-api-v0.1.md). The framework owns windows, frame transactions, event routing and animation. Native adapters own operating-system objects and rendering resources. Editor documents and commands belong to separate application packages.

## Ordinary use

Applications call `App.init`, `App.openWindow(View, options, initial_state)` and `App.run`. Native builds enable the package's `native` build option. Portable tests use an in-memory adapter behind the same window and event implementation. Neither caller manages GPU objects.

## Synthesis decision

Candidates A and B both passed the ownership and failure checks. Use A's stable window-owned frame transaction and lazy native creation, combined with B's private erased platform interface and dispatch-wide application transaction. Both candidates used the inherited model. No different-family judge was configured.

Each window owns two frame arenas. Each arena holds its tree, layout, scene and handlers. Build and validate the staging tree, arrange it, paint it, and finish fallible native encoding before committing through a nonfallible swap. A failed preparation preserves the previous committed frame. CPU storage retires only outside event dispatch. Metal maintains independent leases for in-flight resources. A later GPU failure cannot roll back an already submitted frame.

## Modules and contracts

- `app/window.zig` owns stable window records, root adapters, prepared output and routing.
- `platform/interface.zig` defines borrowed semantic input and private window operations. Native input bytes last through the synchronous callback only.
- `platform/macos/window.zig` implements `open(allocator, options, sink) !Surface`, `pump(timeout_seconds) !void`, and `now() f64`, using direct Zig AppKit bindings. `pump` dispatches native events; it does not render application views. All fallible work in `present` precedes command submission; false means deferred presentation.
- `animation/timeline.zig` owns keyed tracks with a deterministic seconds clock. The window samples it while building a frame and requests ticks only while tracks are active.
- `graphics/painter.zig` records ordered platform-neutral draw commands into a frame arena.

The first integrated input pass uses pointer targeting, bubbling, focus and keyboard/text dispatch. Dispatch pins the committed frame and wraps handlers in one outer application transaction. Persistent targets use full logical key paths rather than arena pointers or hashes alone. Custom elements paint through Painter and receive the same entity-bound event adapters as built-in nodes.

## Verification and remaining contracts

Verify actual native open, click, resize and close; failure retention; event ordering; focus after rebuild; animation interruption and idle scheduling; resource teardown with submitted work. Then use the same public interfaces for the editor.

IME composition requires revisioned owned text snapshots, UTF-16 range conversion and native candidate geometry. Initial plain text delivery does not satisfy that contract. Accessibility, advanced layout, task cancellation and presence/layout animation each require independent verification. Track incomplete capabilities in the status document rather than treating an exported type as a completed feature.
