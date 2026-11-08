# Editor workflow audit

This audit compares Zircon commit `716dfdbbfcac76d75493fe5c477d717d4c37641c` with Zed upstream commit `b5cd310b3b54dfc659fcc06453e6358843dfe216`. The installed reference was Zed Preview `1.28.0`, build `20261104.153513`. The source comparison uses pinned Zed source and official documentation. The running Zed window was also observed through macOS accessibility and a screenshot.

The detailed reviews are [editing and language](editing.md), [Git](git.md), and the [Zed workflow reference](../../research/zed-workflows-reference-2026-11-08.md).

## Highest-priority defects

| Priority | Area | Finding | Evidence |
| --- | --- | --- | --- |
| P1 | Completion | A valid completion with only `label` and `insertText` duplicates the typed prefix: `pri` becomes `priprint`. | `apps/zircon/src/services/language.zig:351`; fresh headless app repro, repeated twice. |
| P1 | Completion | Applying `additionalTextEdits` creates an extra caret. The next keystroke can edit the import and the completion site together. | `apps/zircon/src/services/language.zig:351-358`, `packages/zircon_editor/src/editor.zig:252-259`; fresh headless app repro. |
| P1 | Git | Filenames containing spaces retain Git's header delimiter tab, so the diff source does not match the status path. Newline-quoted paths also remain escaped. Live open, edit, and stage actions fail for those files. | `packages/zircon_git/src/diff.zig`; real Git repository parser repro. |
| P1 | Git | View Stash sets the selected stash but discards the returned patch because the result has no matching history identity. The stash view settles with no diff. | `apps/zircon/src/services/git.zig`; real app repro. |
| P2 | Editing | Save As from a split secondary editor updates only the primary editor's language. The secondary view keeps the old language and grammar. | `apps/zircon/src/actions.zig:681-689`; fresh headless app repro. |
| P2 | Editing | Normal file polling watches directory metadata but does not reload an open clean buffer after an external file write. | `apps/zircon/src/services/project.zig:8-35`; fresh headless app repro. |
| P2 | Git | External commits and branch/ref changes leave history and references stale after ordinary refresh. Manual Git refresh repairs the view. | `apps/zircon/src/services/git.zig`; fresh app repro. |
| P2 | Git | A combined comparison containing text and binary changes drops the binary entry when text hunks exist. | Git comparison rendering; fresh app repro. |
| P2 | Search | Project search includes files ignored by `.gitignore`. The index ignores only a fixed directory/name list. | `apps/zircon/src/project_index.zig:105-111`; fresh headless app repro. |
| P2 | Search | Clearing the project-search query leaves the previous result set visible. The empty-query path returns before clearing the model. | `apps/zircon/src/services/search.zig:67-71`; fresh headless app repro. |

## What is already working

Zircon has a substantial editing base: text insertion/deletion, multiple selections, undo/redo, split views, save policy, CRLF-aware coordinates, folding, wrapping, buffer find/replace, completion transport, hover, push diagnostics, language-server lifecycle, Git status and staging, working-tree diff editing, history, branch/stash/network actions, and project search over indexed files plus open buffers. Existing native checks and the installed clangd journey passed. The fresh native run reported 130 passing tests, and the real-language run reported 131 passing tests.

The existing test suite does not cover the completion item shapes above, external file observation, Git path quoting, stash display, stale Git metadata, mixed binary comparisons, ignored-file search, or clearing search results. Those are the first regression tests to add.

## Largest capability gaps versus Zed

Zed's current language workflow also includes definition, type definition, implementation, references, rename, code actions, document/workspace symbols, signature help, formatting, semantic tokens, richer diagnostics presentation, and source-backed multibuffers shared by search, diagnostics, references, and Git diffs. Zircon currently has no complete workflow for those LSP requests. It also lacks encoding detection/preservation, semantic tokens, LSP folding, format-on-save, full diagnostic navigation, snippets, and automatic bracket/quote pairing.

Zed's project search honors ignore rules and searches dirty buffers using their live snapshots. Zircon searches open tab snapshots and indexed disk files, but its index has fixed depth/count limits and no `.gitignore` parser. Zircon's search package has strong revision checks and cancellation, but the UI has no replacement workflow for project results.

Zed's Git workflow separates disk, buffer, index, and `HEAD`, supports editable working diffs through source-backed multibuffers, and keeps staged/history views read-only. Zircon's working diff editing is a strong foundation, but hunk-level stage/unstage/restore, conflict resolution, reliable stash display, complete binary metadata, quoted-path decoding, and consistent external metadata refresh remain.

## Verification

- Fresh native suite: `./tools/zig build test-native-fresh --summary all`, 130 passed.
- Fresh installed-language suite: `./tools/zig build test-language-real --summary all`, 131 passed including the real clangd completion journey.
- Full repository check: `./tools/zig build check --summary all`, 104 app tests passed plus 4 skipped and all 53 build steps passed.
- Fresh language/editor package suites: 17 language and 49 editor tests passed.
- Focused adversarial app and Git repros are preserved under [`git-evidence/`](git-evidence/). The search repro was run from `/tmp/audit-search-repro.zig`; it reproduced ignored-file inclusion and stale results after clearing the query.

The audit made no production-code changes. The findings are ready to turn into a fix sequence: completion transaction correctness first, then Git path/stash correctness, then external refresh and project-search semantics, followed by the larger LSP workflows.
