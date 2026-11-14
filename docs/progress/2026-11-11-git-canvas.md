# Git canvas follow-up

The Git comparison now uses the source editor's green 6-pixel gutter for added lines, including wrapped continuations. Read-only rows match the editor's gutter width, line-number alignment and semantic change colors.

Raw patch headings have been replaced by context expansion arrows. The three icons are unchanged Zed SVGs at revision `b5cd310b3b54dfc659fcc06453e6358843dfe216`. Their source and ISC attribution are recorded in `assets/icons/SOURCE.md`. The corresponding Zed editor buttons call `expand_excerpt` in `crates/editor/src/element.rs`.

Expansion reveals 20 lines per direction from a captured comparison file. Workers capture worktree text including unsaved buffers, index text for staged comparisons, and the selected commit or stash text for history. UI clicks perform no Git I/O. Expansion persists across refreshes, stops at neighboring hunks and preserves a missing final newline. Added and unchanged working-tree context edits the actual source document.

The missing native input target came from a canvas focus request on a non-focusable element. Source canvases now accept focus. In split panes, the enclosing tool container yields focus to the live canvas. Native AppKit key events verify first-click editing on both added and unchanged lines.

Git previously disabled wrapping explicitly. It now follows the configured editor setting. The source editor and immutable diff rows use the same segment-shaping algorithm, including tab expansion and hanging indentation. A cached display layout drives row heights, context-control placement, split alignment, selection hit testing and caret scrolling. Up/Down traverses wrapped continuations without selecting split padding or hidden context. Resizing recalculates geometry without adding whitespace to source files. Wrapped painting and clicks ignore any earlier horizontal scroll offset. Split-side keyboard input retains the side's wrap width, so typing and caret reveal do not temporarily reshape against the full comparison width.

Extension highlighting previously scheduled only active tabs and active excerpt sources. Every live source in a visible Git comparison now qualifies for grammar work. Results propagate to all source views before a chunk is clicked. A two-file extension fixture reproduces the missing inactive-source highlighting with the scheduling fix removed and passes with it restored.

## Verification

Focused application journeys cover matching gutter rectangles, context expansion and editing after refresh, native text entry, wrapped continuation clicks and Up/Down, resize reflow, split-pane focus and inactive-source grammar work. Git UI package tests cover captured gap expansion, neighboring hunks, final newline preservation and unified/split wrapped geometry.

The earlier [selection delivery](2026-11-11-multibuffer-selection.md) records clipboard and shared transaction behavior. This follow-up supersedes its remaining-work entries for Git context expansion and wrapped Git excerpts. Search wrapping, projected UTF-16 coordinates, cross-source native composition, diagnostics migration and large-project performance acceptance remain open.

Final checks:

- `./tools/zig build --summary all`: all 60 build/check/install steps passed. The application suite executed 143 passing tests with 5 skips; unchanged package results were cached. An earlier complete check executed 360 passing tests with 5 skips, including the changed editor, Git UI and framework packages.
- `./tools/zig build test-native-fresh --summary all`: 169 tests passed and 2 foreground activation checks skipped because macOS denied activation. Window-bound AppKit text entry passed, including the new Git canvas journeys.
- Formatting, import ordering, examples, contract checks and `git diff --check` passed. No temporary debug logging remains.

The development build is `zig-out/Zircon.app`, with executable `zig-out/bin/zircon`. Existing uncommitted changes were preserved. No commit was created.
