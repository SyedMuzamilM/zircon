# Choosing where Zircon UI should compete with GPUI

Compared on 18 November 2026 at Zircon `41f24d6` and Zed/GPUI `bb5e6df`. The first workloads worth competing on are typing in a wrapped buffer, scrolling a large list, and updating one panel while the rest of the window stays still. Each is common in an editor, has a visible correctness condition, and exercises a different source of latency. Neither project has published a matched result for these revisions in the evidence reviewed here. [Zircon revision][z] · [Zed revision][u] · [Implementation roadmap](../zircon-ui-roadmap.md)

## Where the frameworks differ

| Area | Zircon UI today | GPUI at the reviewed revision | What this means for Zircon |
|---|---|---|---|
| View construction and invalidation | A dirty window builds its candidate tree. Explicitly keyed, eligible subtrees can reuse measurement, arrangement and recorded scene commands. | A definitely sized, explicitly cached view can skip view construction and reuse prepaint and paint ranges. GPUI tracks accessed entities for invalidation. | A one-row sidebar update is the clearest experiment. Count view constructions as well as layout and paint cache hits. [Zircon cache contract][cache] · [GPUI cached view][view] |
| State and failure handling | Typed generational entities belong to scopes. Frame-local allocations and a committed frame give failed rebuilds a rollback boundary. Compile-fail tests exercise borrowing and handler rules. | Strong and weak entities, subscriptions and typed contexts control access to persistent state across rendering and tasks. | Preserve Zircon’s ability to recover from failed frame construction. A cached visual that retains a stale hit target is a correctness failure even if its pixels match. [Zircon entity tests][tests] · [GPUI entities][entity] |
| Scene and decorations | Metal renders text, images, lines, gradients and shadows. One concrete consumer, the new diagnostic wave, emits approximately one rectangle per two logical pixels of underline. | The scene can represent a wavy underline directly. It also has paths and dedicated sprite primitives. | Introduce a decoration primitive if the dense-diagnostics profile attributes material CPU time to building those rectangles. A rectangle count alone does not give GPU draw calls. [Zircon wave][wave] · [GPUI scene][scene] |
| Layout and long lists | Flex layout, fixed-height virtualization and variable-height lists with caller-provided offset/index functions. Callers can supply an efficient index or an expensive one. | Taffy layout, uniform lists and stateful variable lists with item splicing, focusable rows and scroll-to-reveal. | Test mutations above the viewport and keyboard navigation as well as uninterrupted scrolling. A fast list that loses the selected row after insertion is a poor editor control. [Zircon lists][list] · [GPUI lists][ulist] |
| Text and input | CoreText shaping, caret metrics, a text-input snapshot for native editing, and context-aware key sequences. A reproduced defect dispatched the action for `x l` after `g l` when only `g f` and `x l` were bound. | Platform text systems, font features, wrapping and a keymap resolver matching accumulated strokes against bindings. | Key dispatch is a small, immediately testable fix. Shaping, selection, IME and grapheme movement each need their own acceptance cases. [Zircon resolver][keys] · [GPUI keymap][ukeys] · [GPUI text][text] |
| Accessibility and platforms | Native AppKit/CoreText/Metal plus a headless backend. The review found no equivalent committed OS accessibility tree. | AccessKit supplies roles, stable identities and assistive actions. Platform crates support desktop windows on macOS, Linux and Windows. | Start semantics on macOS alongside cache work. Reusing a subtree must preserve its accessibility identity and actions. A second desktop port also needs clipboard, text input and font services. [Zircon platforms][platform] · [GPUI accessibility][a11y] · [GPUI platforms][platforms] |
| Background work and developer tools | Owned jobs deliver results on the UI thread, cooperative cancellation, deterministic stepping, native journeys and allocation-failure tests. | Foreground/background executors, priorities, test dispatchers, visual test contexts, inspector and profiler. | Count UI-thread stalls and queue delays separately. Give component authors a way to see why a subtree rebuilt before asking them to adopt more caching APIs. [Zircon jobs][jobs] · [GPUI executor][exec] |

## Where editor architecture affects the result

**Typing with diagnostics.** Zircon copies diagnostic marks into editor views on generation or revision changes. Painting a visible segment scans its view’s marks. For V visible segments and D marks, those checks can grow as V × D. Zed keeps anchored diagnostics in an indexed tree. A document-owned range index and a framework underline primitive solve different costs. Measure them independently. [Zircon synchronization][sync] · [Zircon canvas][canvas] · [Zed diagnostic set][diag]

**Completion while typing.** The November 18 editor commit gives diagnostics and hover a shared visual treatment. Its completion fixture exposed a continuity gap. After suggestions appeared for `ans`, typing `w` cleared the list while the next request was pending. That path runs through editor edit handling. Accelerating layout cannot make a cleared list stay visible. Zed’s menu separately models selection, matching, resolution and documentation. [Zircon input path][edit] · [Zed completion menu][menu]

**Workspace breadth.** Zircon has local Git, a PTY, two editor pane groups, editable search excerpts and LSP actions including rename and formatting. Zed also delivers nested pane arrangements, remote work, debugging and collaboration. These product features belong in an editor plan. The framework roadmap uses real editor screens to expose toolkit costs and interaction defects. [Zircon editor][editor] · [Zed workspace][workspace] · [Zed documentation][docs]

## What the measurements establish

An archived Zircon run on macOS recorded **13.20 ms** for wrapped typing with a 1 MiB document in the core configuration and **10.82 ms** with services. Each value is the median of five per-process p95s, with 20 inputs per process. Timing ended at native frame submission. The archive predates the reviewed commits. It identifies a workload worth repeating, but cannot establish current latency, presentation time or a winner against GPUI. Zircon’s million-row smoke test likewise establishes that it can avoid painting the whole list, while the cost of a native, text-bearing list still needs measurement. [Archived editor data][baseline] · [Existing framework benchmark method][method]

The prior Linux run of the unmodified Zircon tip recorded 496 passed, 6 skipped and 12 crashed across the Zig tests. The crashes reached atomic persistence in recent projects/settings. Formatting and import-order checks also failed. The five focused checks for the newest editor changes passed. These are execution results for Zircon. The GPUI capabilities above were inspected in source. [Zircon change and tests][z]

[z]: https://github.com/SyedMuzamilM/zircon/commit/41f24d630e581cd771ff382dd5d6c169e1f6ae03
[u]: https://github.com/zed-industries/zed/commit/bb5e6dfd078f8e4d9ed63a7aac59a7de319bab8d
[cache]: https://github.com/SyedMuzamilM/zircon/blob/41f24d630e581cd771ff382dd5d6c169e1f6ae03/docs/progress/2026-11-15-subtree-cache.md
[tests]: https://github.com/SyedMuzamilM/zircon/tree/41f24d630e581cd771ff382dd5d6c169e1f6ae03/packages/zircon_ui/tests
[wave]: https://github.com/SyedMuzamilM/zircon/blob/41f24d630e581cd771ff382dd5d6c169e1f6ae03/packages/zircon_editor/src/element.zig
[list]: https://github.com/SyedMuzamilM/zircon/blob/41f24d630e581cd771ff382dd5d6c169e1f6ae03/packages/zircon_ui/src/controls/list.zig
[keys]: https://github.com/SyedMuzamilM/zircon/blob/41f24d630e581cd771ff382dd5d6c169e1f6ae03/packages/zircon_ui/src/event/actions.zig
[platform]: https://github.com/SyedMuzamilM/zircon/tree/41f24d630e581cd771ff382dd5d6c169e1f6ae03/packages/zircon_ui/src/platform
[jobs]: https://github.com/SyedMuzamilM/zircon/blob/41f24d630e581cd771ff382dd5d6c169e1f6ae03/packages/zircon_ui/src/app/owned_tasks.zig
[sync]: https://github.com/SyedMuzamilM/zircon/blob/41f24d630e581cd771ff382dd5d6c169e1f6ae03/apps/zircon/src/services/language.zig
[canvas]: https://github.com/SyedMuzamilM/zircon/blob/41f24d630e581cd771ff382dd5d6c169e1f6ae03/packages/zircon_editor/src/canvas.zig
[edit]: https://github.com/SyedMuzamilM/zircon/blob/41f24d630e581cd771ff382dd5d6c169e1f6ae03/apps/zircon/src/actions.zig
[editor]: https://github.com/SyedMuzamilM/zircon/blob/41f24d630e581cd771ff382dd5d6c169e1f6ae03/README.md
[baseline]: https://github.com/SyedMuzamilM/zircon/blob/41f24d630e581cd771ff382dd5d6c169e1f6ae03/docs/benchmarks/editor-2026-11-07-lifecycle-current-git/README.md
[method]: https://github.com/SyedMuzamilM/zircon/blob/41f24d630e581cd771ff382dd5d6c169e1f6ae03/docs/benchmarks/framework-method.md
[view]: https://github.com/zed-industries/zed/blob/bb5e6dfd078f8e4d9ed63a7aac59a7de319bab8d/crates/gpui/src/view.rs
[entity]: https://github.com/zed-industries/zed/blob/bb5e6dfd078f8e4d9ed63a7aac59a7de319bab8d/crates/gpui/src/app/entity_map.rs
[scene]: https://github.com/zed-industries/zed/blob/bb5e6dfd078f8e4d9ed63a7aac59a7de319bab8d/crates/gpui/src/scene.rs
[ulist]: https://github.com/zed-industries/zed/blob/bb5e6dfd078f8e4d9ed63a7aac59a7de319bab8d/crates/gpui/src/elements/list.rs
[ukeys]: https://github.com/zed-industries/zed/blob/bb5e6dfd078f8e4d9ed63a7aac59a7de319bab8d/crates/gpui/src/keymap.rs
[text]: https://github.com/zed-industries/zed/tree/bb5e6dfd078f8e4d9ed63a7aac59a7de319bab8d/crates/gpui/src/text_system
[a11y]: https://github.com/zed-industries/zed/blob/bb5e6dfd078f8e4d9ed63a7aac59a7de319bab8d/crates/gpui/src/_accessibility.rs
[platforms]: https://github.com/zed-industries/zed/blob/bb5e6dfd078f8e4d9ed63a7aac59a7de319bab8d/crates/gpui/README.md
[exec]: https://github.com/zed-industries/zed/blob/bb5e6dfd078f8e4d9ed63a7aac59a7de319bab8d/crates/gpui/src/executor.rs
[diag]: https://github.com/zed-industries/zed/blob/bb5e6dfd078f8e4d9ed63a7aac59a7de319bab8d/crates/language/src/diagnostic_set.rs
[menu]: https://github.com/zed-industries/zed/blob/bb5e6dfd078f8e4d9ed63a7aac59a7de319bab8d/crates/editor/src/code_context_menus.rs
[workspace]: https://github.com/zed-industries/zed/tree/bb5e6dfd078f8e4d9ed63a7aac59a7de319bab8d/crates/workspace/src
[docs]: https://github.com/zed-industries/zed/tree/bb5e6dfd078f8e4d9ed63a7aac59a7de319bab8d/docs/src
