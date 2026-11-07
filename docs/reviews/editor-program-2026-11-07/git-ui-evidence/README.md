# Git UI correction evidence

The parent compared the earlier clean Zed Git captures from the same installed binary with the current native app and the user's November 7 screenshots. The eight retained 1240 × 820 client-area captures show light/dark Git, Branches, Stashes and returning to Branches. They are produced by the real native capture driver. OS-managed title buttons are outside this client-area capture. No fresh automated Zed workflow or exact full-screen pixel equivalence is claimed.

Changed behavior:

- Sidebar and pane dividers declare inherited resize cursors. Captured drags retain the correct cursor outside the divider; release, leave and focus loss reconcile it. Native checks assert the actual NSCursor instance through the surface adapter.
- Stage All and Publish/Push share rounded surfaces with their dropdown arrows, while preserving independent accessible actions.
- Changed files display rounded green addition and red deletion counts. Tracked counts come from aggregate Git numstat against HEAD, including staged and unstaged net changes. Unborn repositories use the empty tree. Binary files show Binary; unavailable counts show an ellipsis. Untracked reads are capped at 64 MiB per refresh and use NUL detection plus symlink target bytes. Untracked custom attributes/clean filters remain a limitation. Enrichment errors preserve the changed-file list.
- Branches/Stashes are segmented tabs. Their dedicated mode-switch handler preserves the opener anchor and current reference results. Distinct query identities restore typing focus when changing mode.
- Language picker, recent projects, service status, editor options and Git picker now live in cohesive popover modules. Shared framing handles query layout and placement; the workspace dispatcher retains its public entrypoints.

`portable.txt`: 76 passed, four explicit native-only skips, 80 total. `native.txt`: 105/105 passed through the sequential native/window/renderer/editor/settings/rendering chain. The three new UI journeys cover repeated pointer switching with typing, native cursor mapping/capture, and real Git file-count badges/joined controls at wide/narrow widths. `git-package.txt`: 24 package checks passed. `release.txt`: 42/42 build steps, 271 tests passed and four native-only skips. These suites overlap and are not unique-test totals.

The cursor mutation removes divider cursor metadata and fails the expected horizontal-resize assertion. The anchor mutation restores reanchoring from internal tab bounds and moves the popup from y=32 to y=76, failing placement. The first native cursor mutation attempt was inconclusive because an earlier standalone native text-dispatch test failed before the target ran. That log is preserved separately. The subsequent portable mutation isolates the intended failure; clean native chains passed afterward. No production mutation remains.

The requested editable diff buffer, richer headers/collapse/split/hunk toolbar, file breadcrumbs, animated extension recommendations and persistent syntax workers remain the next distinct units, specified in `../git-diff-next.md`. They are not claimed implemented by this correction.

The final release correctness matrix passed8/8 configurations with160 inputs and actual current Git/LSP/grammar results. See `../../../benchmarks/editor-2026-11-07-git-ui-smoke/`. This single-run smoke does not establish a performance improvement or comparative ranking.
