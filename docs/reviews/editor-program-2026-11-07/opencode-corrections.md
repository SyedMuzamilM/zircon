# OpenCode corrections review — editor parity program

Reviewer: OpenCode Beam Free (correction-scope review seat). Review date: 2026-11-07. Scope: correction batch commits `0b73351`, `1f8f99e`, `e08fdc5`, `17e0fd1`, plus HEAD `6acd1cf` and relevant source/artifacts. No subagents, commits, builds, native UI tests, benchmarks or desktop driving were performed. Read-only source and artifact checks only.

## Exact commit and evidence anchors

- Reviewed HEAD: `6acd1cf7cb98bff84259f1f8e5a85a3e5a7fe976` (`chore(evidence): preserve raw lifecycle test output`)
- Correction commits:
  - `0b73351` — Darwin process-handle isolation
  - `1f8f99e` — resolver install-directory lock
  - `e08fdc5` — document-scoped language rebinding and stale results
  - `17e0fd1` — current Git gutter readiness in benchmark
- Reference: Zed Preview 1.28.0 build `20261104.153513`, executable SHA `cd4b698951d19995b4d12b7b0cfc1b4dbb1ec2dc7196e75689e48434cb9ef637` (unchanged, per program record)
- Excluded from this review/patch: the four dirty framework documentation paths (`README.md`, `packages/zircon_ui/README.md`, `docs/zircon-ui.md`, `docs/zircon-ui-usage.md`) are another thread's preserved work.

## Method

1. Read program scope docs (`plan.md`, `progress.md`, `triage.md`, `process-isolation-review.md`, `language-lifecycle-design.md`, `recovery-design.md`, `decisions.tsv`) before source inspection.
2. Inspected exact source for primary scope: `tools/zig`, `tools/zig_stdlib_overlay.py`, `tools/verify_spawn_isolation.zig`, `tools/test_zig_stdlib_overlay.py`, `tools/zed-extension-host/src/process.rs`, `languages.rs`, `runtime.rs`, `apps/zircon/src/services/language.zig`, `extension_host.zig`, `apps/zircon/src/panes.zig`, `shell.zig`, `tools/bench_editor.zig`.
3. Inspected commit diffs for `0b73351`, `1f8f99e`, `e08fdc5`, `17e0fd1`.
4. Cross-checked lifecycle test expectations in `apps/zircon/tests/language_lifecycle_tests.zig` and shared registration in `apps/zircon/tests/journeys.zig` and `all.zig`.
5. Checked installed compiler stdlib anchor (`std/Io/Threaded.zig`) for the `CLOEXEC_DEFAULT` spawn-attribute change.
6. Read runtime/model mapping files (permitted): `/Users/syedmuzamilm/.codex/skills/pstack/references/t3-runtime.md` and `/Users/syedmuzamilm/.codex/pstack-models.md`. Result: model diversity is reduced (both panel seats inherit the same parent model); no different-family cross-judge is configured, so that gate is recorded as omitted rather than substituted.

## Limitations

- No builds, native tests, benchmarks, UI driving, or commits were run. Runtime evidence is taken from committed artifacts and source reading only.
- Local `zig version` on the reviewer PATH is 0.17.0; repository tooling pins 0.17.1. This discrepancy is inherited from prior reviews and remains unresolved here.
- Visual/UI dimensions cannot be re-verified from this seat; captures are treated as historical/current-client evidence with their documented limits.
- The trust-obscured Zed screenshot remains non-clean-editor evidence and is not used as parity proof.

## Attention flags carried from decisions.tsv

- `reference` decision rejected the trust-obscured capture as clean-editor parity evidence (status INCONCLUSIVE).
- `review` decision rejected the secondary-pane omission claim after source verification; the actual pane model retains secondary documents in `tabs.items` (see below).
- `diagnosis`/`design` decisions traced grammar timeouts to inherited pipe handles and introduced the explicit Darwin spawn inheritance overlay.
- `verification` decision recorded the epoch mutation as mixed/inconclusive: two intended assertion failures, then scratch-directory ENOSPC crashes. Later restored-source runs passed.
- `harness` decision rejected an accidentally launched old-binary smoke after a failed driver build; the run is not accepted evidence.
- `baseline` decision accepts the complete 40/40 lifecycle matrix only with final Git freshness required; no speedup or Zed performance ranking is claimed.
- `handoff` decision explicitly requests fresh cross-provider review before recovery work; this report is that review.

## Pane model verification (corrects stale initial claim)

The actual model does not omit secondary-only source tabs:

- `apps/zircon/src/shell.zig:10`: `Tab` carries both `primary` and `secondary` flags plus `secondary_state`.
- `apps/zircon/src/panes.zig:19-51`: `selectSecondary` flags an existing `tabs.items` entry and moves/restores its editor state; `closePrimaryTab` changes group flags rather than deleting the entry.
- `apps/zircon/src/services/language.zig:112-160`: LSP polling iterates the shared `self.tabs.items` list and creates one document entry per tab, so secondary documents are covered.
- `apps/zircon/src/services/language.zig:286-335`: syntax polling explicitly includes the active tab or the secondary document (`tab_index != self.active and (self.secondary == null or !std.meta.eql(self.secondary.?.document, tab.document))`).

Conclusion: no omitted-pane defect is established. Secondary documents share the tab list; the secondary pane is an additional editor/view over the same document identity.

## Proven findings versus hypotheses

Proven by code trace or committed artifact:

1. Grammar failure retry gap (see F1 below): code-proven.
2. LSP diagnostics loop early exit on version mismatch (F3): code-proven.
3. Process isolation mechanism: CLOEXEC_DEFAULT is added to `posix_spawnattr_setflags` in `std/Io/Threaded.zig` via the private overlay; deterministic probe and four cache-integrity tests are committed evidence.
4. Resolver lock: `lock_work_directory` is acquired in both `languages.rs::resolve` and `runtime.rs::resolve` before writing, and released on function return.
5. Benchmark readiness now requires repository presence, no pending refresh, and `git_revision == record.doc.revision()` for every tab.

Hypotheses / not established here:

- H1: whether a same-revision grammar worker failure in production leaves highlighting stale until revision changes. The mechanism is code-proven; no fresh runtime reproduction was run in this review.
- H2: whether `tracked.scoped` persistence causes measurable server-process growth over repeated rebindings. Design-level observation only.
- H3: actual IME/grapheme behavior remains unverified beyond source declarations.

## Primary scope findings

### F1 — Same-revision grammar failure does not retry (meaningful)

- Trigger: a highlight worker fails or times out for a document whose revision does not change afterward.
- Impact: `tracked.pending` is cleared but `tracked.revision` remains equal to the current revision, so `pollSyntax` skips the document (`if (tracked.revision == record.doc.revision()) continue;`). Highlighting stays stale; in benchmark terms grammar readiness can wedge for that document.
- File/line: `apps/zircon/src/services/language.zig:316` (skip), `:334` (eager revision assignment), `:346-355` (failure path clears `pending` only).
- Evidence: code trace; committed lifecycle test covers obsolete cross-language failure (`first1`), not same-revision transient failure.
- Smallest corrective direction: on a matched-epoch failure, reset `tracked.revision = null`; add a bounded consecutive-failure counter/backoff to avoid spawn storms; invoke `pollSyntax` to reschedule.
- Acceptance check: inject a failing highlight worker for an unchanged revision and assert a later successful job installs `grammar_revision == document revision`; assert no unbounded retry loop.

### F2 — Obsolete grammar jobs correctly do not clear current pending state

- The early returns on generation/epoch mismatch occur before `tracked.pending = false`, preserving the current document's pending flag. This matches the lifecycle test expectation and is not a defect.
- File/line: `apps/zircon/src/services/language.zig:343-346`.

### F3 — LSP diagnostics drain loop exits early on version mismatch

- Trigger: multiple documents share a server and one diagnostic payload has a mismatched version.
- Impact: the `break` on version mismatch exits the whole document loop, potentially dropping diagnostics for later documents in the same drain pass.
- File/line: `apps/zircon/src/services/language.zig` diagnostics branch (`if (doc.version == null or (value.version != null and value.version.? != doc.version.?)) break;`).
- Direction: use `continue` for version mismatch so later documents are still considered.
- Acceptance check: multi-document fixture asserting diagnostics delivery for a later document when an earlier one is stale.

### F4 — `tracked.scoped` is never reset

- Observation: `invalidateDocument` sets `tracked.scoped = true`; `poll` uses it to select a document-scoped session. There is no path that clears it, so a once-rebound document keeps a dedicated server session indefinitely.
- File/line: `apps/zircon/src/services/language.zig` (`invalidateDocument` and `poll` session selection).
- Impact: possible long-lived extra server process per rebound document; not a data-safety defect but a resource/ownership concern.
- Direction: document as intended or add reset when the document returns to a shared language; requires design decision before changing.

### F5 — Resolver lock lifetime and explicit inherited handles

- `lock_work_directory` blocks on `lock()` and returns an owned `File`; drop releases it. Different directories are independent; built-in binary overrides return before locking.
- File/line: `tools/zed-extension-host/src/process.rs:12-24`; `languages.rs` and `runtime.rs` call sites.
- Verification: committed Rust test checks one-writer-per-directory and independent directories.
- Residual risk: nested resolver calls on the same directory within one process could deadlock; no such path is evident in current code, but should be guarded if resolver composition changes.

### F6 — Darwin process-handle isolation

- The overlay adds `.CLOEXEC_DEFAULT = true` to `posix_spawnattr_setflags`, so handles not explicitly inherited are closed. Explicit `inherit_files`/`inherit_dirs` still use `posix_spawn_file_actions_addinherit_np`.
- File/line: `tools/zig_stdlib_overlay.py` anchor patch; installed stdlib `std/Io/Threaded.zig` (spawnDarwin attribute flags).
- Verification: `tools/verify_spawn_isolation.zig` probe (unrelated handles 128/129 not inherited; explicit handle preserved); four cache-integrity tests.
- Residual risk: terminal raw fork/exec path is not covered by this stdlib correction (documented in process-isolation review).

### F7 — Benchmark readiness

- `17e0fd1` requires repository presence, no pending refresh, and `git_revision == record.doc.revision()` before readiness. This converts nonzero command counts into proof that Git gutter work reached the editor.
- File/line: `tools/bench_editor.zig:50-63`.
- Evidence: committed 40/40 lifecycle matrix with these checks; no speedup claim.

### F8 — `tools/zig` argument preservation

- Flag scanning stops at `--`, so target-program arguments are untouched; conflicting `--zig-lib`/`--zig-lib-dir` overrides are rejected.
- File/line: `tools/zig`.
- Verification: committed cache tests and actual handle probe with `--zig-lib`.

### F9 — Extension host process runner

- `output()` kills the process group on timeout and again after completion to close descendant pipes. This is a cleanup risk for slow descendants but is not changed in this batch.
- File/line: `tools/zed-extension-host/src/process.rs:40-90`.

## Settings, fonts, extensions, Vim, API/docs assessment

- Settings store is validated and atomically published, with per-field ranges and font-family/ligature controls. Invalid config currently fails the whole settings entity and schema_version >1 is a hard block (prior finding, still open).
- Extensions/language services: lifecycle isolation and resolver locking are improved; incremental LSP sync, navigation/refactoring, and richer syntax classes remain open.
- Vim: single unnamed register and 64 single-character remaps; macros/marks/named registers absent (tracked).
- API/function design: consistent task/owner patterns and handoff boxes; callback error semantics for `pollSyntax`/`poll` and `Stamp` identity remain underdocumented.

## Scores (scoped opinions, not full-product claims)

| Dimension | Score | Reason |
| --- | --- | --- |
| UI/workflow fidelity | UNVERIFIED | No native UI run in this review; captures are historical/current-client evidence with documented limits. |
| Correctness & data safety | 5/10 | Process isolation and document-scoped language rebind are improved, but same-revision grammar retry (F1), recovery, and file watches remain open. |
| Text/IME/Unicode | UNVERIFIED | No runtime IME/grapheme evidence in this review; source declares incomplete grapheme stepping. |
| Performance & memory | 4/10 | Benchmark method is reproducible and now proves Git gutter work, but per-keystroke LSP/git cost shape remains open and no new run was performed. |
| Settings/fonts/themes | 5/10 | Strong store and font controls; invalid-config failure shape and schema-version block remain. |
| Extensions/language services | 5/10 | Lifecycle isolation and resolver lock landed; incremental sync, navigation, and retry robustness remain. |
| Vim/keybindings | 4/10 | Real modes/counts/operators/single register; macros/marks/named registers absent. |
| API/function design | 6/10 | Solid ownership patterns; callback/identity contracts still need documentation. |
| Formatting/documentation | 6/10 | Useful module docs; some public functions lack contract docs. |
| Verification/distribution | 5/10 | Reproducible method and artifacts; zig version discrepancy and platform distribution remain open. |

No dimension is scored 10/10. Full editor parity is not claimed.

## Residual blockers

- TEXT-05 durable recovery (next new feature slice per program).
- TEXT-06 external file watches.
- LANG navigation/refactoring/hover/signature/workspace-edit/formatting acceptance.
- GIT-01 and PERF-01 measured scheduling work.
- Same-revision grammar retry robustness (F1).
- LSP incremental synchronization and liveness.
- Platform distribution (PLATFORM-01/02) and IME/grapheme/accessibility runtime proof.

## Next verifiable slice

Fix F1 in `apps/zircon/src/services/language.zig`: reset `tracked.revision = null` on matched-epoch highlight failure, add a bounded retry counter, and add a portable regression that injects a failing worker for an unchanged revision and asserts successful retry. Then re-run `language_lifecycle_tests` and the portable/native journey suites without changing the excluded documentation files.

## Verdict

ISSUES for the correction scope. The correction batch is substantively sound and well-evidenced, but F1 is a concrete introduced correctness gap that should be fixed before claiming language-service robustness. Full-product coverage remains NOT VERIFIED.