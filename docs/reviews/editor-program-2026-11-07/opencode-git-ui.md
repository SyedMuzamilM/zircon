# OpenCode Git UI review — Zed parity program

Reviewer: OpenCode Beam Free (review sub-agent seat). Review date: 2026-11-07. Scope: commits `c23490e` (grammar retry), `8ea2d7e` (storage-only recovery), `5700514` (Git UI/status/cursors/popovers), and `f5d9068` (screenshot-specific diff/notification acceptance), at HEAD `f5d9068`. No production or test source changes were made. No commits were made. Native builds and UI driving were not performed; portable tests and source inspection were used.

## Exact anchors

- `packages/zircon_git/src/numstat.zig` — NUL-delimited numstat parsing, rename/binary handling.
- `packages/zircon_git/src/status.zig` — porcelain v1 status, unborn/detached, rename/copy old paths.
- `packages/zircon_git/src/root.zig:78-135` — `Repository.status`, `statusCounts`, unborn empty-tree baseline, untracked `countNewFile`.
- `apps/zircon/src/services/git.zig` — refresh/result handoff, blame gating, stale-result rejection by generation.
- `apps/zircon/src/views/git_sidebar.zig` — badges, split actions, tree rows.
- `apps/zircon/src/views/git_controls.zig` and `apps/zircon/src/views/popovers/git_picker.zig` — anchored picker, mode switching, keyboard navigation.
- `apps/zircon/src/view.zig:179` — divider cursor and drag capture.
- `packages/zircon_ui/src/app/window.zig:311-327` — `updateCursor`, capture/pointer handling.
- `packages/zircon_ui/src/platform/macos/window.zig:214-223` — native `NSCursor` selector mapping.
- `apps/zircon/src/services/language.zig:370-470` — `pollSyntax`, `highlighted`, `syntaxFailed`, `clearSyntaxError`.
- Evidence: `docs/reviews/editor-program-2026-11-07/git-ui-evidence/README.md`, `recovery-storage-evidence/README.md`, `grammar-retry-evidence/README.md`.

## Method

1. Read program scope and evidence documents (`plan.md`, `progress.md`, `triage.md`, `git-diff-next.md`, `editor-todo.md`, evidence READMEs).
2. Inspected exact source for all audit targets; did not rely on reports alone.
3. Ran portable suites and package tests (commands/output below).
4. Performed manual Git command validation for unborn and rename numstat output.
5. Did not run native builds, native tests, benchmarks, browser/UI driving, or performance measurements.

## Executed checks

```text
$ ./.tools/zig-aarch64-macos-0.17.1/zig build test-app --summary all
Build Summary: 5/5 steps succeeded; 76/80 tests passed (4 skipped)
test-app success
+- run test 76 pass, 4 skip (80 total) 12s MaxRSS:359M
```

```text
$ ./.tools/zig-aarch64-macos-0.17.1/zig build test-git-parsers --summary all
Build Summary: 3/3 steps succeeded
test-git-parsers success
+- run test cached
```

```text
$ ./.tools/zig-aarch64-macos-0.17.1/zig build test-git --summary all
Build Summary: 3/3 steps succeeded; 16/16 tests passed
test-git success
```

```text
$ ./.tools/zig-aarch64-macos-0.17.1/zig build test-workspace --summary all
Build Summary: 3/3 steps succeeded; 21/21 tests passed
test-workspace success
```

```text
$ ./.tools/zig-aarch64-macos-0.17.1/zig build test-editor --summary all
Build Summary: 4/4 steps succeeded; 45/45 tests passed
test-editor success
```

Manual validation (executed, not source inference):

- Rename numstat output: `git diff --numstat -z --find-renames ...` emitted `1\t0\t\0old.txt\0new.txt\0`; parser’s empty-first-field rename branch maps the new path.
- Unborn repository: `git status --porcelain=v1 --branch -z` emitted `## No commits yet on main\0`; `git hash-object -t tree --stdin` emitted `4b825dc642cb6eb9a05e5e...`; diff against that empty tree produced tracked counts.

## Verified behavior (source plus executed tests)

### Git line statistics

- Tracked counts use `git diff --numstat -z --find-renames --no-ext-diff --no-textconv HEAD --` (or the unborn empty tree), so they are net HEAD-to-worktree counts including staged and unstaged changes. Partially staged files therefore show the combined net delta, not separate staged/unstaged deltas. This matches the documented intended semantics in `git-ui-evidence/README.md`.
- Unborn repositories use `git hash-object -t tree --stdin` as the baseline (`root.zig:94-99`), verified manually.
- Renames use `-z` numstat’s empty-path sentinel and consume `old_path` then `path` (`numstat.zig:14-21`); status parser records `old_path` (`status.zig:43`). Manual output confirms the mapping.
- Binary tracked files are detected by `-`/`-` and rendered as `Binary` (`numstat.zig:22`, `git_sidebar.zig:changeBadges`).
- Enrichment failures set all tracked stats to `null`, preserving the changed-file list and rendering `…` (`root.zig:80-86`, `git_sidebar.zig:changeBadges`).
- Untracked files are counted directly, capped at 64 MiB aggregate, with NUL binary detection in the first 8000 bytes and symlink target bytes (`root.zig:392-431`). Custom attributes/clean filters remain an explicit known limitation and are not treated as a regression.

### Cursor inheritance/capture/blur

- Divider nodes declare `.resize_horizontal`/`.resize_vertical` (`view.zig:179`).
- `updateCursor` walks parents and uses the first explicit cursor, so captured drags retain the resize cursor outside the divider (`window.zig:311-327`). On pointer up/leave/focus loss it returns to `.arrow`.
- Native mapping uses `resizeLeftRightCursor` and `resizeUpDownCursor` (`platform/macos/window.zig:219-220`).
- Portable plus native cursor assertions pass in `git_controls_tests.zig` for hover, capture, release, leave, and blur.

### Anchored branch/stash mode switching

- `switchMode` preserves the opener anchor by avoiding the global open command and resetting query, picker index, scroll, stash selection, and stash OID (`git_picker.zig:switchMode`).
- Branch and stash tabs use distinct query keys (`git-branch-query`, `git-stash-query`), restoring typing focus across mode changes.
- Keyboard navigation handles up/down/enter/escape, wraps within the filtered list, and invokes selection or branch creation (`git_picker.zig:input`).
- The placement test passes: repeated pointer switching keeps the popup bounds unchanged and typing remains focused.

### Split action hit targets

- `splitAction` creates one rounded surface with two independent buttons separated by a 1 px divider (`git_sidebar.zig:splitAction`).
- The portable test verifies contiguous hit targets at wide and narrow widths for both Stage All/Change actions and Publish/Remote actions.

### Grammar retry/reset/stale error ownership

- `SyntaxDocument` now tracks `attempts` and `retry_at`; `revision` is assigned only after successful installation (`language.zig:10-20`, `highlighted`).
- Retries are bounded to three attempts with backoff, then stop; a source revision change resets the budget (`pollSyntax`, `syntaxFailed`).
- Obsolete revision results call `pollSyntax` and return without clobbering status or retry state (`highlighted` revision mismatch path).
- Unrelated operation errors are preserved across successful grammar recovery because `clearSyntaxError` only clears syntax-origin status (`clearSyntaxError`, `Ops` test journey).
- Stale older-source failures cannot overwrite a newer unrelated operation error (tested by `journey("stale", true)`).
- Grammar retry tests pass: 6 tests in `grammar_retry_tests.zig` are included in the 76/80 portable result.

## Findings

### F1 — Grammar callback error paths can leave `pending` set (medium, source inference)

- Location: `apps/zircon/src/services/language.zig:389-401` (`highlighted`).
- Trigger: a highlight result whose host callback fails before `tracked.pending = false` is reached, specifically the `raw catch` path at lines 390-394, the generation/index guard at line 396, or the workspace lookup failure at line 401.
- Impact: `pending` remains true for that document, so `pollSyntax` skips it and highlighting can remain stale until the document revision changes. This is the same class of wedging defect previously reported as F1 in `opencode-corrections.md`, but applied to the new retry code’s less common failure paths.
- Evidence status: source inference only; no portable test exercises these paths. The retry tests cover worker failure, invalid JSON, invalid spans, persistent failure, and stale revision, but not callback/raw errors or workspace lookup failure.
- Smallest corrective direction: clear `tracked.pending = false` in each early return where the tracked identity is known; for the raw-error path, resolve the tracked document by `result.stamp.index` only when it is in range and matches, otherwise leave retry scheduling to the next revision.
- Acceptance check: inject a failing host result and a workspace lookup failure for an unchanged revision and assert the document still gets a later successful grammar installation within the bounded retry budget.

### F2 — Grammar failure can replace a newer unrelated status error (low/medium, source inference)

- Location: `apps/zircon/src/services/language.zig:syntaxFailed` (`try self.setStatus(...)` followed by `self.status_origin = .{ .syntax = tracked.id }`).
- Trigger: a grammar job starts, then a newer unrelated operation sets a general status error; when the older grammar job later fails for the current revision, `syntaxFailed` overwrites the status text and changes origin to syntax.
- Impact: the newer unrelated error disappears from the status bar even though it was set after the grammar job began. The existing stale-revision test prevents obsolete revision failures from doing this, but there is no time-ordering guard for current-revision failures.
- Evidence status: source inference plus test gap. `grammar_retry_tests.zig` covers unrelated-error preservation across recovery and stale revision, but not this ordering.
- Smallest corrective direction: record a status generation/sequence or compare status origin before replacing a general error; alternatively, make grammar failures append rather than replace when `status_origin == .general` and `status_is_error`.
- Acceptance check: set an unrelated error after a grammar job has started, force the grammar job to fail for the current revision, and assert the unrelated error remains visible.

### F3 — Net-zero tracked file shows `+0` badge (low, source inference)

- Location: `apps/zircon/src/views/git_sidebar.zig:changeBadges` (`if (stats.added > 0 or stats.deleted == 0)`).
- Trigger: a tracked file whose staged and unstaged changes cancel out (for example staged deletion plus worktree re-addition), so both net counts are zero.
- Impact: the badge row renders `+0` instead of no count or an explicit unchanged marker. This is cosmetic and does not affect data, but it can misread as a change.
- Evidence status: source inference only; the count test checks `+1`/`−1` and `Binary`, not zero.
- Smallest corrective direction: render `+0` only when there is a known change context, or omit both badges when `added == 0 and deleted == 0`, optionally showing a neutral marker.
- Acceptance check: add a fixture with canceling staged/unstaged edits and assert the expected badge set.

### F4 — Raw host callback failure path does not clear pending (same root as F1)

- Location: `apps/zircon/src/services/language.zig:390-394`.
- Notes: listed separately because it is the most likely trigger of F1 and the natural place to patch. The fix should be made there first.

## Non-findings / verified intended limitations

- Untracked count custom attributes and clean filters remain a documented limitation (`git-ui-evidence/README.md`); not reported as a regression.
- Storage-only recovery (`8ea2d7e`) is intentionally not app-integrated; 21/21 workspace tests pass, but forced-termination restore remains pending per `recovery-storage-evidence/README.md`.
- No editable diff buffer, shared diff layout, breadcrumb toolbar, animated recommendations, or persistent parser workers are claimed implemented; they remain in `git-diff-next.md`.
- No performance or Zed timing ranking is claimed.

## Residual scope

- Native cursor, anchored picker, and split-action tests passed in the portable suite but native-only assertions (NSCursor instance, native window event routing) were not rerun in this review; the native mutation log remains the recorded evidence.
- Grammar callback/raw and time-ordering ownership gaps (F1, F2) are not covered by existing tests.
- Recovery app integration and SIGKILL/restart proof remain open.
- Editable diff buffers and persistent grammar workers remain the next distinct units.

## Acceptance verdict

The scoped Git UI, cursor, anchored picker, split-action, and grammar retry changes are acceptable as a correction slice: the relevant portable suites pass (`76/80` with four explicit skips, plus `16/16` Git, `21/21` workspace, `45/45` editor tests), manual Git validation confirms unborn and rename counting, and mutation evidence shows the tests catch the targeted regressions. Two grammar ownership gaps (F1, F2) and one cosmetic badge gap (F3) remain actionable before claiming robustness. No full parity score is awarded, and recovery app integration, editable diffs, and persistent parser ownership remain outside this slice.
## Parent follow-up

All three findings were fixed locally before the diff projection slice. Transport errors now clear pending grammar jobs and schedule bounded retry; syntax errors preserve a newer general status error; net-zero files omit `+0`. The clean portable result is77 passes with four explicit skips.
