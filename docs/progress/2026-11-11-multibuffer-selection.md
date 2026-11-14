# Multibuffer selection and clipboard delivery

This delivery covers WORK-02 selection and transaction behavior for Search and
Git. It builds on the existing uncommitted source-backed Search and grouped
history work. It does not close the full editor roadmap.

Git unified patches now support dragging across context, added and deleted text,
including multiple hunks and files. Split selection stays on its starting side
and skips alignment padding. Normal Cmd+C and Edit > Copy copy selected code
without diff prefixes, line numbers or file/hunk headings. The old Copy added and
Copy deleted buttons and their separate clipboard helper were removed.

Deleted text, staged comparisons, the old split side, and commit history remain
immutable while supporting selection and copying. History tabs retain their
review snapshots and selections. Copying a commit reads the commit patch rather
than today's workspace file. Mutations touching immutable rows stop before any
source changes. Live edits validate source identity, revision and displayed
bytes before using the shared multibuffer transaction owner. Contiguous edits
continue through the source editor for pairing, composition and ordinary source
history. Cross-source replacement/cut uses one grouped undo step.

`zircon_git_ui.review.Review` owns derived, immutable patch text, a row map and an
ordinary `zircon_editor.Editor` for selection/navigation/clipboard behavior.
Workspace documents remain the editable source of truth. The review snapshot
has no editing history. Existing source canvases paint live rows, and the shared
code-line painter highlights immutable rows with the same selection color and
text metrics. Both paths use the configured tab width and horizontal scroll.

The Search projected selection path now recognizes the ordinary editor clipboard
chords before dispatching to a single source. This fixes Cmd+C/Cmd+X and native
menu actions on selections across files. Search and Git also share continuous
drag autoscroll. The pointer can remain still outside the viewport while the
selection advances; release or window focus loss cancels it.

## Acceptance coverage

- Partial-word and reverse multiline selection of deleted Git text, with actual
  selection rectangles in the rendered scene and exact clipboard bytes.
- Shift navigation, keyboard Copy and platform menu Copy.
- Mixed immutable/live selection rejecting text, deletion, cut, paste and undo
  without changing workspace files.
- Staged selection and copy preserving the actual Git index.
- Split-side isolation, cross-file live cut and grouped source undo.
- Historical selection copying committed text while today's file differs, then
  retaining that selection after switching tabs.
- External source reload invalidating live projected selections before the
  asynchronous diff catches up. Stale live clicks fall back to the actual source
  editor instead of editing the review snapshot.
- Git and Search autoscroll with no further pointer movement, then stopping on
  release.
- UTF-8 endpoint validation, CRLF preservation, missing final newlines, collapsed
  files, split padding and matching refresh retention in the Git UI package.
- Existing source editing, save, undo/redo and Search journeys remain in the
  portable and native suites.

During implementation, the reverse-drag journey caught a row-style replacement
that dropped fixed line heights. The dedicated cursor setter preserves those
heights, keeping painted geometry and hit testing aligned. An initial standalone
native-input run also reported duplicate key delivery; a fresh rerun passed
without changing platform input code. A separate settings hover assertion also
failed once, then passed in the next full native run without settings changes.

## Remaining limits

This is not a complete Zed display-map implementation. UTF-16 projected points,
context expansion, wrapped excerpts, diagnostics migration, broad modal editing
across projections, and large-project profiling remain work. Cross-source native
composition has no projected surrounding-text contract and does not mutate
several sources. File/hunk headings and binary metadata are outside the selected
code projection. Selection retention across a changed patch is conservative:
both endpoint rows must still match the same file and text.
Live selections involving a changed source are cleared while a refreshed patch
is pending; immutable selections keep referring to their captured revision.

The architecture research is in
[Zed and Delta editor foundations](../research/zed-delta-editor-foundations-2026-11-11.md).

## Final verification

- `./tools/zig build --summary all`: all 60 build/check/install steps succeeded;
  the application suite executed 134 passing tests with 5 skips. Other unchanged
  package verdicts were cached. Formatting, import ordering, examples and contract
  checks passed.
- `./tools/zig build test-native-fresh --summary all`: 162 tests passed in fresh
  sequential execution, including 125 editor journeys, 27 renderer/framework
  checks, 9 native window/input checks and the settings regression.
- `git diff --check`: passed. Temporary diagnostic logs were removed.

The updated development application is `zig-out/Zircon.app`; the executable is
`zig-out/bin/zircon`. This work preserves the pre-existing uncommitted Search,
multibuffer transaction and text-document changes and does not create a commit.
