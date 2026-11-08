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

Git now loads live source documents for the worktree comparison, including files without an existing visible source tab. Each current/context diff row resolves its document and revision through `zircon_multibuffer`. Clicking it activates a source editor in place, keeping file headers, hunk headers, deleted lines and staging controls visible. Removed lines, staged comparisons and immutable commits remain read-only. Source documents own text, save state and undo/redo; there is no separate flattened editable document or edit-mode toggle.

The Git worker overlays unsaved snapshots on its repository comparison with the bounded line-diff algorithm. It publishes a result only while its captured source revisions are current. Typing, newline changes, undo, redo and save refresh the diff. Revisioned document events map rows while a refresh is pending. Native integration tests exercise the same AppKit/CoreText/Metal rendering path as the editor.

Commit history opens distinct entries in the main top tab strip. Each retains its patch, mode, collapsed paths, scroll and commit message; reselecting an immutable commit uses that retained presentation. The body shows commit metadata and message above its read-only patch.

## Gaps before calling it full support

The current core does not yet provide UTF-16 projected points, context expansion, a shared display-map model, or grouped undo across several source documents. Search and diagnostics still use their existing excerpt models. Cross-file selections and edits, drag selection across several diff rows, and split-diff editing need separate acceptance before claiming full Zed parity. The live Git view currently edits one source through the normal editor transaction/history contract at a time.

Primary source links:

- [`multi_buffer/src/multi_buffer.rs`](https://github.com/zed-industries/zed/blob/b5cd310b3b54dfc659fcc06453e6358843dfe216/crates/multi_buffer/src/multi_buffer.rs)
- [`multi_buffer/src/anchor.rs`](https://github.com/zed-industries/zed/blob/b5cd310b3b54dfc659fcc06453e6358843dfe216/crates/multi_buffer/src/anchor.rs)
- [`multi_buffer/src/transaction.rs`](https://github.com/zed-industries/zed/blob/b5cd310b3b54dfc659fcc06453e6358843dfe216/crates/multi_buffer/src/transaction.rs)
- [`git_ui/src/text_diff_view.rs`](https://github.com/zed-industries/zed/blob/b5cd310b3b54dfc659fcc06453e6358843dfe216/crates/git_ui/src/text_diff_view.rs)
- [`git_ui/src/project_diff.rs`](https://github.com/zed-industries/zed/blob/b5cd310b3b54dfc659fcc06453e6358843dfe216/crates/git_ui/src/project_diff.rs)
- [`search/src/project_search.rs`](https://github.com/zed-industries/zed/blob/b5cd310b3b54dfc659fcc06453e6358843dfe216/crates/search/src/project_search.rs)

## Later implementation status

The editor workflow follow-up now adds editable Project Search excerpts, independent split-pane source views, source range remapping, per-source undo/redo and saving dirty results. See [the current progress record](../progress/2026-11-08-editor-workflow-fixes.md). The earlier gaps section describes the initial implementation; cross-source selection and grouped transactions still remain.
