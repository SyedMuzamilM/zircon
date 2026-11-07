# Upstream follow-up: Zed and GPUI recommendations

This note checks the recommendations in [zed-gpui-vs-zircon-2026-11-07.md](zed-gpui-vs-zircon-2026-11-07.md) against the current Zed source. I queried `main` on 2026-11-07 and got commit `b5cd310b3b54dfc659fcc06453e6358843dfe216`, committed `2026-11-07T09:46:58Z`, as returned by the [GitHub commit API](https://api.github.com/repos/zed-industries/zed/commits/b5cd310b3b54dfc659fcc06453e6358843dfe216). Every upstream link below pins that SHA. Source evidence establishes mechanisms and contracts. It does not establish a frame-rate or CPU result.

## Findings

### 1. Keep incremental display and wrapping in the editor package

Zed's `DisplayMap` is a persistent pipeline of inlays, folds, tabs, wrapping, blocks, and highlights. Its `sync_through_wrap` consumes buffer edits through each layer and returns a new snapshot plus transformed edits. The [DisplayMap fields](https://github.com/zed-industries/zed/blob/b5cd310b3b54dfc659fcc06453e6358843dfe216/crates/editor/src/display_map.rs#L212-L245) and [sync pipeline](https://github.com/zed-industries/zed/blob/b5cd310b3b54dfc659fcc06453e6358843dfe216/crates/editor/src/display_map.rs#L561-L571) are direct evidence.

`WrapMap` retains a snapshot, queued edits, a transform tree, and an optional background task. Small changes update synchronously. Larger changes get a short foreground budget, then continue in the background, while interpolation keeps the display usable. See [state and sync](https://github.com/zed-industries/zed/blob/b5cd310b3b54dfc659fcc06453e6358843dfe216/crates/editor/src/display_map/wrap_map.rs#L42-L61), [edit sync](https://github.com/zed-industries/zed/blob/b5cd310b3b54dfc659fcc06453e6358843dfe216/crates/editor/src/display_map/wrap_map.rs#L210-L238), and [background rewrap](https://github.com/zed-industries/zed/blob/b5cd310b3b54dfc659fcc06453e6358843dfe216/crates/editor/src/display_map/wrap_map.rs#L285-L357).

The local `packages/zircon_editor/src/wrap.zig:11-135` already has a useful revision-keyed row cache and copies unaffected rows around an edit. It still walks every source line and copies unaffected rows into replacement arrays; changed lines are shaped on the UI path. Width or font changes invalidate that reuse. The next concrete step is to preserve the existing row map while moving large changed ranges to a worker, with a revisioned result and interpolation policy. Do not move this into `zircon_ui`; it is editor display state.

### 2. Make parsing persistent, then make LSP synchronization incremental

Zed's syntax map interpolates edits between parses and reparses an existing Tree-sitter tree with `old_tree`, then uses `changed_ranges` to limit downstream invalidation. See [syntax interpolation](https://github.com/zed-industries/zed/blob/b5cd310b3b54dfc659fcc06453e6358843dfe216/crates/language/src/syntax_map.rs#L374-L392), [old-tree reuse and changed ranges](https://github.com/zed-industries/zed/blob/b5cd310b3b54dfc659fcc06453e6358843dfe216/crates/language/src/syntax_map.rs#L781-L860), and the [parse helper](https://github.com/zed-industries/zed/blob/b5cd310b3b54dfc659fcc06453e6358843dfe216/crates/language/src/syntax_map.rs#L1602-L1643).

Zed also chooses LSP `FULL` or `INCREMENTAL` synchronization from server capabilities. For incremental servers it converts retained buffer edits to UTF-16 ranges, and falls back to a full document when line endings changed. The [change builder](https://github.com/zed-industries/zed/blob/b5cd310b3b54dfc659fcc06453e6358843dfe216/crates/project/src/lsp_store.rs#L9685-L9753) and [versioned notification](https://github.com/zed-industries/zed/blob/b5cd310b3b54dfc659fcc06453e6358843dfe216/crates/project/src/lsp_store.rs#L9756-L9773) make the boundary explicit.

The local tree is already careful about stale results. `apps/zircon/src/services/language.zig:10-22` tracks document revisions and epochs, `:371-448` rejects stale highlight results, and `:214-226` sends full snapshots through `Client.didChange`. The process and parser are rebuilt per highlight request in `apps/zircon/src/services/extension_host.zig:75-80` and `tools/zed-extension-host/src/highlight.rs:22-38`. The high-value follow-up is a persistent Tree-sitter or grammar worker that accepts edit ranges, plus LSP `didChange` content changes derived from the retained rope. Keep full-snapshot fallback for servers and line-ending changes. The current 8 MiB caps and full byte copies are explicit policy, not proof of a Zed-sized performance gap.

### 3. Add context predicates and multi-stroke keymaps

GPUI's keymap is a small context language. `KeyContext` stores identifiers and key-value entries, and `KeyBindingContextPredicate` parses expressions over them. See [context representation](https://github.com/zed-industries/zed/blob/b5cd310b3b54dfc659fcc06453e6358843dfe216/crates/gpui/src/keymap/context.rs#L5-L10) and [predicate parsing and depth matching](https://github.com/zed-industries/zed/blob/b5cd310b3b54dfc659fcc06453e6358843dfe216/crates/gpui/src/keymap/context.rs#L166-L265). `Keymap::bindings_for_input` resolves the deepest matching context, later bindings win at equal depth, and the resolver reports pending prefixes. The [precedence contract](https://github.com/zed-industries/zed/blob/b5cd310b3b54dfc659fcc06453e6358843dfe216/crates/gpui/src/keymap.rs#L150-L180) and [pending multi-stroke resolution](https://github.com/zed-industries/zed/blob/b5cd310b3b54dfc659fcc06453e6358843dfe216/crates/gpui/src/keymap.rs#L192-L270) support the recommendation directly.

Zircon's `packages/zircon_ui/src/event/actions.zig:5-25` is a typed single-chord linear scan. `apps/zircon/src/key_bindings.zig:63-68` validates duplicates, but has no prefix state or context predicate. The useful design is a trie or equivalent pending-prefix table over a widened `Key` enum, with a context stack supplied by the shell and editor mode. Keep action identity typed. Defer JSON compatibility details until the resolver and precedence rules have tests.

### 4. Build an accessibility tree at the element boundary

GPUI documents AccessKit integration and requires stable IDs plus a role before reporting a node. Its guide explains that IDs identify the same node across frames and that nodes without a role are omitted from the accessibility tree. See [AccessKit and node identity](https://github.com/zed-industries/zed/blob/b5cd310b3b54dfc659fcc06453e6358843dfe216/crates/gpui/src/_accessibility.rs#L10-L18) and [roles and stable IDs](https://github.com/zed-industries/zed/blob/b5cd310b3b54dfc659fcc06453e6358843dfe216/crates/gpui/src/_accessibility.rs#L55-L103). The `Element` trait exposes `a11y_role`, `write_a11y_info`, and synthetic children as separate hooks. See [Element accessibility methods](https://github.com/zed-industries/zed/blob/b5cd310b3b54dfc659fcc06453e6358843dfe216/crates/gpui/src/element.rs#L107-L137).

The original note correctly distinguishes GPUI support from Zed product readiness. Zed's [`build_application`](https://github.com/zed-industries/zed/blob/b5cd310b3b54dfc659fcc06453e6358843dfe216/crates/zed/src/main.rs#L87-L94) enables accessibility only when `ZED_EXPERIMENTAL_A11Y=1`; otherwise it calls `Application::new_inaccessible`. This verifies the opt-in claim, but does not measure screen-reader coverage.

The local tree has useful labels, focus, and keyboard handling. `packages/zircon_ui/src/ui/tree.zig:8-22` stores labels and focusability, but there is no role, stable accessibility ID, or platform accessibility adapter. Start with buttons, text fields, project rows, and the editor surface. Put the role and name on `Node`, keep IDs stable across frames, and emit a platform-neutral snapshot before choosing an AX or AccessKit bridge. Defer broad coverage and custom editor synthetic children until those four primitives work.

### 5. Turn existing visible-row math into a reusable list element

GPUI's `UniformList` computes the visible index range from scroll offset and item height, lays out and prepaints only those items, and paints the retained item elements. See [request layout and prepaint state](https://github.com/zed-industries/zed/blob/b5cd310b3b54dfc659fcc06453e6358843dfe216/crates/gpui/src/elements/uniform_list.rs#L263-L340), [visible-range construction](https://github.com/zed-industries/zed/blob/b5cd310b3b54dfc659fcc06453e6358843dfe216/crates/gpui/src/elements/uniform_list.rs#L473-L534), and [painting visible items](https://github.com/zed-industries/zed/blob/b5cd310b3b54dfc659fcc06453e6358843dfe216/crates/gpui/src/elements/uniform_list.rs#L544-L568). This bounds generated row elements to the visible range, plus measurement work. Arbitrarily expensive row callbacks can still exceed a frame budget. It does not prove 120 FPS.

Zircon already has the right raw pieces. `packages/zircon_ui/src/controls/scroll.zig:20-33` returns an overscanned visible range, and project, Git, agent, extension, and search views use variants of it. The code is currently duplicated at the view layer. A reusable list should own row count, row height, overscan, scroll offset, clipping, hit mapping, and child generation. A composed helper can reuse the current builders now. A GPUI-style custom list that creates children after learning its final bounds would need child layout and prepaint hooks. The gap is shared list behavior, not the absence of virtualization.

## Claim audit from the original note

### "Prepaint is folded into paint"

This is accurate if it means the local custom adapter invokes both phases from its paint callback. `packages/zircon_ui/src/ui/custom.zig:34-59` stores layout state, constructs `PrepaintCx`, calls `prepaint`, and immediately calls `paint`. The framework has a named prepaint method, so the sentence should not imply that the phase is missing. The real difference from GPUI is traversal scope: GPUI's `Element` trait has distinct `request_layout`, `prepaint`, and `paint` phases, with prepaint state passed into paint. See [GPUI's phase contract](https://github.com/zed-industries/zed/blob/b5cd310b3b54dfc659fcc06453e6358843dfe216/crates/gpui/src/element.rs#L48-L105). Zircon's custom elements cannot contribute child elements to the frame tree. That limits custom containers, but does not block composed lists or popovers, which already exist. Add child layout support when final-bounds-dependent child generation needs it; a separate prepaint traversal alone will not supply that capability.

### "GPUI has the same default full rebuild, full layout, and full paint"

The source supports the rebuild part. GPUI's element docs say the element tree and callbacks are dropped before the next frame and rebuilt from the root. See [GPUI element lifecycle](https://github.com/zed-industries/zed/blob/b5cd310b3b54dfc659fcc06453e6358843dfe216/crates/gpui/src/element.rs#L8-L18). The stronger performance wording needs care. GPUI's scene can replay a range from a previous scene through [`Scene::replay`](https://github.com/zed-industries/zed/blob/b5cd310b3b54dfc659fcc06453e6358843dfe216/crates/gpui/src/scene.rs#L141-L149), and `UniformList` bounds work to visible rows. Therefore "full paint" is a reasonable default pipeline description, not a universal cost claim for every frame.

### Performance numbers and causal language

The local 1 MiB wrapped p95 comes from the original note's repository baseline, which I did not rerun. It supports investigating wrap work. A timing table alone cannot isolate wrap-map rebuilding, Git scheduling, or full LSP synchronization as the cause; those need profiling or controlled comparisons. Upstream source confirms that Zed uses background wrapping, edit interpolation, incremental syntax parsing, and capability-aware LSP changes. It does not show that those mechanisms exist specifically to avoid this repository's 13 ms result, nor that they produce a particular frame rate.

The cited social post claiming GPUI Fast reduced CPU use from `40%-70%` to `10%-25%` at 120 FPS is not a Zed or GPUI source file, and no benchmark harness or raw data is part of this review. Treat it as an unverified anecdote, or remove it from the evidence section. The same applies to claims that `UniformList` is why a project panel stays at 120 Hz. Keep the recommendation, drop the causal performance claim until a reproducible benchmark compares the same workload and build.

## What to implement and what to defer

Implement the editor-owned incremental wrap and parse loop first. Preserve the local revision and epoch checks, then add incremental LSP changes with full-sync fallback. Next add a context-aware multi-stroke resolver and a reusable uniform-row list. Add stable element IDs, roles, and a small accessibility snapshot before committing to a platform bridge.

Defer subtree caching, broad layout features, and cross-platform accessibility adapters until those paths have measurements and a real screen that needs them. The pinned sources justify the shape of these changes. They do not justify a claim that Zircon is faster than Zed.

## Local source references

- [wrap cache](../../packages/zircon_editor/src/wrap.zig)
- [syntax cache](../../packages/zircon_editor/src/syntax.zig)
- [language lifecycle](../../apps/zircon/src/services/language.zig)
- [single-chord keymap](../../packages/zircon_ui/src/event/actions.zig)
- [custom element adapter](../../packages/zircon_ui/src/ui/custom.zig)
- [visible-row math](../../packages/zircon_ui/src/controls/scroll.zig)
