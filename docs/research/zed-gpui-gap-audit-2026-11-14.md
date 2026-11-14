# Zircon versus current GPUI: capability and performance audit

Audited 2026-11-14 against Zircon commit `ab6aca696880a58c210e4927a7d4ef134fa7fb94` and the current Zed `main` tip `0cfc4a483dfab6ca171df0ceedaaa2a9f7954d0e`. The upstream commit only changes the `async-task` dependency, but the checkout is the complete current `crates/gpui` source and examples, including SVG animation, scene replay, lists, paths, image caching, accessibility, platform services and tests.

Evidence checked:

- Upstream GPUI source: [`crates/gpui`](https://github.com/zed-industries/zed/tree/0cfc4a483dfab6ca171df0ceedaaa2a9f7954d0e/crates/gpui)
- Upstream GPUI README and public surface: [`gpui.rs`](https://github.com/zed-industries/zed/blob/0cfc4a483dfab6ca171df0ceedaaa2a9f7954d0e/crates/gpui/src/gpui.rs), [`Cargo.toml`](https://github.com/zed-industries/zed/blob/0cfc4a483dfab6ca171df0ceedaaa2a9f7954d0e/crates/gpui/Cargo.toml)
- Specific upstream mechanisms: [`svg.rs`](https://github.com/zed-industries/zed/blob/0cfc4a483dfab6ca171df0ceedaaa2a9f7954d0e/crates/gpui/src/elements/svg.rs), [`animation.rs`](https://github.com/zed-industries/zed/blob/0cfc4a483dfab6ca171df0ceedaaa2a9f7954d0e/crates/gpui/src/elements/animation.rs), [`scene.rs`](https://github.com/zed-industries/zed/blob/0cfc4a483dfab6ca171df0ceedaaa2a9f7954d0e/crates/gpui/src/scene.rs), [`list.rs`](https://github.com/zed-industries/zed/blob/0cfc4a483dfab6ca171df0ceedaaa2a9f7954d0e/crates/gpui/src/elements/list.rs), [`uniform_list.rs`](https://github.com/zed-industries/zed/blob/0cfc4a483dfab6ca171df0ceedaaa2a9f7954d0e/crates/gpui/src/elements/uniform_list.rs), and [`view.rs`](https://github.com/zed-industries/zed/blob/0cfc4a483dfab6ca171df0ceedaaa2a9f7954d0e/crates/gpui/src/view.rs)
- Zircon UI source: [`packages/zircon_ui`](../../packages/zircon_ui), [`docs/zircon-ui.md`](../zircon-ui.md), [`docs/status.md`](../status.md)
- Existing performance evidence: [`current lifecycle baseline`](../benchmarks/editor-2026-11-07-lifecycle-current-git/README.md)

Implementation follow-up: the current worktree now includes the first macOS/headless slice from this audit—fixed and variable virtual lists, AppKit SVG rasterization, transformed scene images, compositor-only image animation, explicit keyed scene-range replay, gradients, layered shadows, and context-aware sequence keymaps. See the [implementation progress note](../progress/2026-11-14-framework-slice.md). The remaining gaps in this document still describe work not yet implemented, especially dirty-subtree layout, accessibility, advanced layout, vector path tessellation, and editor-side incremental services.

## The answer in one paragraph

Zircon already has a sound small UI core: typed entities and scopes, transactional frame rollback, three-phase custom elements, CoreText shaping, Metal quads/text/images, input capture and bubbling, focus/modal routing, reduced-motion animation, owned jobs and deterministic headless tests. It is not yet feature-complete GPUI. The largest missing capability is a retained/incremental rendering path: Zircon rebuilds the dirty tree, layout and scene, while current GPUI can cache a view subtree and replay its scene range. The largest missing product capability is the reusable virtualized list. SVG is absent as a runtime feature: generated icon paths are not an SVG parser, and Zircon has no SVG path rasterization, external/data loading, transforms or scene-level SVG animation.

Do not attempt to beat GPUI by copying all of GPUI first. Make the hot path cheaper, then add the features that depend on it. A smaller retained renderer with incremental layout, incremental text display maps and virtualized lists has a credible path to outperform GPUI on editor workloads. No speed ranking is established yet; the current benchmark is Zircon-only.

## Framework capability matrix

Status: **present** means a usable implementation exists in Zircon; **partial** means a narrower implementation exists; **missing** means no framework-level implementation was found in the current tree.

| Capability | Current GPUI main | Zircon now | Gap and priority |
|---|---|---|---|
| Entity/state | Generational `Entity`, weak handles, typed app contexts, globals, release observers | Typed generational entities, explicit scopes, scoped borrows, observations/events, deferred destruction | Keep Zircon ownership model. Add weak/erased handles only when a consumer needs them. **P2** |
| Frame invalidation | Per-view invalidation and cached view subtrees; scene ranges can be replayed | Dependency versions and two-frame commit/rollback; every dirty window rebuilds tree/layout/paint | Add retained subtree records and scene replay. This is the main performance gap. **P0** |
| Layout | Taffy flex, grid, wrapping, block/float layout, absolute/relative positioning and richer sizing | Row/column/stack flex, padding/margin/gap, grow/shrink, min/max, align, clipping and scrolling | Add dirty-subtree layout first; then wrap and grid; baseline and positioning after real consumers. **P1** |
| Lists | Variable-height `list`, uniform-height `uniform_list`, measurement/reveal/follow-tail/scroll handles | `Scroll` and `visibleRows` math; consumers implement their own rendering | Build a reusable virtual list with fixed and variable row modes. **P0** |
| Scene primitives | Quads, rounded borders, shadows, underlines, monochrome/subpixel/polychrome sprites, surfaces, paths and batch iteration | Rectangles, text, images, round-capped lines, clip rectangles | Add path/gradient/shadow primitives behind a stable scene IR; do not grow painter calls without batching. **P1** |
| SVG | `svg()` accepts file paths, external assets and raw bytes; `resvg/usvg` parses/rasterizes; transforms and timed transformations are built in | No runtime SVG parser or painter primitive; generated icon geometry in `controls/icon_paths.zig` | Implement SVG asset parsing/cache/rasterization, then transforms and retained animation. **P1** |
| SVG animation | Timed scale/translation/rotation/alpha transformation can move an already-painted sprite; reduced motion is honored; animation can cap FPS | Scalar/color/rect/presence timeline; animation changes targets and requests frames; no scene-level transform | Add `Scene.Sprite`/`Scene.Path` transform handles and compositor-only animation. Fix animation-key namespace collisions before extending it. **P1** |
| Images/assets | `Asset`/`AssetSource`, async image loading, image cache providers, multi-frame images and frame delays | Immutable RGBA image, native ImageIO decode of first frame, bounded texture cache | Add async decode, reusable asset identity/cache and animated frames. **P2** |
| Text | Font fallback, font features, grapheme segmentation, wrapped line layouts, truncation, rich runs, underline/strike styles and color glyph paths | CoreText shaping and caret/index conversion, text cache, UTF-8 validation, code-point movement | Add shared grapheme boundaries, rich runs/decorations, bidi policy and color glyph atlas. **P1** |
| Input events | Mouse/key/touch/pressure/pinch/back gesture, drag/drop, hover/tooltip, capture/bubble and action dispatch | Pointer/key/text input, capture/bubble, focus, pointer capture, modal routing and drag-region | Add physical key identity/context routing first; then touch/gesture/file-drop/tooltip APIs. **P1/P2** |
| Commands/keymap | Typed actions, registered schemas, multi-stroke sequences, key contexts and precedence predicates | Typed single-chord bindings; limited key enum; no context or pending sequence | Widen key identity, add context stack and pending sequence state. **P1** |
| Animation model | Element animation chains, springs, easing, synced loops and max-FPS scheduling | Keyed scalar channels, tweens/springs, color/rect/presence, reduced-motion | Keep the simpler typed API; add max-FPS and compositor-only tracks. **P2** |
| Accessibility | AccessKit tree, roles, names, values, actions, synthetic custom-editor nodes | No OS accessibility tree | Add semantic metadata to committed frame and a macOS AX adapter. **P0 for product readiness** |
| Native windows | macOS, Windows, Linux/X11/Wayland, iOS/web paths in the upstream ecosystem; menus, prompts, notifications, clipboard, screen capture, popups and layer shell | macOS AppKit window/input/clipboard/ImageIO/Metal plus portable headless adapter | Finish native menus/dialog API, then SDL3/shared backend and non-macOS execution. **P1/P2** |
| Async/runtime | Foreground/background futures, timers, priorities, scoped tasks and test-controlled clocks | Thread-per-job owned queue, cooperative cancellation and external inbox wake | Add a foreground executor/timer abstraction without changing the safe job ownership contract. **P2** |
| Testing/profiling | Test/visual contexts, screenshots, inspector, profiler, randomized element trees and renderer benches | Headless deterministic `App.step`, native journeys, compile-fail ownership tests and snapshots | Add frame counters, allocation counters, scene batch counters and an inspector before tuning. **P1** |

### SVG specifically

Current GPUI's SVG implementation is four separate capabilities that Zircon should model separately:

1. **Source:** file path, external asset path, or raw bytes.
2. **Rasterization:** parse once, rasterize at the needed scale and cache by source/scale/color.
3. **Scene primitive:** retain the rasterized sprite/path and clip it like any other primitive.
4. **Motion:** apply scale, translation, rotation and alpha in the scene at present time without rebuilding the view.

The first Zircon slice should be a safe `graphics.SvgAsset` backed by an SVG parser/rasterizer and a retained texture identity. Do not parse SVG during `paint`. The second slice should add `SvgTransform` to the scene and an animation ID whose updates touch instance data only. A large animated icon must not trigger layout, text shaping or tree construction.

The existing generated icons remain useful: they are deterministic and fast for built-in controls. They should be a fast path beside, rather than a substitute for, runtime SVG support.

## Editor/product gaps versus Zed

The UI framework gaps above are independent of editor product parity. Current Zircon application code is ahead of a toy editor, but these Zed-level capabilities remain materially incomplete:

| Product area | Zircon current state | Missing or partial behavior |
|---|---|---|
| Panes/workspace | Two pane groups, tab dragging, four-edge splits and child settings window | Arbitrary nested pane tree, richer docks and full workspace persistence |
| Text model | Persistent UTF-8 rope, snapshots, grouped undo, multi-cursor and cached soft wrap | Grapheme-aware movement, bidi, encodings/BOM, background incremental display map and parser tree reuse |
| File/workspace | Safe save/conflict fingerprints, recovery store and project tree | External watcher/reload/rename/delete/new-folder flows and full recovery acceptance in all paths |
| Search | Project search over saved/unsaved buffers, source edits, selection and grouped undo | Project regex, live query refresh, multibuffer virtualization and cross-source IME |
| Language services | Diagnostics, completion and additional edits through stdio servers | Hover, definition, references, rename, formatting, code actions, semantic tokens and snippets |
| Syntax | WASM grammar integration and seven token categories | Retained incremental Tree-sitter trees, injections and semantic-token fidelity |
| Git | Status, file staging, commit/history, blame, stash, push/pull, inline hunk display and cross-file selection | Hunk staging, conflict-resolution editor, graph/worktrees, file watching and destructive restore/discard UI |
| Terminal | Native PTY tabs, docking, paste/Ctrl-C and bounded scrollback | Full ANSI/VT protocol, Unicode/grapheme/IME behavior, task integration and lifecycle coverage |
| Extensions | Catalog, themes/icons/grammars and WASM language-server hooks | Snippets, DAP/debug adapters, MCP/agent contributions, broader API compatibility and capability negotiation |
| Agents/debugging | Codex/ACP transport pieces exist; agent UI is temporarily unavailable | Full agent panel/worktrees/edit prediction, debugger/DAP and collaboration/remote development |
| Settings/commands | Child settings window and persisted appearance/editor preferences | Keybinding editor, context-sensitive multi-stroke commands, menus and broad settings catalog |
| Platform/accessibility | macOS native plus portable compile/headless | Linux/Windows native adapters, native menus/dialogs, AX tree and screen-reader journeys |

These rows should not be implemented in a single parity rewrite. Each needs a vertical consumer journey and a measured budget.

## Performance: how to make Zircon faster than GPUI

The current evidence gives a starting point, not a claim. In the controlled 1 MiB lifecycle baseline, wrapped typing reached **13.20 ms p95** core and **10.82 ms p95** with services; the test ends at native frame submission and excludes GPU completion and scanout. The same run recorded 20 wrap-map rebuilds, document-wide folding scans, repeated Git status/history commands and full-document LSP serialization. A 13.20 ms CPU path misses an 8.33 ms 120 Hz budget before compositor work is counted.

Use this order:

### P0: establish a fair benchmark and remove the editor cliffs

Create one benchmark driver that renders equivalent scenes in Zircon and GPUI:

- 10k-row uniform list and 10k-row variable list, with scroll and selection.
- 1 MiB wrapped editor, middle insert, delete, undo and resize.
- 5k text labels with font fallback and cache warm/cold runs.
- 1k SVG icons with 60 FPS transform animation.
- Image gallery with decoded-cache hits/misses and multi-frame image playback.
- Idle window, hover-only update and compositor-only animation.

Record p50/p95/p99 CPU frame time, input-to-submit, GPU submission, allocations/bytes, scene primitive count, layout nodes visited, text bytes shaped, cache hit rate and process RSS. Run release builds on the same machine, at 60 and 120 Hz, with cold and warm caches. A GPUI number is only comparable when the feature set, event count and timing boundary match.

### P0: retained frame and damage tracking

Preserve Zircon's two-frame rollback contract, but add stable node IDs and per-node records:

- Reuse layout/bounds when constraints and style inputs are unchanged.
- Reuse prepaint handlers and accessibility nodes for unchanged subtrees.
- Store scene ranges per subtree and replay them into the next scene.
- Track dirty causes (`content`, `layout`, `paint`, `input`, `asset`) instead of one boolean.
- Add a compositor-only path for transforms/opacity and caret blink.

The target is that a cursor blink, hover, scroll offset or SVG transform does not rebuild the whole editor tree.

### P1: incremental layout and display maps

Replace whole-frame `flex.calculate` for stable subtrees with dirty-subtree recomputation. For the editor, retain a row index and update only the changed logical line plus the affected wrap neighborhood. Move folding scans and expensive shaping to background jobs with revisioned results. Keep a fresh full-map implementation as the correctness oracle.

### P1: virtualized lists and image/SVG caches

Implement `ListState`/`UniformListState` equivalents with measured heights, overscan, reveal/scroll handles, follow-tail and selection/focus persistence. Add async image/SVG decode and cache entries keyed by source identity, scale and theme color. Upload textures once and reference stable GPU IDs in scene commands.

### P1: scene and GPU throughput

Change the current per-item scene into a structure-of-arrays or tightly packed instance stream. Sort/batch by primitive/material/texture where painter order permits. Use persistent mapped buffers or a ring buffer for frame instances, and never synchronously upload the same image on every draw. Add path tessellation and shadows as separate batched passes. Instrument the Metal path before changing shader design.

### P2: scheduling and service isolation

Add a single foreground executor with timers and priorities, keep background jobs revisioned and cancellable, and make Git/LSP/grammar work incremental. Typing must not launch repository status/history work or serialize a full document when a server accepts incremental edits. Use bounded queues and drop obsolete work before it reaches the UI thread.

## Recommended implementation sequence

1. Add the benchmark schema and counters; capture a Zircon-only baseline and a GPUI baseline with identical scenarios.
2. Fix animation channel identity collisions and add frame/scene/node counters.
3. Ship retained subtree scene replay for one real workspace panel and compositor-only opacity/transform animation.
4. Ship uniform and variable virtual lists; migrate project tree, search, Git rows and extension catalog.
5. Make editor wrapping/folding and language synchronization incremental.
6. Add runtime SVG assets, cached rasterization and scene transforms/animation.
7. Add accessibility semantics, native menus/dialogs and broader keyboard contexts.
8. Add grid/wrap/baseline and non-macOS native adapters only when a supported consumer justifies them.

The first four steps are the path to being faster. SVG, grid and platform breadth are important library features, but implementing them before retained/incremental work will make a larger library that still misses the frame budget.
