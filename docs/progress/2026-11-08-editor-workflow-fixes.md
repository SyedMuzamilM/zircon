# Editor workflow fixes, November 8

This record supplements the earlier workflow audit. It records implemented behavior separately from remaining Zed parity work.

## Implemented

- Language workspace edits retain request revisions, validate open target revisions, prepare every document before publishing text, preserve selections, and open ordinary dirty tabs for newly loaded targets. Rename, formatting, and edit-based code actions share this path. Applying an edit leaves its language server running.
- Both LSP workspace-edit text encodings are parsed. Unsupported commands, action resolution, and resource operations have explicit unavailable reasons instead of terminating the server. Local file URI decoding handles uppercase escapes and Unicode.
- Diagnostics have a dedicated tab, severity filters, grouped files, virtual rows, scrolling, and source navigation. Stale diagnostics are excluded. The editor no longer appends an unbounded list beneath its canvas.
- Project Search and Language Results are separate tabs. Language results scroll and use readable paths.
- The Git sidebar compacts directory chains, retains branches and disclosure state, switches between tree and flat-list modes, and displays plain colored change counts.
- Typed brackets and quotes pair on the ordinary and native input routes. Generated closers can be skipped or removed with paired Backspace. Selection wrapping retains orientation and multicursors. Composition and multi-character pastes remain literal. Newline between a pair puts the closer on a separate indented line.
- Matching brackets receive a subtle background, and the enclosing multiline scope receives a brighter indentation guide. The scan skips lexical comments and strings. It is cached by document revision and caret, and bounded to a 128 KiB window; very large enclosing scopes outside that window are not highlighted.
- The editor context menu preserves a selection when right-clicking inside it and otherwise moves the caret to the click. It retains the source pane, validates its revision and selection, supports keyboard navigation and dismissal, and uses the configured shortcuts. It exposes supported language actions, clipboard actions, Finder reveal, and a terminal in the file's folder.
- F2, F12, Shift-F12, Option-Shift-F, Control-Shift-Space, and Command-period now have real bindings and native key mappings. Consumed native keys do not also reach AppKit text interpretation. A regression reproduced Format Buffer inserting an Option character before the fix.

## Zed context-menu reference

Source inspected at immutable revision `b5cd310b3b54dfc659fcc06453e6358843dfe216`:

- [Selection preservation and action grouping](https://github.com/zed-industries/zed/blob/b5cd310b3b54dfc659fcc06453e6358843dfe216/crates/editor/src/mouse_context_menu.rs).
- The menu retains editor focus, moves the caret only when the click falls outside selections, groups navigation/edit/clipboard/file actions, and dismisses when its selection changes.
- Zircon currently dismisses its menu on scroll. Zed's anchored menu follows the source while visible.

## Verification

- `./tools/zig build check --summary all`: 53/53 steps passed. The latest application run passed 116 tests and skipped 5 native-only cases. Other unchanged package results may be cached.
- `./tools/zig build test-native-fresh --summary all`: 144/144 tests passed in the final run. Earlier runs explicitly skipped foreground checks when macOS denied activation.
- `./tools/zig build test-editor --summary all`: 59 editor tests passed, including actual scene checks for bracket backgrounds and the scope guide.
- Text preparation tests cover aborting without changing undo/redo, stale commits, wrong-document commits, and repeated commits.
- App language-action tests cover a stale source, a changed second target, an invalid final edit, ordinary dirty-tab ownership, server survival, Save, and a real stdio definition request from the context menu.
- The diagnostics journey exercises 600 issues, severity filtering, scrolling to the final issue, opening another source, and excluding stale results.
- Git model and UI journeys cover compact chains, branching, collapsed ancestors, group identity, and switching modes.
- Native menu checks distinguish bound responder dispatch from foreground responder-chain routing. Activation denial is an explicit skip, not a pass. See [native verification](../native-verification.md).

## Remaining work

1. Extend Git beyond the verified basic operations. The application now publishes, fetches, pulls, commits and pushes against disposable bare remotes. Commit preserves an explicit index or implicitly stages tracked changes when empty. Stage and implicit Commit save affected buffers after checking captured revisions and paths; disk conflicts stop index mutation. Failed hooks retain their message/index, successful commits clear only the submitted message, and idle refreshes preserve refs/history allocations and skip history queries. External-network credentials, hunk staging, conflict controls, advanced history remain open. Multiline commit composition is now implemented with the editor text model, wrapping, selection, undo/redo and Command-Enter submission.
2. Complete editable global-search multibuffers and Git comparisons, including selection, editing, Save/Save All, clipboard/deleted hunks, undo and source synchronization. Existing Git inline editing covers a subset; global search is still display-only.
3. Add declaration, type-definition, implementation and call-hierarchy navigation. These screenshot actions are not in the context menu yet. File history and hosted permalinks also remain separate work; repository history is not a replacement for file history.
4. Add context menus to writable Git/search excerpts when their source targeting is complete. The new menu currently covers normal source panes and splits. Cut/Copy require a selection; Zed's empty-selection line-copy behavior remains open.
5. Support code-action resolve/commands, resource operations, prepare-rename and full LSP result presentation. Signature help remains a status label. Reference results are scrollable links, not editable source excerpts.
6. Expand diagnostics beyond the files currently opened by an enabled language server, and add full source excerpts/project diagnostics support.
7. Finish the audit's syntax, external reload, UI organization, formatting, performance and supported-language acceptance cases. Passing current fixture tests is not full Zed parity.

Scratch source copies remain excluded from commits.

## Git operation follow-up

The app workflow suite reproduces the disabled unstaged Commit control and stale disk staging before the fixes. It verifies conditional implicit staging, dirty-buffer staging, disk-conflict refusal, stale preparation refusal, explicit-index preservation, hook failure/retry, message retention, and local publish/fetch/pull/commit/push through real controls. Idle-refresh checks assert unchanged refs/history identities and no additional history commands, then verify external commits and clean source reloads. The full check passed 53/53 steps; a fresh native run passed 150/150 tests before the final stale-preparation test was added. That additional test passed independently.

## Commit message follow-up

The single-line field rejected multiline text and left HEAD unchanged in the new app regression. The commit input now uses an editor-backed document. The acceptance test types the subject, inserts blank lines with Enter, pastes a body, performs undo/redo, submits with Command-Enter and reads the exact message from Git. Draft and theme ownership checks use the new control. The full check passed 53/53 steps; the fresh native run passed 152/152 tests. A preceding portable full run intermittently failed the existing buffer-search invalid-query recovery assertion. Its isolated rerun and the subsequent full run passed; its timing cause remains unproven.
