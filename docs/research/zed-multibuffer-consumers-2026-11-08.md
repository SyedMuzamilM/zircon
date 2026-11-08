# Zed multibuffer and Zircon's editable projections

Inspected `/tmp/zigpui-zed-current-20261106` at immutable Zed revision `b5cd310b3b54dfc659fcc06453e6358843dfe216` with `git show`. The checkout is sparse, so the source was read from the immutable object rather than assumed to be present on disk.

## The upstream model

Zed's `multi_buffer` crate is an editor model. It owns source `Buffer` entities, a merged `MultiBufferSnapshot`, excerpt ranges, diff state, subscriptions and grouped history. A multibuffer offset is a view coordinate. `Anchor` retains a source `BufferId` and a text anchor, so it survives edits and resolves back to the source. `ExcerptAnchor` additionally tracks the path key and optional diff-base anchor.

`set_excerpts_for_buffer` and `build_excerpt_ranges` add context around primary ranges. `snapshot` synchronizes source changes before returning a read-only projection. `edit`, `edit_before` and `edit_non_coalesce` accept projected ranges and route them to source buffers. `History` groups edits across buffers, clears redo after a completed transaction and carries source transaction IDs for undo/redo.

The snapshot tracks byte offsets, UTF-16 offsets, points, rows, excerpts, deleted diff hunks and source mapping. Source edits publish `BufferRangesUpdated`, `BuffersEdited`, `Edited`, `TransactionUndone`, `Reloaded`, `Saved` and related events. Consumers subscribe to those events rather than rebuilding a copied string as their source of truth.

## Direct consumers found

| Consumer | How it uses the model |
| --- | --- |
| `git_ui::text_diff_view` | Creates a read/write `MultiBuffer`, installs source excerpts and `BufferDiff`, then builds a split/unified editor. Its hunk controls inspect multibuffer snapshots and selections. |
| `git_ui::project_diff` | Exposes the active diff editor's `MultiBuffer` and snapshot, computes hunk state from source identity and selection ranges, and keeps file navigation separate from row positions. |
| `search::project_search` | Stores search results in a `MultiBuffer`, refreshes excerpt ranges as files/results change, maps selected anchors to source buffers and keeps one editor projection for results. |
| `search::text_finder` | Converts match ranges through multibuffer anchors and source snapshots instead of assuming a flat result string. |
| `editor::hover_links` | Maps source/LSP ranges through `MultiBufferOffset` and anchors for navigation and display. |
| `editor::git::blame` | Subscribes to buffer range/edit events and regenerates blame when source content or excerpt mapping changes. |
| `git_ui::conflict_view` | Registers an editor against a multibuffer for conflict regions. |

The Git UI dependency list includes `multi_buffer`, `buffer_diff`, `editor`, `language`, `ui` and workspace services. This is a model boundary, not a widget package. Zed's `ui` and `extensions_ui` sit above GPUI and consume editor/domain models. Zircon should keep `zircon_extensions` data-only and keep the multibuffer model independent of `zircon_ui`.

## Zircon implementation

`packages/zircon_multibuffer` now provides the first source-backed core. A source is a workspace `DocumentId` plus an immutable `zircon_text.Snapshot`. An excerpt stores source identity and a source byte range. The projection concatenates excerpt bytes for rendering, while `edit(ProjectedRange, replacement)` returns a `SourceEdit` with the original document ID, the source revision observed by the projection, and the source range. Edits crossing an excerpt or source boundary return `CrossExcerptEdit`. `setSources` replaces several source snapshots and their excerpt order atomically, retaining the previous projection if validation or allocation fails.

`Anchor` stores source identity, byte offset and insertion bias. `updateSource` remaps excerpt ranges through `text.Change` mappings and swaps the retained snapshot. `mapAnchor` applies the same mapping. Revision mismatches return `StaleSourceRevision`. The package does not mutate workspace documents; the caller must group returned source edits through the existing workspace transaction and publish `DocumentChange` values.

The Git service now creates this source-backed projection for every distinct open workspace document represented in a combined Git diff, while retaining the single-file selection path. The existing patch renderer remains a display projection. The experience suite opens two changed files, asserts that both source identities are retained, and still verifies that patch rows remain display-only until a multibuffer editor is wired into the view.

## Gaps before calling it full support

The current core does not yet provide UTF-16 projected points, context-line expansion, diff transforms, deleted hunks, per-source event subscriptions, grouped multi-document undo, virtualization or a multibuffer editor. The Git patch view still renders `git.Diff` rows. Search and diagnostics still use their existing copied excerpt models. Those are explicit WORK-02 follow-ups.

The next verifiable slice is a read/write editor backed by `zircon_multibuffer` for one open Git file. It should map a projected replacement to the workspace `DocumentId`, apply one undoable transaction, update anchors and hunk state, and reject a stale source revision. Then add multiple source excerpts and grouped transactions. Do not flatten several files into one workspace document.

Primary source links:

- [`multi_buffer/src/multi_buffer.rs`](https://github.com/zed-industries/zed/blob/b5cd310b3b54dfc659fcc06453e6358843dfe216/crates/multi_buffer/src/multi_buffer.rs)
- [`multi_buffer/src/anchor.rs`](https://github.com/zed-industries/zed/blob/b5cd310b3b54dfc659fcc06453e6358843dfe216/crates/multi_buffer/src/anchor.rs)
- [`multi_buffer/src/transaction.rs`](https://github.com/zed-industries/zed/blob/b5cd310b3b54dfc659fcc06453e6358843dfe216/crates/multi_buffer/src/transaction.rs)
- [`git_ui/src/text_diff_view.rs`](https://github.com/zed-industries/zed/blob/b5cd310b3b54dfc659fcc06453e6358843dfe216/crates/git_ui/src/text_diff_view.rs)
- [`git_ui/src/project_diff.rs`](https://github.com/zed-industries/zed/blob/b5cd310b3b54dfc659fcc06453e6358843dfe216/crates/git_ui/src/project_diff.rs)
- [`search/src/project_search.rs`](https://github.com/zed-industries/zed/blob/b5cd310b3b54dfc659fcc06453e6358843dfe216/crates/search/src/project_search.rs)
