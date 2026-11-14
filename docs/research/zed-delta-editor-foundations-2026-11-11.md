# Zed and Delta editor foundations

Date: 2026-11-11

The subsequent [selection delivery](../progress/2026-11-11-multibuffer-selection.md)
implements the clipboard, deleted/history selection and autoscroll work below.
The initial implementation findings in this note describe the preceding audit.

This note records the current Zircon implementation review against the linked
Zed and Delta material. All eight supplied URLs returned HTTP 200 on the review
date. Zed source references use commit
`b5cd310b3b54dfc659fcc06453e6358843dfe216`. The editor element, display map,
multibuffer and text diff source were fetched from GitHub during this review;
other consumer details also draw on the earlier pinned research notes. Delta's
article includes architectural explanations and illustrative code. Those are
first-party descriptions, rather than an independently inspected source tree.

## What Zircon has today

`zircon_multibuffer.MultiBuffer` already keeps source document identities,
retained snapshots, excerpt ranges, projected offsets, anchors, revision checks,
copying, and source edits in one model. `apps/zircon/src/search_selection.zig`
adds a projected selection that can span Search excerpts and files. Its pointer
handler captures the pointer on the whole result page, maps the hit back to a
source editor, and uses `MultiBuffer.copy` and grouped transactions for copy,
cut, paste, replacement, undo, and redo.

The current Git view is only partly multibuffer-shaped. A live added/context row
creates a source `Editor` canvas through `git_editing.renderBlock`; the source
editor owns selection and edits. `packages/zircon_git_ui/src/layout.zig`
provides the shared row projection and hit test. Deleted rows, staged comparisons,
old split sides, and selected commits use the patch row renderer instead. They
have no projected selection, so `diff_controls.zig` adds separate “Copy added”
and “Copy deleted” buttons.

History is a read-only commit patch. `commit_details.zig` renders metadata and
`diff.zig` renders the same patch content path. There is no source-backed
selection for the historical side, even though read-only text can still be
selected and copied in a useful editor.

The editor canvas is already a real custom element. `packages/zircon_editor/src/canvas.zig`
copies the visible snapshot window and selection state into a frame-owned
`Canvas`, computes visible rows in `prepaint`, shapes text with CoreText through
`zircon_ui`'s text measurer, and paints selection rectangles, text, gutters, and
Git annotations. `packages/zircon_ui/src/graphics/backends/metal.zig` caches
CoreText glyphs in a Metal atlas and draws the shaped runs. Replacing this with a
new widget would not address the multibuffer problem.

## Zed source lessons

Zed's `multi_buffer` crate is an editor model rather than a diff widget. Its
source buffers remain authoritative. Excerpts and anchors map a projected view
coordinate to a source `BufferId` and text anchor. The snapshot owns the projection
mapping, UTF-8/UTF-16 points, rows, excerpts, deleted diff hunks, and source
identity. Edits arrive in projected coordinates and are converted into source
buffer edits. History groups the resulting source transactions and exposes
buffer change events to consumers.

The next stage is `DisplayMap`, which owns a `MultiBuffer` and transforms it
through `InlayMap`, `FoldMap`, `TabMap`, `WrapMap`, and `BlockMap`. Each layer has
snapshots, coordinate conversions and input/output summaries. This is separate
from the actual GPU canvas. See
[`display_map.rs:1`](https://github.com/zed-industries/zed/blob/b5cd310b3b54dfc659fcc06453e6358843dfe216/crates/editor/src/display_map.rs#L1).

`EditorElement` then implements GPUI's element lifecycle. `request_layout` sizes
the editor for single-line, auto-height or full modes. `prepaint` gets the editor
snapshot and read-only state, resolves fonts and metrics, and prepares viewport
layout. `paint` installs text input, actions and pointer handling, then draws
backgrounds, guides, line numbers, text and blocks through GPUI. The entry points
are [`element.rs:8491`](https://github.com/zed-industries/zed/blob/b5cd310b3b54dfc659fcc06453e6358843dfe216/crates/editor/src/element.rs#L8491),
[`8566`](https://github.com/zed-industries/zed/blob/b5cd310b3b54dfc659fcc06453e6358843dfe216/crates/editor/src/element.rs#L8566)
and [`10093`](https://github.com/zed-industries/zed/blob/b5cd310b3b54dfc659fcc06453e6358843dfe216/crates/editor/src/element.rs#L10093).
The reviewed text diff creates a `MultiBuffer`, attaches source excerpts and a
`BufferDiff`, then passes it to `SplittableEditor` at
[`text_diff_view.rs:176`](https://github.com/zed-industries/zed/blob/b5cd310b3b54dfc659fcc06453e6358843dfe216/crates/git_ui/src/text_diff_view.rs#L176).

The most relevant pinned files are:

- [`multi_buffer/src/multi_buffer.rs`](https://github.com/zed-industries/zed/blob/b5cd310b3b54dfc659fcc06453e6358843dfe216/crates/multi_buffer/src/multi_buffer.rs)
- [`multi_buffer/src/anchor.rs`](https://github.com/zed-industries/zed/blob/b5cd310b3b54dfc659fcc06453e6358843dfe216/crates/multi_buffer/src/anchor.rs)
- [`multi_buffer/src/transaction.rs`](https://github.com/zed-industries/zed/blob/b5cd310b3b54dfc659fcc06453e6358843dfe216/crates/multi_buffer/src/transaction.rs)
- [`git_ui/src/text_diff_view.rs`](https://github.com/zed-industries/zed/blob/b5cd310b3b54dfc659fcc06453e6358843dfe216/crates/git_ui/src/text_diff_view.rs)
- [`git_ui/src/project_diff.rs`](https://github.com/zed-industries/zed/blob/b5cd310b3b54dfc659fcc06453e6358843dfe216/crates/git_ui/src/project_diff.rs)
- [`git_ui/src/diff_multibuffer.rs`](https://github.com/zed-industries/zed/blob/b5cd310b3b54dfc659fcc06453e6358843dfe216/crates/git_ui/src/diff_multibuffer.rs)
- [`search/src/project_search.rs`](https://github.com/zed-industries/zed/blob/b5cd310b3b54dfc659fcc06453e6358843dfe216/crates/search/src/project_search.rs)

Zed's rope and SumTree articles explain why summaries are stored beside text:
byte length, line count, UTF-16 length, and other aggregates let the editor
answer offset, row, and display-range queries without flattening the document.
The same principle is useful for Zircon's rope summaries and for a future Git
display map. The current Zircon multibuffer still lacks projected UTF-16 points,
context expansion, and a shared display-map object.

The rope optimization article specifically indexes newlines, UTF-8 character
boundaries and UTF-16 information in bitmasks on 128-byte chunks, then adds a tab
mask. Zircon currently uses AVL nodes with leaves up to 4 KiB and aggregate byte,
line and UTF-16 summaries. Preserve that existing structure until profiles show
leaf scans are a bottleneck. The article's benchmark numbers do not establish
that Zircon would become faster by copying Zed's chunk size or bit operations.

The coordinate-system article is directly relevant to pointer selection. A
single UI point can be converted through screen, display row, excerpt, and source
coordinates. Those conversions must carry affinity at boundaries so a drag over
a separator or deleted row chooses the intended adjacent anchor.

The tasks article covers terminal task templates and Tree-sitter runnables,
rather than editor background scheduling. Tasks use variables such as the current
file, selected text, and symbol. `runnables.scm` captures syntax nodes with tags
that match task definitions, producing gutter run buttons. This is a useful next
step for Zircon's existing terminal and language support. Resolving a runnable in
Search or a diff must first map the cursor back to the correct source file.

The Vim article explains the conflict between Vim's cursor on a character and
Zed's cursor between characters, including inclusive newlines and repeat-command
semantics. Zed preserves its own text model rather than embedding Neovim, and
uses Neovim to test compatibility. Zircon should define projected selection
boundaries first, then test modal behavior against those boundaries.

The five Zed source articles are:

- [Rope Optimizations, Part 1](https://zed.dev/blog/zed-decoded-rope-optimizations-part-1)
- [Rope & SumTree](https://zed.dev/blog/zed-decoded-rope-sumtree)
- [Syntax-Aware Task Spawning With Tree-Sitter](https://zed.dev/blog/zed-decoded-tasks)
- [Why not just embed Neovim?](https://zed.dev/blog/zed-decoded-vim)
- [Text Coordinate Systems](https://zed.dev/blog/zed-decoded-text-coordinate-systems)

## Delta lessons

Delta's thread UI article supplies concrete editor architecture and code samples,
although it does not provide a complete reusable implementation. One underlying
buffer supplies contiguous selection. A formatter styles buffer ranges, hides
Markdown delimiters, replaces rendered text, marks ranges read-only, embeds
elements, and adds gutters. These are editor ranges, so users can select across
tables and tool cards. Comments have separate buffers attached to anchor ranges;
they are interleaved during layout instead of inserted into the primary text.

Its custom GPUI element runs `request_layout`, `prepaint`, and `paint`.
`prepaint` shapes text into positioned glyphs. Scrolling stores a stable buffer
anchor plus a pixel offset within the anchored line. Formatting seeks to the
viewport and stops once it fills. A separate B+ tree stores runs of measured or
unmeasured row heights for scrollbar estimates, refined in small idle slices.
Stale height estimates affect the scrollbar, while current visible text is laid
out directly. This separation is useful for Zircon's expanding hunks and future
rich agent transcript, which currently have no shared anchor-based display map.

The October update explicitly adds links to selections in files and diffs, and
opens a historical file/diff when a comment refers to deleted code. That supports
preserving revision identity along with text positions. The public beta post
describes DeltaDB retaining edits between Git commits and review subthreads with
isolated worktrees. Those collaboration features are later scope for Zircon.

- [The Diff: October 2026](https://delta.dev/blog/the-diff-2026-10)
- [Replace PRs with Delta – Now in Public Beta](https://zed.dev/blog/delta-public-beta)
- [Building a thread UI on hard mode](https://delta.dev/blog/building-a-thread-ui-on-hard-mode)

## Recommended implementation

1. Add a `DiffSelection` to `zircon_git_ui` that stores projected row anchors,
   source identity where available, and a read-only patch-text anchor where no
   live source exists. This is a consumer of shared projected selection logic,
   not a second independent clipboard or editor implementation. Put diff-specific
   row mapping beside the existing `Projection`; keep selection and copy rules
   reusable with Search. Historical identity must include repository, commit or
   blob, path and side rather than a live workspace document ID alone.
2. Make unified and split views expose one display-row map. A row records file,
   hunk, side, source line or deleted patch line, byte range, and screen bounds.
   Deleted rows remain selectable and copyable even though they are immutable.
3. Route Git `copy`, `cut`, `paste`, `select_all`, and selection painting through
   that model. `cut` and `paste` should be enabled only for live worktree source
   ranges. Copy must work for live, deleted, staged, and historical rows.
4. Remove the hunk-level copy buttons after the shared selection path has native
   acceptance coverage. Keep staging and navigation controls; they are actions
   on the diff, not alternate clipboard APIs.
5. Give history the same read-only diff selection model. A selected commit can
   copy exact patch text, including deleted lines and metadata, while edits and
   staging remain disabled.
6. Keep `zircon_editor.Canvas` and generalize its text input to a projection
   snapshot that can contain live source ranges and immutable revision text.
   Deleted lines should use that shared selection and layout path. Headers and
   controls remain display blocks. Avoid another independent patch-text editor.
7. Extend tests with drag selection across added/context/deleted rows, split-side
   selection, historical commit selection, redraw/scroll pointer capture, UTF-8
   and CRLF boundaries, and copy output. Then remove assertions that require the
   old copy buttons.

## Priority order

The first vertical slice should be Git unified working diff selection plus copy
of deleted rows. Next apply the same model to split and history views. Then share
the display-map and anchor code with Search, diagnostics, and future threaded
review. Only after that should the project tackle broader Zed parity such as
context expansion, full UTF-16 display points, grapheme movement, hunk staging,
conflict resolution, and large-project performance budgets.

Validation run during this review:

```text
./tools/zig build test-multibuffer test-git_ui test-editor test-app --summary all
  190 passed, 5 skipped
./tools/zig build test-editor-native -Dnative-test-filter='project search' --summary all
  44 passed
./tools/zig build test-editor-native -Dnative-test-filter='Git multibuffer' --summary all
  39 passed
```

Those tests validate the current Search and live Git source-editor paths. They
do not yet validate selection of deleted or historical patch text, which is the
specific gap this recommendation addresses.

Acceptance for the next slice must include partial words and multiple lines of
deleted text, ordinary Cmd-C and menu Copy, Shift selection, dragging in either
direction, and pointer capture across redraw and scroll. Unified copy should
serialize the selected code in display order without line numbers, hunk headers,
or synthetic `+`/`-` gutter markers. Split selection should stay in its chosen
side and skip alignment padding. A selection containing immutable text should
remain copyable while replacement and cut must reject the immutable range
without partial source mutation. Commit selection must not read today's file
contents. Add native history and deleted-row journeys because the current live
Git test neither attempts those selections nor asserts their clipboard result.

Search is further along, but still needs acceptance for drag autoscroll, large
result sets, refresh while selecting, overlapping excerpts, and cross-source IME.
The current cross-source input path explicitly rejects composition. Both Search
and Git currently disable soft wrapping for their source excerpt editors. Their
projected lookup paths remain linear in sources/excerpts, so no large-project
scaling claim follows from the passing small fixtures.
