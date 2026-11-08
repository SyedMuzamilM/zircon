# Inline Git editing and history tabs

Verified on macOS/aarch64 with Zig 0.17.1. The original separate source-mode draft was removed; these checks exercise typing directly inside the unified diff.

- `check.log`: 45/45 build steps, including 97 application checks and four explicit native-only skips, five multibuffer checks and 46 editor checks. Some other package checks used cached results.
- `native.log`: 122 native checks, comprising 9 AppKit window checks, 27 framework checks and 86 application journeys. Counts overlap portable journeys and are not unique-test totals.
- `editable-git.png`: real native rendering after direct diff typing, newline insertion, undo, redo and save.
- `history.png`: two commits alongside source files and Uncommitted changes in the main top tab strip, with commit metadata/message above the patch.

The direct-edit journey verifies exact source bytes, unchanged disk bytes before save, refreshed hunk line numbers, grouped typing undo, redo and saved bytes. Initially unopened changed files are loaded into workspace ownership. Deleted rows and history stay read-only. Vim journeys verify pending `g`/`gc`, clearing after command completion, and `g /` project search. History checks locate the commit button inside the main `tabs` bounds and verify distinct retained entries.

Cross-file selection/grouped history, selection dragging across multiple diff rows, full diff-display transforms and split-diff editing remain open. Portable Linux/Windows compilation is separate from native desktop support.
