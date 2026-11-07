# Zircon Editor Corrections Review: Autonomous Program 2026-11-07

- **Review Sub-Agent**: Antigravity (`gemini-3.8-flash-high`)
- **Repository / Workspace**: `/Users/syedmuzamilm/work/expirements/zigpui`
- **Committed HEAD Reviewed**: [`6acd1cf7cb98bff84259f1f8e5a85a3e5a7fe976`](file:///Users/syedmuzamilm/work/expirements/zigpui) (`chore(evidence): preserve raw lifecycle test output`)
- **Key Earlier Commits Inspected**:
  - [`0b73351b9e27d9dda4c3e4eeda1cd774802c24d9`](file:///Users/syedmuzamilm/work/expirements/zigpui) (`fix(runtime): isolate concurrent Darwin child process handles`)
  - [`1f8f99eb8c5814b7855d2c520162f6dba758ec4b`](file:///Users/syedmuzamilm/work/expirements/zigpui) (`fix(extensions): serialize resolver writes to shared install directories`)
  - [`e08fdc52613f884d00a730a0d763f85ab8c3d6a6`](file:///Users/syedmuzamilm/work/expirements/zigpui) (`fix(language): isolate document language rebindings and stale results`)
  - [`17e0fd181193dffb6bf4a21f5daa82fd501b65e9`](file:///Users/syedmuzamilm/work/expirements/zigpui) (`test(editor): require current Git gutter results in baseline readiness`)
  - [`05148b885650ad3be52977d234f54905854163de`](file:///Users/syedmuzamilm/work/expirements/zigpui) (`docs(editor): record lifecycle acceptance and next recovery design`)
- **Working Tree Exclusions**: The four dirty framework documentation paths (`README.md`, `packages/zircon_ui/README.md`, `docs/zircon-ui.md`, `docs/zircon-ui-usage.md`) represent another thread's preserved work; they were not touched or reviewed as part of this correction patch.
- **Reference Targets**:
  - Installed reference executable: Zed Preview 1.28.0 (build `20261104.153513`), SHA-256 `cd4b698951d19995b4d12b7b0cfc1b4dbb1ec2dc7196e75689e48434cb9ef637`.
  - Local Zed GPUI reference checkout: `/tmp/zed-gpui-grok` at commit `ead5672e169f4d4ec0a6a88ebac18e00a37bf81b`.
- **Verdict**:
  - **Correction Scope**: **PASS** (Darwin process isolation, resolver directory lock, document-scoped language rebinding, and benchmark harness readiness assertions are verified and reproducible).
  - **Full Product Parity**: **ISSUES** (Substantial architectural gaps remain: durable session recovery, multi-tree pane docks, incremental LSP synchronization, file system watchers, and advanced Vim/language capabilities remain unverified or unimplemented).

---

## 1. Review Method, Scope & Constraints

### 1.1 Method & Operational Limitations
- **Read-Only Inspection**: Conforming strictly to instructions, no subagents were launched, no local git commits or code modifications were made, and no background build tasks, native UI tests, benchmarks, or desktop driving were initiated.
- **Assigned Output Only**: Only this assigned report file ([`docs/reviews/editor-program-2026-11-07/antigravity-corrections.md`](file:///Users/syedmuzamilm/work/expirements/zigpui/docs/reviews/editor-program-2026-11-07/antigravity-corrections.md)) is written.
- **Security Sandbox Limitation**: Attempts to access external skill references at `/Users/syedmuzamilm/.codex/skills/pstack/references/t3-runtime.md` and `/Users/syedmuzamilm/.codex/pstack-models.md` were denied by platform boundary controls. All runtime, model, and workflow evaluations rely exclusively on repository-local sources ([`plan.md`](file:///Users/syedmuzamilm/work/expirements/zigpui/docs/reviews/editor-program-2026-11-07/plan.md), [`progress.md`](file:///Users/syedmuzamilm/work/expirements/zigpui/docs/reviews/editor-program-2026-11-07/progress.md), [`triage.md`](file:///Users/syedmuzamilm/work/expirements/zigpui/docs/reviews/editor-program-2026-11-07/triage.md), [`process-isolation-review.md`](file:///Users/syedmuzamilm/work/expirements/zigpui/docs/reviews/editor-program-2026-11-07/process-isolation-review.md), [`language-lifecycle-design.md`](file:///Users/syedmuzamilm/work/expirements/zigpui/docs/reviews/editor-program-2026-11-07/language-lifecycle-design.md), [`recovery-design.md`](file:///Users/syedmuzamilm/work/expirements/zigpui/docs/reviews/editor-program-2026-11-07/recovery-design.md), [`decisions.tsv`](file:///Users/syedmuzamilm/work/expirements/zigpui/docs/reviews/editor-program-2026-11-07/decisions.tsv)).
- **Inspection Order**: All commit diffs (`0b73351`, `1f8f99e`, `e08fdc5`, `17e0fd1`, `05148b8`, `6acd1cf`) and primary source implementations were audited directly *prior* to evaluating prior review reports (`antigravity-initial.md`, `opencode-initial.md`) and triage notes.

### 1.2 Evidence Integrity Check
- **Reference Capture Quality**: As documented in [`reference-inspection.md`](file:///Users/syedmuzamilm/work/expirements/zigpui/docs/reviews/editor-program-2026-11-07/reference-inspection.md), the screenshot `zed-light-trust-dialog.png` is **inconclusive and rejected** as clean-editor reference evidence. The client area is blocked by an active modal security prompt ("Do you trust the authors of the files in this window?"), and AX API automation was unable to interact with or dismiss the modal. Clean comparison relies strictly on prior un-obscured captures and native client-area bounds.
- **Current UI Captures**: The 28 PNG captures in [`current-ui/`](file:///Users/syedmuzamilm/work/expirements/zigpui/docs/reviews/editor-program-2026-11-07/current-ui) represent the native AppKit client area (`MTKView`), legitimately omitting OS-managed window buttons (traffic lights). They confirm pixel-level layout of command palettes, font pickers, Git diff/staging views, split panes, and Markdown previews under dark and light themes, but do not establish dynamic interactive latency or OS-level IME composition behavior.

---

## 2. Audit of Primary Correction Scope

### 2.1 Darwin Child Process-Handle Isolation ([`0b73351`](file:///Users/syedmuzamilm/work/expirements/zigpui))
- **Problem Proven**: Zig 0.17.1's standard library implementation on Darwin (`std/Io/Threaded.zig:spawnDarwin`) creates pipes via `pipe()` and subsequently marks them close-on-exec with `fcntl(F_SETFD, FD_CLOEXEC)`. A concurrent spawn on another thread between those two syscalls inherited unrelated pipe ends. This manifested as the Python LSP process inheriting the grammar worker's stdin writer pipe, blocking the worker indefinitely on `read()` even after the parent closed its writer.
- **Implementation Mechanism**:
  - [`tools/zig_stdlib_overlay.py`](file:///Users/syedmuzamilm/work/expirements/zigpui/tools/zig_stdlib_overlay.py) prepares an isolated, fingerprint-verified copy of the Zig 0.17.1 standard library in `.tools/zig-stdlib-overlay/<digest>/` under an exclusive file lock (`prepare.lock`) and atomic directory rename.
  - Injects `.CLOEXEC_DEFAULT = true` into Darwin's `posix_spawnattr_setflags`, making handle inheritance strictly opt-in. Declared stdin, stdout, stderr, and explicit handles (`inherit_files`) continue to be preserved via explicit `posix_spawn_file_actions_adddup2` and `posix_spawn_file_actions_addinherit_np`.
  - [`tools/zig`](file:///Users/syedmuzamilm/work/expirements/zigpui/tools/zig) wraps compiler commands on Darwin, automatically passing `--zig-lib` or `--zig-lib-dir`, while rejecting conflicting `--zig-lib` arguments before `--` and preserving arguments passed after `--`.
- **Regressions & Evidence**:
  - [`tools/verify_spawn_isolation.zig`](file:///Users/syedmuzamilm/work/expirements/zigpui/tools/verify_spawn_isolation.zig): Deterministic regression opens non-cloexec pipes at descriptors 128 and 129, spawns a probe child, and verifies neither descriptor leaks into the child, while an explicitly declared inherited handle survives. Confirmed red before the overlay and green after.
  - [`tools/test_zig_stdlib_overlay.py`](file:///Users/syedmuzamilm/work/expirements/zigpui/tools/test_zig_stdlib_overlay.py): 4 unit tests verify cache reuse, non-spawn source updates creating new hashes, detection/rejection of corrupted cached overlays, and rejection of changed spawn implementations.
- **Architectural Boundary**: Covers `std.process.spawn` and `std.process.run`. As documented, it does *not* cover the terminal subsystem's raw `fork`/`execve` path ([`apps/zircon/src/terminal.zig`](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/src/terminal.zig)), nor does it apply to Linux-hosted cross-compilation targeting macOS.

### 2.2 Extension Host Resolver Locking ([`1f8f99e`](file:///Users/syedmuzamilm/work/expirements/zigpui))
- **Problem Proven**: When multiple documents with different scopes or concurrent language configurations resolve language servers simultaneously, parallel worker processes could concurrently write to the same `.work/<server_id>` installation cache, risking torn binaries or corrupt index files.
- **Implementation**:
  - Added [`lock_work_directory(work: &Path)`](file:///Users/syedmuzamilm/work/expirements/zigpui/tools/zed-extension-host/src/process.rs#L12) in `tools/zed-extension-host/src/process.rs`.
  - Creates `.zircon-resolve.lock` inside the specific server's work directory and acquires an exclusive advisory file lock (`File::lock()`, supported on Rust 1.89+).
  - The owned `File` handle is returned and held for the duration of the resolve operation (`_work_lock` in `languages.rs:183` and `runtime.rs:518`), guaranteeing automatic release on normal return, error unwind, or process exit.
  - Built-in binary overrides (configured without install requirements) bypass the lock, avoiding unnecessary filesystem serialization.
- **Evidence**:
  - `resolver_installation_has_one_writer_per_directory` test in `process.rs:25` asserts that a second concurrent `try_lock()` returns `WouldBlock`, while an unrelated server directory locks independently.
  - Release test suite passes 5/5 tests in 0.09s ([`language-evidence/resolver-lock-release.txt`](file:///Users/syedmuzamilm/work/expirements/zigpui/docs/reviews/editor-program-2026-11-07/language-evidence/resolver-lock-release.txt)).

### 2.3 Document-Scoped Language Lifecycle & Stale Result Rejection ([`e08fdc5`](file:///Users/syedmuzamilm/work/expirements/zigpui))
- **Problem Proven**: Previously, changing a document's language via the picker invoked `self.language.deinit()`, which destructively destroyed all active LSP client connections across all open documents. Furthermore, late diagnostics or highlights from an earlier language mode could be delivered at the same document revision, poisoning the new language view.
- **Implementation**:
  - **Scoped Invalidation** ([`language.zig:invalidateDocument`](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/src/services/language.zig#L102)): Clears pending completions, increments `tracked.epoch` for the target document, marks `tracked.scoped = true`, resets `revision`, `observed`, and `pending`, and closes only documents matching the target `DocumentId`.
  - **Non-Destructive Session Scope**: `sessionFor` tracks `scope: ?ws.DocumentId`. A manually rebound document receives its own scoped server session without disrupting other open documents.
  - **Epoch Guarding on Asynchronous Callbacks**:
    - `resolved`: Verifies `!session.retired && session.epoch == result.stamp.epoch` before assigning client.
    - `highlighted`: Verifies `std.meta.eql(tracked.id, document) && tracked.epoch == result.stamp.epoch` before installing highlights. Late results from obsolete language requests are silently dropped.
  - **Slot Reuse & UI Visibility**:
    - Retired sessions are retained in `sessions` to preserve stable index references for in-flight tasks, and are reused on subsequent spawns with an incremented epoch.
    - Status reporting in [`chrome.zig:127`](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/src/views/chrome.zig#L127) (`activeSessions()`), [`workspace_controls.zig:141`](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/src/views/workspace_controls.zig#L141), and [`extensions.zig:56`](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/src/views/extensions.zig#L56) explicitly skips `session.retired`, preventing zombie or starting indicators from overwriting active service status.
  - **Saved & Live Secondary State Invalidation** ([`workspace_controls.zig:51-60`](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/src/views/workspace_controls.zig#L51-L60)): When rebinding language on a document that is split or stashed in `tab.secondary_state`, `applyLanguage` is invoked on both the primary editor, the live secondary pane editor, and `tab.secondary_state`, clearing syntax caches and resetting `grammar_revision = null`.

### 2.4 Baseline Benchmark Readiness Hardening ([`17e0fd1`](file:///Users/syedmuzamilm/work/expirements/zigpui))
- **Harness Enforcement**: [`tools/bench_editor.zig:53,62`](file:///Users/syedmuzamilm/work/expirements/zigpui/tools/bench_editor.zig#L53) was updated to explicitly require:
  1. `!self.git.needs_refresh && self.git.repository`
  2. `tab.editor.git_revision == record.doc.revision()`
  3. `tab.editor.grammar_revision.? == record.doc.revision()`
- **Outcome**: Ensures that benchmark runs measure real end-to-end delivery of Git gutter diffs and Tree-sitter grammar spans rather than measuring prematurely settled buffers. Complete repeated matrix (`docs/benchmarks/editor-2026-11-07-lifecycle-current-git`) completed **40/40 passed** across 800 input events with zero failures.

---

## 3. Audit of `decisions.tsv` & Attention Flags

All 22 entries in [`decisions.tsv`](file:///Users/syedmuzamilm/work/expirements/zigpui/docs/reviews/editor-program-2026-11-07/decisions.tsv) were audited against committed code, logs, and artifacts:

| # | Timestamp | Phase | Logged Decision | Artifact Cited | Verification Finding |
|---|---|---|---|---|---|
| 1 | 04:19:15 | frame | Scope scores; avoid 10/10 parity claims | `docs/editor-todo.md` | **PASS**: 88-task inventory sets objective acceptance. |
| 2 | 04:19:15 | rendering | Commit wrapping/gutter fixes | `bad2152` | **PASS**: Diff inspectable; 45 editor / 92 native checks passed. |
| 3 | 04:21:47 | reference | Reject trust-obscured capture | `reference-inspection.md` | **PASS**: Documented modal dialog obstruction confirmed. |
| 4 | 04:38:58 | review | Reject false secondary-tab omission claims | `triage.md` | **PASS**: Source inspection confirms secondary tabs remain in `tabs.items`. |
| 5 | 04:38:58 | diagnosis | Trace grammar timeout to pipe inheritance | `10-family-pipes.txt` | **PASS**: Verified live file descriptors and Python LSP leak. |
| 6 | 04:38:58 | design | Use Darwin overlay with `CLOEXEC_DEFAULT` | `verify_spawn_isolation.zig` | **PASS**: Deterministic probe red before / green after. |
| 7 | 04:44:28 | baseline | Retain new complete 40-case baseline | `verification.json` | **PASS**: 40/40 passed; historical 34/40 retained. |
| 8 | 04:46:23 | runtime | Commit child descriptor isolation | `0b73351` | **PASS**: Clean commit with documentation. |
| 9 | 04:49:47 | integration | Commit terminal/workspace controls | `dc56004` | **PASS**: Integrates terminal and two-pane management. |
| 10 | 04:49:47 | capture | Capture current dark/light UI scenarios | `current-ui/manifest.json` | **PASS**: 28 native PNG images verified. |
| 11 | 04:51:00 | verification | Commit reproducible native/bench tooling | `33ee79c` | **PASS**: Native test harness and driver commits verified. |
| 12 | 04:56:10 | tooling | Cache integrity regressions / preserve `--` | `test_zig_stdlib_overlay.py` | **PASS**: 4 cache tests pass; command flags preserved. |
| 13 | 05:03:19 | verification | Retain mixed mutation result & rerun clean | `epoch-mutation.txt` | **ATTENTION FLAG**: Documented below. |
| 14 | 05:15:12 | verification | Share journey registration in `journeys.zig` | `journeys.zig` | **PASS**: Common suite registered for portable and native test roots. |
| 15 | 05:15:12 | review | Fix retired-session status in Extensions | `retired-status-before.txt` | **PASS**: Red-then-green proof verified. |
| 16 | 05:15:12 | resolver | Lock shared install directories | `resolver-lock-release.txt` | **PASS**: 5 release worker tests pass. |
| 17 | 05:20:52 | harness | Reject freshness smoke from failed build | `git-freshness-compile-failure.txt` | **ATTENTION FLAG**: Documented below. |
| 18 | 05:22:23 | language | Commit document-scoped lifecycle | `e08fdc5` | **PASS**: Native (95/96) and clangd (93/94) passed. |
| 19 | 05:22:23 | resolver | Commit resolver directory lock | `1f8f99e` | **PASS**: Locking implementation verified in source. |
| 20 | 05:23:49 | harness | Require Git gutter revision matching | `tools/bench_editor.zig` | **PASS**: Driver checks `git_revision == doc.revision()`. |
| 21 | 05:27:19 | baseline | Accept complete 40/40 current Git matrix | `verification.json` | **PASS**: 40/40 attempts and 800 inputs verified. |
| 22 | 05:30:37 | handoff | Request fresh review before recovery slice | `progress.md` | **PASS**: Decision records align with state. |

### Attention Flags & Weak Evidence Points:
1. **Mutation Run Conclusiveness (Row 13)**:
   In [`language-evidence/epoch-mutation.txt`](file:///Users/syedmuzamilm/work/expirements/zigpui/docs/reviews/editor-program-2026-11-07/language-evidence/epoch-mutation.txt), removing epoch guards successfully failed the two target assertions (`GrammarOps.pending` and `ResolverOps.pending`), confirming the guards are active. However, the subsequent 11 tests crashed with `NoSpaceLeft` on `tmpDir` creation due to scratch-space disk exhaustion. While the two specific guards are proven necessary, the run was inconclusive as a full-suite mutation test. The decision log accurately acknowledged this nuance rather than claiming a clean mutation pass.
2. **Harness Fail-Fast Gap on Driver Compile Failure (Row 17)**:
   In [`language-evidence/git-freshness-compile-failure.txt`](file:///Users/syedmuzamilm/work/expirements/zigpui/docs/reviews/editor-program-2026-11-07/language-evidence/git-freshness-compile-failure.txt), when `bench_editor.zig` had a type error (`u64` compared to `null`), the benchmark runner proceeded to execute the old pre-existing binary rather than aborting. The operator correctly rejected this invalid smoke run and moved it to a temporary directory before fixing the type error. A production test runner should strictly abort on compilation failure.
3. **Foreground-Activation Skip in Native Chains (Row 18)**:
   Both the native rendering chain (95 passed, 1 skip / 96 total) and the real-clangd chain (93 passed, 1 skip / 94 total) contain 1 skipped test in the native window suite (`test 8 pass, 1 skip`). This skip is caused by macOS AppKit headless focus limitations (`canBecomeKeyWindow` in non-interactive sessions). Full OS foreground window activation and native menu bar integration remain unverified in headless automated runs.
4. **Shared Application Chains (Rows 14 & 18)**:
   The 59 application tests in `test-editor-rendering-native` and `test-language-real` are identical shared tests registered through `journeys.zig`. They must not be aggregated or counted as 118 distinct test cases.

---

## 4. Evaluation of Recovery Design ([`recovery-design.md`](file:///Users/syedmuzamilm/work/expirements/zigpui/docs/reviews/editor-program-2026-11-07/recovery-design.md))

### 4.1 Alignment with Current Zircon Semantics
`recovery-design.md` proposes Candidate A (immutable versioned document checkpoints with an atomic session index) as the design direction for `TEXT-05`. Evaluating this against Zircon's actual codebase reveals critical design constraints:

1. **`DiskStamp` Preservation on Restore**:
   - In [`packages/zircon_workspace/src/persistence.zig:56`](file:///Users/syedmuzamilm/work/expirements/zigpui/packages/zircon_workspace/src/persistence.zig#L56), `save()` enforces optimistic concurrency: `if (expected) |old| { if (actual == null || !old.eql(actual.?)) return error.DiskConflict; } else if (actual != null) return error.PathAlreadyExists;`.
   - **Flaw in naive restore**: If recovery restores a document buffer without its original `DiskStamp`, saving will fail with `error.PathAlreadyExists` because `expected` is null while the file exists on disk.
   - **Requirement**: Checkpoint metadata MUST record the original `DiskStamp` (`inode`, `size`, `modified`, `permissions`, `digest`). Upon recovery, the `Workspace.Record.disk` field must be restored with this baseline stamp. If external edits occurred while Zircon was crashed, the subsequent save will legitimately detect `DiskConflict` and prompt for Save As / Overwrite.
2. **`saved_state` Rope Identity vs Monotonic Revision**:
   - In [`packages/zircon_workspace/src/root.zig:24`](file:///Users/syedmuzamilm/work/expirements/zigpui/packages/zircon_workspace/src/root.zig#L24), `dirty()` is defined as: `if (record.saved_state) |saved| saved != record.doc.stateId() else true`.
   - In Zircon's immutable rope (`zircon_text`), `stateId()` identifies the exact root tree node. If a user edits and then presses `Undo` back to the clean baseline, `stateId()` matches `saved_state`, returning `dirty() == false`, even though `doc.revision()` has incremented.
   - **Requirement**: Recovery checkpoints must not rely on revision numbers alone to determine dirtiness; they must record `state_id`, `saved_state`, and the dirty flag.
3. **Window-Level Discard Invalidation Race**:
   - In [`apps/zircon/src/actions.zig:768`](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/src/actions.zig#L768), when the dirty prompt handles `.discard_dirty` for `.window`, it executes: `self.allow_close = true; try cx.app.requestCloseWindow(self.window.?);`.
   - It does *not* close tabs individually or invoke `close(..., .discard)`.
   - **Critical Design Flaw**: If the session checkpoint directory is left intact on disk when the window closes after an explicit "Don't Save" choice, the next editor launch would discover the unsaved checkpoints and resurrect discarded work!
   - **Requirement**: The `.discard_dirty` handler for `.window` must write an atomic session discard marker (or delete the session directory) *before* issuing `requestCloseWindow`.
4. **Pane Split & Secondary State Restoration**:
   - In Zircon's two-group pane architecture, tabs can be primary, secondary, or both. Inactive secondary tabs stash their editor in `tab.secondary_state` ([`panes.zig`](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/src/panes.zig)), while the active secondary tab resides in `self.secondary.?.editor`.
   - Recovery must serialize pane layout (`active_pane`, `self.active`, `split` ratio), `tab.primary`, `tab.secondary`, and `tab.secondary_state` (scroll offset, selection cursor, and language override) to reconstruct exact multi-pane views.

### 4.2 Small First Implementation Slice with Forced-SIGKILL Proof
To deliver `TEXT-05` cleanly without sprawling into an unbounded database engine:
1. **Directory Structure**:
   `$APP_DATA/sessions/<workspace_hash>/`:
   - `checkpoints/<doc_uuid>.raw` (UTF-8 bytes)
   - `checkpoints/<doc_uuid>.meta.json` (`{ path, untitled_name, state_id, saved_state, disk_stamp, cursor, scroll, language_path }`)
   - `session.json.tmp` -> atomically renamed to `session.json` (`{ tabs: [...], active_pane: "primary", active_index: 0, secondary_index: 1 }`)
2. **Debounced Checkpoint Pipeline**:
   - UI thread captures read-only `doc.snapshot()` and metadata upon edit (debounced at 500 ms).
   - Writes checkpoint files, syncs directory, and atomically replaces `session.json`.
3. **Adversarial Subprocess Acceptance Test (`SIGKILL` Proof)**:
   - A dedicated test binary (`test_recovery_sigkill.zig`):
     1. Launches `zircon` in a headless child process with an untitled buffer and an existing file.
     2. Dispatches key inputs modifying both buffers.
     3. Awaits the checkpoint marker on disk.
     4. Sends `SIGKILL` (`kill -9`) to the child process, bypassing all application destructors and cleanup code.
     5. Relaunches `zircon` with the same workspace root.
     6. Asserts both buffers are restored with exact modified text, dirty status preserved, cursor positions restored, and original disk file untampered.
     7. Asserts that external disk modification between kill and relaunch triggers `DiskConflict` upon subsequent save attempt.

---

## 5. Independent Evaluation Across 10 Plan Dimensions

Each dimension is scored strictly against parity with installed Zed Preview 1.28.0 (build `20261104.153513`). Lacking verified automated proof results in **UNVERIFIED**. Desired 10/10 scores are rejected.

| Plan Dimension | Score / Status | Concrete Rationale & Evidence |
|---|---|---|
| **1. UI / Workflow Fidelity** | **5 / 10** | Two-group pane splits (`primary` / `secondary`), tab drag-and-drop, command palette, and dark/light themes render natively (verified in 28 `current-ui` captures). However, arbitrary dock layouts (`WORK-01`), draggable panel docks (left/right/bottom), breadcrumbs, and floating modals are absent compared to Zed. |
| **2. Correctness & Data Safety** | **7 / 10** | Atomic file replacement with `DiskStamp` verification is robust. `0b73351` eliminates concurrent child pipe leaks. `1f8f99e` serializes resolver directory writes. `e08fdc5` prevents cross-document language rebind contamination. However, durable crash recovery (`TEXT-05`) is currently unimplemented, and terminal teardown uses ungraceful raw `SIGKILL`. |
| **3. Text / IME / Unicode** | **6 / 10** | Persistent rope text buffer (`zircon_text`) and line/column conversions are reliable. Soft-wrap continuations preserve source indentation (`bad2152`). However, multi-codepoint grapheme cluster boundaries and complex bidirectional/accented shaping are only partially handled, and native IME composition has automated test activation skips. |
| **4. Performance & Memory** | **5 / 10** | Baseline `BASE-03` completed 40/40 release cases across 800 inputs with verified Git/Tree-sitter/LSP work. However, no performance speedup or Zed parity ranking is claimed: LSP synchronization transmits full buffer payloads (16 MiB queue cap), indentation folding re-scans buffers on the UI thread, and wrap cache rebuilds entire buffers on edit. |
| **5. Settings, Fonts & Themes** | **6 / 10** | JSON settings store with atomic write/reload is functional. Font picker and theme picker popups work (`zircon-dark-font-picker.png`, `zircon-dark-theme-picker.png`). However, syntax token highlights are flattened to 7 base categories rather than Zed's granular Tree-sitter scope palette, and font shaping metrics across arbitrary system fallback fonts lack automated coverage. |
| **6. Extensions & Language Support** | **5 / 10** | Stdio LSP client supports `didOpen`, `didChange`, and `completion`. Tree-sitter grammar highlighting executes via native extension host. Document-scoped rebinding and epoch isolation prevent stale diagnostic cross-talk (`e08fdc5`). However, core IDE capabilities (Definition, References, Rename, Hover, Code Actions, Formatting, Diagnostics panel) remain completely unimplemented (`LANG-04`–`LANG-07`). |
| **7. Vim & Keybindings** | **4 / 10** | Normal, Insert, Visual, VisualLine, VisualBlock, basic motions (`w`, `b`, `0`, `$`), operators (`d`, `c`, `y`, `p`), search (`/`), and dot repeat are implemented. However, named registers, macros (`q`), marks (`m`), Ex command line (`:`), text objects (`ciw`, `dap`), and multi-key chord remappings are missing compared to Zed's Vim mode. |
| **8. API & Function Design** | **6 / 10** | Clean package isolation across `zircon_text`, `zircon_editor`, `zircon_workspace`, `zircon_language`, and `zircon_ui`. Language session epochs and work-directory locks are well-encapsulated. However, LSP client mixes memory allocators, lacks structured typed LSP responses, and UI thread directly blocks on synchronous client deinit during document close. |
| **9. Formatting & Documentation** | **7 / 10** | Architecture guides, decision logs (`decisions.tsv`), design documents, and audit logs are thorough and meticulously maintained. The editor guide and roadmap reflect current state. Minor gap: internal doc comments on private helper functions in `shell.zig` and `panes.zig` are sparse. |
| **10. Verification & Distribution** | **6 / 10** | Comprehensive automated verification: deterministic spawn isolation probe, 4 overlay cache tests, 5 release Rust worker tests, 95/96 native rendering tests, 93/94 real-clangd tests, 42/42 ReleaseFast install steps, and 40/40 current Git lifecycle cases. However, full-product score remains capped because headless window activation is skipped (1 skip), and Linux cross-compilation is outside the verified path. |

---

## 6. Actionable Findings & Defects

### Finding 1: Window Discard Path Resurrects Unsaved Work under Recovery Design
- **Location**: [`apps/zircon/src/actions.zig:765-771`](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/src/actions.zig#L765-L771)
- **Trigger**: User closes a window containing dirty documents and selects "Don't Save" on the prompt (`.discard_dirty` for `.window`).
- **Impact**: `actions.zig` sets `self.allow_close = true` and invokes `cx.app.requestCloseWindow()`. Because individual tabs are not closed with `.discard`, any on-disk session checkpoints generated during editing would remain intact in the session directory. Upon next launch, the recovery engine would restore these discarded buffers, directly violating the user's explicit discard decision.
- **Smallest Corrective Direction**: In `actions.zig`, within the `.window` branch of `.discard_dirty`, invoke a synchronous session discard hook (e.g. `recovery.discardSession(self.workspace.root_path)`) before requesting window close.
- **Acceptance Check**: Run an automated test that edits a file, waits for a checkpoint, triggers window close with `.discard_dirty`, relaunches the application, and verifies no recovered session or dirty buffer is restored.

### Finding 2: Missing Fail-Fast in Benchmark Runner on Driver Build Failure
- **Location**: [`docs/benchmarks/editor-2026-11-07-lifecycle-current-git/runner.py.txt:45-55`](file:///Users/syedmuzamilm/work/expirements/zigpui/docs/benchmarks/editor-2026-11-07-lifecycle-current-git/runner.py.txt)
- **Trigger**: Driver compilation fails (as occurred in [`git-freshness-compile-failure.txt`](file:///Users/syedmuzamilm/work/expirements/zigpui/docs/reviews/editor-program-2026-11-07/language-evidence/git-freshness-compile-failure.txt)).
- **Impact**: Runner ignores build return code or fails to delete old output binary, accidentally executing an obsolete compiled binary for subsequent benchmark smoke runs.
- **Smallest Corrective Direction**: Ensure the benchmark runner removes any existing binary before compiling and strictly aborts execution if `./tools/zig build-exe` returns non-zero.
- **Acceptance Check**: Introduce a deliberate syntax error in `bench_editor.zig` and verify `runner.py` terminates immediately with non-zero exit status without launching any benchmark runs.

### Finding 3: Synchronous LSP Client Deinitialization on UI Thread
- **Location**: [`apps/zircon/src/services/language.zig:77-80`](file:///Users/syedmuzamilm/work/expirements/zigpui/apps/zircon/src/services/language.zig#L77-L80)
- **Trigger**: User closes a document or changes a language in a large project with an active language server.
- **Impact**: `retireUnused()` calls `client.deinit()`, which synchronously closes pipes, sends shutdown/exit notifications, and joins or kills child worker threads on the main UI thread. If a language server is slow to respond or wedged in I/O, the UI thread will stutter.
- **Smallest Corrective Direction**: Offload client shutdown to background worker tasks or detach the process cleanup so the UI thread remains non-blocking.
- **Acceptance Check**: Trigger `invalidateDocument` with a mock server that pauses on SIGTERM/stdin close; assert UI event loop frame dispatch continues without hitching.

---

## 7. Residual Blockers & Next Verifiable Slice

### 7.1 Residual Blockers
1. **TEXT-05 Durable Crash Recovery**: Critical data safety gap. Zircon currently has zero crash-resilience or session restore.
2. **LANG-01 Incremental Synchronization**: Sending 21+ MiB full text payloads across stdio pipes on rapid typing is an existential bottleneck for large files.
3. **WORK-01 Arbitrary Pane Trees**: Zircon is limited to 2 pane groups (`primary` and `secondary`); multi-directional splits (horizontal + vertical docks) are required for full Zed layout fidelity.
4. **FILE-01 Filesystem Watchers**: Modifying files externally does not trigger editor reload or conflict warnings until manual focus or save attempts.

### 7.2 Next Verifiable Slice: TEXT-05 Durable Crash Recovery
The recommended next implementation unit is **TEXT-05 (Crash Recovery Slice 1)**:
- Implement single-session atomic checkpointing in `packages/zircon_workspace/src/recovery.zig`.
- Store raw UTF-8 content and JSON metadata (`state_id`, `saved_state`, `DiskStamp`, cursor/scroll).
- Connect to `Shell` actions, ensuring window `.discard_dirty` deletes recovery state.
- Create automated `test_recovery_sigkill.zig` to deliver deterministic `SIGKILL` proof.
