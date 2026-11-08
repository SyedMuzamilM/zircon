# Git workflow audit

Result: **ISSUES**. Four defects reproduced against Zircon `716dfdbbfcac76d75493fe5c477d717d4c37641c`. This pass changes no application code. It audits the repository module, app services, command routing, diff editor and Git UI. It uses real local Git repositories and the real portable app entity/task/render pipeline, without desktop automation or native windows.

The comparison target is Zed upstream `b5cd310b3b54dfc659fcc06453e6358843dfe216`. Installed Zed Preview `1.28.0` is a separate artifact. [The primary-source reference](../../research/zed-workflows-reference-2026-11-08.md) establishes Zed capabilities; this pass did not run Zed or measure performance. Prior research supplied leads, and current source and fresh reproductions supplied conclusions.

## Confirmed defects

| ID | Priority | Trigger and observed result | Owner and acceptance check |
| --- | --- | --- | --- |
| G1 | P1 | Modify `space name.zig` and open all changes. Git's patch header ends the unquoted filename with a delimiter tab. Zircon retains it in `Hunk.path`, so the app opens the wrong path and creates **zero editable sources**. A newline filename instead retains the quoted `"b/line\\nname.txt"` spelling. Status has the actual bytes. | Decode patch header paths and delimiters in `packages/zircon_git/src/diff.zig:48`. Preserve actual path identity through diff headers, source opening, stage matching, collapse, navigation and unsaved overlays. Test real Git output for spaces, tabs, quotes, backslashes, Unicode and newlines; do not trim legitimate filename whitespace. |
| G2 | P1 | Create a stash, then run the exposed **View stash** action. `stash_view` and the selected stash OID update, but **no diff installs** after the worker finishes. | `views/git/picker.zig:52` sets selected_commit to the stash OID. `services/git.zig:365` stamps `history_oid` only for `.history`; `.stash_show` leaves it empty. The stale-result check at `services/git.zig:652` rejects it. Bind stash results to their actual target identity and test opening two stashes rapidly, returning to working changes and history, and read-only protection. |
| G3 | P2 | Make an external commit while the editor is open, then perform the normal automatic refresh path. The visible history still points to the old HEAD. Opening History itself also uses plain `.refresh`. | `services/git.zig:553` enables metadata only for an explicit flag, missing refs, or certain editor-originated mutations. `services/git.zig:461` loads history only with that metadata flag. Detect external HEAD/refs changes without republishing unchanged UI. Verify an external commit, branch checkout, fetch and stash update; explicit `.git_refresh` currently requests fresh metadata at `views/git/commands.zig:81`. |
| G4 | P2 | Modify a binary file and a text file together, then open all changes. Status has **two entries**, but the comparison projection contains **one file**. The binary's metadata disappears from the combined comparison. | `packages/zircon_git_ui/src/layout.zig:70` derives files exclusively from text hunks. `content.zig:89` displays raw metadata only when the entire patch has zero hunks. Retain file-level patch entries for binary, pure rename and mode-only changes, independently of text hunks. Show a noneditable metadata row beside normal editable files; preserve file controls and identity. The mixed binary case is reproduced; pure rename and mode-only cases follow the same inspected model and need acceptance tests. |

G1 affects the live source workflow, not merely a cosmetic filename. `services/git.zig:257` resolves the parsed path before opening the source. `views/git/diff_controls.zig:109` matches that same path against exact status entries. The existing synthetic parser fixture for spaces omits Git's delimiter tab, so it does not catch this failure.

G2 reproduces with a fresh app and one valid stash. It is independent of any prior diff or current source selection. A prior comparison may remain on screen because the rejected result does not replace it. That stale presentation is a source-derived consequence, while the preserved repro establishes the fresh-app blank case.

G3 is stale metadata, rather than a claim that all polling is broken. Status and ordinary diff refreshes still run. The current quiet refresh path compares status/diff data before notifying views. The failure is that it never invalidates cached metadata for this external change.

## Capability coverage

`Implemented` means code and exposed routing exist. `Partial` identifies a narrower workflow than Zed. `Missing` means no corresponding app command or repository operation was found in the inspected owners. Tests establish only their stated scenarios.

| Workflow | Zircon coverage at the baseline | Evidence and practical limit |
| --- | --- | --- |
| Repository discovery, status and file colors | Implemented, with unborn and detached HEAD handling, staged/unstaged flags, conflicts and net line counts. | `packages/zircon_git/src/root.zig:44`, `status.zig`, `numstat.zig`; `views/git/files.zig`, `views/components.zig`. Fresh package tests cover exact status paths, counts, untracked binary/symlink handling and partially staged counts. |
| External status/diff refresh | Implemented polling, with data equality checks and preserved scroll. Metadata is partial due to G3. | `shell.zig:712`, `services/git.zig:216`, `services/git.zig:656`. This pass makes no latency or overhead claims. |
| Whole-file stage/unstage and all-files operations | Implemented. Paths are passed as literal argv pathspecs; unborn unstage preserves bytes. | `packages/zircon_git/src/root.zig:228`, `services/git.zig:429`, `views/git/files.zig`, `views/git/diff_controls.zig:101`. Fresh package tests exercise actual index contents and hostile-looking pathspecs. |
| Unsaved changes and staging policy | Partial compared with Zed's save-before-stage paths. Live comparison includes dirty snapshots, but stage uses saved disk bytes. The file-header tooltip explicitly says so. | `services/git.zig:391`, `views/git/diff_controls.zig:129`, `root.zig:228`. Status rows/counts describe disk/index, so a dirty-only change need not have a staging target. Decide the intended save/stage policy and expose it consistently, rather than silently changing it. |
| Live working diff editing | Implemented for source/context/addition rows in unified and the current side of split view; source docs own bytes and history. | `git_editing.zig`, `services/git.zig:238`, `zircon_git_ui/sources.zig`. G1 breaks source activation for common filenames. Current selections and mutations remain within one displayed source excerpt. |
| Immutable comparisons | Implemented protection for historical, staged and stash views. Stash presentation is broken by G2. | `git_editing.zig:21`, `git_editing.zig:98`; repository `commitDiff`, `stashDiff`; existing source tests inspect generation/readonly paths. Zed's staged/history comparisons are also read-only, so this distinction is not itself a missing feature. |
| Source save and undo in diff | Implemented per source document. Save iterates dirty sources in the live projection. | `git_editing.zig:332`, shared editor/workspace transaction paths. Cross-file selections and one grouped undo transaction covering several source documents are missing. Source saving and staging remain separate. |
| Hunk copy and navigation | Implemented. Copy added/deleted lines strips prefixes and handles no-final-newline markers. | `views/git/diff_controls.zig:18`, `zircon_git_ui/hunks.zig:7`, `layout.zig`; existing Git UI tests cover copied bytes. No new copy defect was established. |
| Hunk/selection staging and unstaging | Missing. Available stage controls always target whole files. | `services/git.zig:20`, `root.zig:228`, `views/git/diff_controls.zig:101`. Zed has selection/hunk stage operations. This is a high-value next feature after the confirmed defects. |
| Restore/discard working changes | Missing native file/hunk controls. | The repository operation union and command catalogue contain stage/unstage but no worktree restore or hunk revert. Add distinct undoable source edits for hunk restore and an explicit destructive file-discard workflow with clear scope. |
| Diff find/replace and context expansion | Missing as diff workflows. Existing Find routes to buffer find and changes to the source editor panel. | `actions.zig:517`, `services/buffer_find.zig:32`; no diff-aware finder or expand-hidden-context operation in `git_editing.zig` or Git controls. |
| Completion/hover/navigation in diff | Partial editor reuse. Syntax and shared bytes work, but Git input does not call the normal editor's hover/completion path. | Compare `git_editing.zig:259` with `actions.zig:334`; completion and symbol hover are bound to ordinary active editor selection. The main editing audit owns detailed LSP correctness. |
| Conflict handling | Partial. Conflicts are grouped/colored and commit UI disables committing while conflicted. Manual editing remains possible. | `status.zig:40`, `models/git_tree.zig`, `views/git/commit.zig:35`. No Accept Current/Incoming/Both controls, conflict navigation, or merge/rebase continue/abort workflow. Zed exposes conflict resolution controls. |
| Commit | Basic staged commit implemented, with empty-message validation and real failure propagation. | `views/git/commit.zig`, `root.zig:254`. The input is a single-line `TextInput`; `controls/text_input.zig:278` rejects newline bytes. Expanded subject/body editing, amend, signoff and uncommit are missing. Existing failed-hook package test preserves worktree/index for retry. |
| History | Latest 100 repository commits, immutable diff tabs and commit body preview. | `services/git.zig:462`, `views/git/sidebar.zig:185`, `views/git/commit_details.zig:25`. No pagination, per-file history, branch comparison or graph UI. Body preview stops after four lines. G3 affects externally created commits. |
| Branches and tags | Create/switch local and track remote branches implemented. Branch rename/delete and tag management missing. | `views/git/picker.zig:63`, `commands.zig`, `root.zig:328`, `references.zig`. Linked Git worktree creation/switch/removal is missing. Opening an existing linked worktree directory is a different, narrower operation. |
| Stashes | All/tracked save, list, apply and pop implemented in the backend. View stash is broken. | `root.zig:336`, `views/git/picker.zig:38`; fresh package tests include conflicting apply/pop preserving the stash. Named/staged-only stash and drop controls are missing. |
| Fetch/pull/push | Implemented including remote picker, publish, pull rebase and force-with-lease. | `root.zig:303`, Git command/menu/picker owners. Fresh package suite uses a local bare remote. Public-remote auth, credential prompts and cancellation UX were not tested here. |
| Dirty-buffer protection during worktree mutation | Implemented conservative refusal if any file-backed tab is dirty before switch/stash/pull. | `services/git.zig:493`. Errors ask the user to save. No per-operation save selection/stash-dirty-buffer dialog. This is a policy difference, not an observed loss of edits. |
| Blame | Inline current-line blame with delayed request, hover/pinned details and SHA copy implemented; unsaved snapshot passed to Git. | `services/git.zig:782`, `editor_git.zig`, `root.zig:259`. Full gutter blame/history navigation and hosted file/selection permalinks are missing. |
| Remotes, advanced Git | Multiple existing remotes selectable. Remote add/edit/remove, submodule/LFS/sparse-checkout management and complex rebase/cherry-pick UI are outside current native coverage. | Repository operation surface and command/menu catalogue. Zed also retains terminal/task fallbacks for unsupported operations; this audit does not claim all advanced Git is native in Zed. |

## Evidence and reproduction

The app harness uses the actual portable app module graph, with `ui.App`, `Shell.bootstrap`, async jobs, normal commands, and real Git subprocesses against `std.testing.tmpDir` fixtures. It uses invisible portable windows, not AppKit. Its forced normal-refresh step moves the existing poll deadline and invokes `Shell.pollLanguage`; it does not replace or mock the Git worker. No user's repository is committed, staged, stashed or modified by these tests.

| Check run | Result | Preserved evidence |
| --- | --- | --- |
| `./tools/zig build test-git test-git_ui test-git-parsers --summary all` | Succeeded, **cached** test executions. Not counted as a fresh run. An earlier misspelled `test-git-ui` invocation failed before tests ran and was corrected. | Build summary observed in tool output. |
| `./tools/zig test --dep zircon_git -Mroot=packages/zircon_git/tests/all.zig -Mzircon_git=packages/zircon_git/src/root.zig` | **17/17 passed freshly**, including real branch/stash/local-remote, error/index, diff, counts and blame scenarios. | [Package log](git-evidence/existing-package-tests.log) |
| Real-patch path assertions | **2 failed, 1 passed.** Both space and newline source identities fail; the binary-only metadata observation passes. | [Harness](git-evidence/path-repros.zig), [log](git-evidence/path-repros.log) |
| Real-app workflow assertions | **4/4 failed** for G1, G2, G3 and G4, with no skipped tests. These are deliberately failing audit checks, not repaired regressions. | [Harness](git-evidence/app-repros.zig), [log](git-evidence/app-repros.log), [exact compiler command](git-evidence/executed-app-command.txt) |

Run from the repository root:

```sh
python3 docs/reviews/editor-workflow-audit-2026-11-08/git-evidence/run-app-repros.py
./tools/zig test --dep zircon_git -Mroot=docs/reviews/editor-workflow-audit-2026-11-08/git-evidence/path-repros.zig -Mzircon_git=packages/zircon_git/src/root.zig
```

Both commands are expected to exit nonzero at the audit baseline. The app runner first asks the normal build for its portable compile command and replaces only the test root and runner flags. This preserves the app's actual dependency/options configuration without editing the build graph. All fixture Git mutations remain in temporary directories. Compiler caches and the extension-host build may be updated by normal verification.

## Recommended order

1. Fix G1 and G2 and promote their audit repros to permanent behavior tests.
2. Fix G3/G4 so repository metadata and nontext changes stay represented reliably.
3. Add hunk/selection stage, unstage and restore. Make unsaved-buffer staging policy explicit in all staging entry points.
4. Add conflict resolution and a proper multiline commit editor.
5. Complete the common source-editor contract in diffs, including find, hover/completion, context expansion and consistent save/history behavior.
6. Extend history, branch/stash management and worktrees according to actual use, before optional advanced-Git UI.

## Verification limits

This pass does not establish native pointer geometry, foreground keyboard/IME behavior, installed-Zed behavior, external-network auth, large-repository scalability, concurrent external worktree mutation, or universal accessibility. Existing native verification belongs to the parent audit. I did not benchmark polling, diff or rendering. The two-agent audit uses inherited models, so independent slices do not provide model diversity.
