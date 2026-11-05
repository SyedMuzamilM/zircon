# Framework implementation status

Status audited on 2026-11-05 against the [supplied specification](specification/framework-api-v0.1.md) and the current source and tests.

The entity runtime and frame-tree foundations work. Layout, CoreText shaping, and offscreen Metal rendering work as separate subsystems. The framework cannot yet run a desktop application through its public API: `App.openWindow`, `App.run`, the native window loop, and the integrated render/input pipeline do not exist.

## Milestone coverage

| Specification milestone | Current state | What works | What remains |
| --- | --- | --- | --- |
| 1. Entity runtime and headless harness | Foundation implemented | Typed generational handles, stable state allocations, application/entity/explicit-scope ownership, read/update borrows, destruction, notifications, lifecycle tests | Automatic window-scope integration comes with windows; observations/subscriptions are not implemented |
| 2. Frame-local UI builder | Foundation implemented | Const render contracts, indexed element trees, copied strings/children, logical keys, typed click adapters, cleanup hooks, committed/staging storage | Custom elements and their layout/prepaint/paint adapters, `Ui.view`, and `Ui.watch` |
| 3. Layout, rendering, native window | Partly implemented | Flex subset, injected measurements, CoreText shaping/caret metrics, glyph atlas, offscreen Metal quads/text, clipping, PNG snapshots, GPU buffer leases | Native windows/surfaces and high-level connection of trees, layout, text, paint, and presentation |
| 4. Interactive application runtime | Not implemented | Direct invocation of a typed entity-handler adapter is tested; frame lifetime guards exist | Hit testing, capture/target/bubble dispatch, focus, keyboard/actions/menus, dependency tracking, event-loop scheduling, a native counter/settings app |
| 5. Editor-grade capabilities | Not implemented | Text metrics and UTF-8/UTF-16 conversion are reusable foundations | Native text input/IME, editable controls, selections, undo, scrolling, virtualization, owned worker tasks, accessibility, editor |
| 6. Optimization and other platforms | Not implemented | Cache limits, GPU timings and resource counters exist | Repeatable application benchmarks, startup/memory measurements, scene caching, Windows/Linux native adapters, measured Zed comparison |

The first two milestone foundations are in place, and the third is partial. These milestones have different sizes; this count is not a percentage of the full implementation effort.

## Available API and limits

`App` currently supports initialization/destruction, typed entity creation/read/update, explicit ownership scopes, destruction, versions, and coalesced invalidation requests. It does not open windows or run a native event loop. `Context(T)` supports notification, scoped access, child creation, and deferred destruction. Observer/event subscription and worker-task APIs are absent.

`Ui` builds `div`, `row`, `column`, `text`, `textFmt`, and `button` nodes and assigns keys. `onClick` creates a typed adapter that resolves its owner entity when explicitly invoked. A button node is not yet an OS-interactive control. Typed event payloads do not provide propagation controls until an actual dispatcher exists.

Tree construction uses committed/staging arenas. Failed staging tree construction preserves the committed tree. Layout calculation and GPU submission are still separate operations, so a complete window frame is not yet one integrated transaction.

Layout supports rows/columns, padding, positive margins, gaps, grow/shrink with min/max limits, alignment, and typed dimensions. It does not implement wrapping, grid, or baseline alignment. Headless tests inject fixed metrics; the native CoreText measurer has not been connected to the high-level pipeline.

Native text/graphics are currently reached through a private test module, separately from the portable package API. They use direct Zig system bindings and a Metal shader. There is no C/Objective-C implementation source or NanoUI/GPUI dependency. The shaping cache is bounded by estimated cost; that is not a process-memory cap. Color emoji render as monochrome coverage. Shaders compile at renderer creation, and recycling a busy GPU buffer can wait.

## Verification

Run from the repository root with Zig 0.17.1:

```sh
./tools/zig build check
./tools/zig build test-native
./tools/zig build test-build -Dtarget=aarch64-linux-gnu
./tools/zig build counter
```

- Core: 36 test-runner cases plus three expected compiler-error contracts.
- Native: 12 test-runner cases on macOS with Metal, including decoded PNG pixel checks and buffer reuse.
- Linux: the headless tests compile for `aarch64-linux-gnu`; this is not a Linux native UI implementation or a Linux runtime test.
- Counter: constructs and inspects a headless tree. It opens no window.

Test-runner totals include each test suite's import aggregation case. The counts establish behavior coverage for the implemented pieces, not completion of the specification.

## Cleanup in this revision

Removed ignored `App.init` I/O/renderer options, event propagation controls without a dispatcher, unused scene text-input metadata, an unread entity change flag, unused native bindings/imports, and a geometry helper with no callers. Updated current call sites and docs. Kept functional public utilities and the native backend used by the rendering tests.

Deleted the ignored rejected-editor/framework source archive, old dependency copy, stale output binaries, and the downloaded compiler archive. The installed Zig compiler, active build cache, original specification, research, and historical design notes remain.

## Next deliverable

A native window driven by the existing const-render entities and committed/staging trees, with measured text layout and Metal presentation. Event dispatch and focus follow through the committed tree. The editor starts after that framework path is verified.
