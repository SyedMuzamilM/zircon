# Framework implementation plan

The controlling specification is [framework-api-v0.1.md](specification/framework-api-v0.1.md), supplied by the user on 2026-11-05. It is preserved unchanged, including the original placeholder name and source formatting. Its SHA-256 is `211152c1d6558dcecf7ac0f2e41b4d64e8c3f1f35b40bff4708e065edd78f19a`.

The product name remains **Zircon UI**, imported as `zircon_ui`. The framework lives in `packages/zircon_ui` and follows the specification's subsystem structure inside that package. Zig 0.17.1 is the implementation target. Native adapters use direct Zig bindings to system APIs. No NanoUI or GPUI implementation is a dependency.

## Implementation order and acceptance

1. Entity runtime and headless harness. Typed generational handles, stable objects, application/entity ownership scopes, scoped read/update borrows, stale-handle rejection, safe destruction, notification coalescing, and allocation-failure tests. No GPU dependency.
2. Frame-local UI builder. Const view contract, epoch-checked elements, owned child lists and text, keyed identity, cleanup hooks, and committed/staging arenas. Inspect trees without a window; preserve the committed frame on failure.
3. Layout and native rendering. A documented flex subset, platform-neutral scene, direct Zig macOS bindings, Metal, and CoreText. Verify a standalone example before migrating the editor.
4. Interactive runtime. Dispatch through committed trees, capture/target/bubble, typed handlers, explicit invalidation, focus, and actions. Demonstrate counter/settings apps.
5. Editor capabilities. Native input and composition, selection, scrolling, virtualization, owned background messages, accessibility. Build the editor only on verified framework interfaces.
6. Optimization and more systems. Measure fixed workloads before claims. Add further adapters behind the existing seams; do not create fake Windows/Linux implementations.

Each implementation commit must state what works and pass the checks appropriate to that layer. Work for later stages may exist locally while being reconciled, but is not evidence that those stages are complete.

## Reconciliation with earlier work

The earlier immediate-frame design in `docs/design/` is historical and superseded by the user's specification. Its explicit-rectangle public interface is not the target. Independently written text shaping, GPU batching, and document algorithms may be retained behind the new interfaces when their ownership contracts fit. The former NanoUI dependency and Objective-C bridge are rejected.

Entity handles do not own state. Render methods receive `*const T`. UI elements and handlers belong to a frame; they cannot store raw render-state pointers. Committed frames remain alive throughout dispatch and failed staging builds. Notifications schedule work after borrows end. Platform APIs are direct bindings in Zig; Metal shaders remain Metal shader source.

## Honest status

Only the user-supplied document is a full API specification. This checklist is an implementation plan, not a declaration that all of that API exists. README and commit descriptions report the tested subset. Performance parity with Zed is not established.

## Verified progress

- `e2174d0`: unchanged specification and implementation plan preserved.
- `f935bed`: entity runtime, scope ownership, borrowing, coalesced notifications, and headless lifecycle tests.
- `64c971a`: immutable view contracts, frame-owned trees, typed handler adapters, committed/staging storage, and compiler-error contracts.
- The next tested unit adds deterministic flex layout with injected measurements. Native text and Metal remain isolated from core checks until their dedicated checks are wired.

The native window and event-propagation milestones are still ahead. The headless counter inspects a tree; it is not advertised as a finished native application.

The flex layout unit is committed as `993ed57`. Core validation now runs 36 behavior tests plus three expected compile failures. Direct Zig CoreText and Metal modules have a separate macOS test target with 12 tests, including rendered-pixel checks and asynchronous buffer reuse. The native implementation files follow the requested `text/`, `graphics/backends/`, and `platform/macos/` separation. The former `.h`/`.m` bridge is absent from the source tree.

The next verifiable unit is the native window and high-level frame pipeline. It must integrate the existing committed/staging trees and const-render entities, rather than reintroducing the superseded immediate-frame application interface. Capture/target/bubble dispatch, persistent focus, observer dependency tracking, worker tasks, and editor integration remain later work.
