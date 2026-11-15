# Subtree layout reuse and scene-cache ownership

The November 15 follow-up completes arrangement reuse for explicitly cached subtrees, including the project sidebar rows. Tree construction continues each frame. Eligible unchanged branches skip layout computation and replay their drawing commands; dirty branches recompute through the flex engine.

The final review found problems in the first cache implementation. Replayed text borrowed persistent cache storage, which replacement or eviction could free before a committed frame retired. Layout reuse could also skip initialization of a custom element's frame-local phase state. Scene hashes omitted descendant geometry and child hover state, and hashes of raw structs included padding and inactive union bytes.

The fixes give each frame its own replayed text, copy cache entries before replacement, and clean partial copies on allocation failure. Cache keys include the logical ancestor path. Hashing uses semantic fields. Font generation, rem units, viewport, descendant layout, focus, hover, opacity, and clipping invalidate the relevant records. Both caches cap retained payloads at 8 MiB and entries at 4,096.

Layout entries hold subtree measurements and arranged bounds in preorder. Restoration maps that order to the new frame's node indices. Non-void custom layout state always runs its layout phase. Pure custom elements with void layout state, such as generated icons, can reuse measurement and arrangement while retaining valid phase storage.

Regressions compare cached bounds and scene commands with fresh computation after edits, sibling updates, hover, resize, and render failure. They also exercise duplicate keys in separate scopes, font-generation changes, custom phase initialization, cache eviction, and every allocation failure in text-cache creation and replacement.

This establishes skipped-work behavior and output equivalence. A runtime speedup against GPUI remains unmeasured. Broader library gaps, including accessibility, advanced layout, vector paths, and editor service incrementality, remain tracked in the audit.

Validation completed before push:

- `./tools/zig build check --summary all`: 53/53 build steps, 362 tests passed and 5 explicitly skipped.
- `./tools/zig build test --summary all`: 136/136 framework tests passed.
- `./tools/zig build test-editor-native --summary all`: 185/185 native framework and editor tests passed.
- `git diff --check`: passed.
