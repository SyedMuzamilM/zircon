# OpenCode initial review — correctness/data safety, performance/process lifecycle, API design

Reviewer: OpenCode GLM-5.3-Flash Free (panel seat 1 of 2). Review time: 2026-11-07.
Scope of this report: the four recorded grammar-host timeouts, the two `ServicesDidNotRun` failures, plus high-impact correctness/data-safety, performance/process-lifecycle and API-design findings visible in source. Other dimensions are scored below but not re-proven here.

## State under review

- Working tree head at review time: `36e30a8150dd386f5a51cfe85a88d20751e65ea3` ("docs(editor): define evidence gates for autonomous parity work"). `bad215247947b8c37933330e2f6cc0d4cbd645ef` is the parent. Review inspected the dirty checkout, not HEAD alone.
- Dirty scope (from `git diff` + untracked): 32 modified files, ~1337 insertions / 233 deletions, plus untracked `apps/zircon/src/terminal.zig`, `apps/zircon/src/recent.zig`, `apps/zircon/src/views/workspace_controls.zig`, benchmark artifacts, and docs. Full snapshot in `docs/reviews/editor-program-2026-11-07/starting-state.json` (recorded at head `bad2152`).
- Benchmark evidence under review: `docs/benchmarks/editor-2026-11-07/README.md`, `summary.json`, `diagnostic-outcomes.json`, `environment.json`, `artifact-verification.json`, `profile/profile.txt`, retained failure logs (`1048576-wrap-services-{3,5}.log`, `32768-wrap-services-5.log`, `1048576-plain-services-3.log`).
- Local `zig version` reports **0.17.0** on this machine; the benchmark README claims 0.17.1. This is an unverified discrepancy (possibly a different toolchain on the batch machine); flag for the parent to reconcile, because std-I/O semantics (`std.Io.Timeout`, `std.process`) differ across minor versions and the recorded failure signatures depend on them.

## Method

Read-only: source inspection at file:line granularity, the retained benchmark logs and driver source, the starting-state manifest, and the two program documents. Direct read of the extension host worker (`tools/zed-extension-host/src/main.rs`, `highlight.rs`) as primary evidence. Two lightweight read-only greps confirmed absence of recovery/session-restore and file-watch code. No builds, no native runs, no benchmarks, no UI driving, no commits, per review constraints.

## Proven facts versus hypotheses (summary)

Proven by code/logs, independently traceable:

1. All four grammar timeouts produced status text `Extension host: Timeout`; in every case `syntax pending=false revision=0`, `editor grammar revision=null`, LSP diagnostics current at version 0 (retained logs). That exact string is produced only by `apps/zircon/src/services/extension_host.zig:33` when `Job.perform` returns `error.Timeout`, so the highlight child was spawned and the 30 s drain deadline in `runInput` (extension_host.zig:85,88) expired before the child finished producing output. What the child/he environment was doing during those 30 s is not proven (see probe P1/P2).
2. A single failed or dropped grammar result permanently wedges grammar readiness. `apps/zircon/src/services/language.zig:346` clears `pending` on the failure path; `pollSyntax` line 316 then skips the document because `tracked.revision` (set eagerly when the job was queued, language.zig:334) still equals the current document revision. The document never retries, `editor.grammar_revision` stays `null`, and `Operations.ready` at `tools/bench_editor.zig:49-63` can never pass — that is the bridge from one worker timeout to the recorded 60 s `BackgroundTimeout`.
3. The two `ServicesDidNotRun` failures are not attributable to a counter: the archived driver (`docs/benchmarks/editor-2026-11-07/driver.zig.txt`) had no counter print on that path (`tools/bench_editor.zig:164-167` only prints it now). The failing counter is one/ several of `git_errors>0`, `git_status==0`, `lsp_changes!=20`, `wrap_builds!=20`, `syntax_jobs==0` (`tools/bench_editor.zig:164`). No assignment beyond that list is proven.

Hypotheses (explicitly unproven):

- H1: the highlight worker exceeded 30 s because of first-invocation cost concentration: fresh `wasmtime::Engine::default()` per job (`tools/zed-extension-host/src/highlight.rs:23`) plus WASM module load plus desktop scheduling noise (the benchmark host was in ordinary use, README method section). Twelve diagnostic runs passing seconds apart shows intermittency, not resolution.
- H2: `error.Timeout` could also arise from `child.wait` (`runInput` last-phase) if the version-dependent std process wait honors deadlines; the exact blocked call inside `runInput` is unknown.
- H3: the ServicesDidNotRun counter was `lsp_changes != 20` or `git_status == 0` due to one skipped/pipelined refresh matching the known coalescing behavior; unproven. Requires a fresh run with the fixed driver.

Narrow probes that distinguish the remaining hypotheses (parent action items, cheap and read-only):

- **P1**: Run the worker standalone: build a ~1 MiB `main.py` fixture, measure `zircon-extension-host highlight <wasm> python <scm> < fixture` over ~200 cold and warm invocations. If p99 stays < 1 s, the timeout is not inherent worker cost.
- **P2**: Instrument `runInput` (or make the deadline configurable via an env var, e.g. `ZIRCON_EXT_HOST_TIMEOUT_SECS`, with a debug log of spawn/write/drain phases). One repro then shows which phase stalls.
- **P3**: Rerun the failed services matrix cells once with the current driver (which prints the counter tuple on failure). The counter identity then needs no further hypothesis.

## Findings

Priority order; the first three are small enough to fix next. Each lists file:line, trigger, impact, evidence status, smallest corrective direction, and an acceptance check.

### 1. One failed grammar job permanently disables highlighting for that document (P0, small fix)

- Where: `apps/zircon/src/services/language.zig:316` (skip) interacts with `language.zig:334` (eager `tracked.revision` assignment) and `language.zig:346-352` (failure path clears `pending` but not `tracked.revision`).
- Trigger: any single grammar worker invocation fails or times out (`Extension host: Timeout` proven four times in the batch).
- Impact: the document is never re-parsed until its revision changes; highlighting stays stale; BASE-03 readiness wedges for the full 60 s settle deadline. In production the editor silently keeps obsolete highlighting. Impact diameter: one intermittently failing worker degrades a whole session and poisons the benchmark batch.
- Evidence: proven (code trace + all four retained logs).
- Smallest corrective direction: on the `!result.success` path in `highlighted`, reset `tracked.revision = null` (and `changed_at`) so the next `pollSyntax` retries; add a bounded consecutive-failure counter (e.g. 3 attempts then surface once and stop retrying automatically) so a persistently broken grammar can't spin process spawns.
- Acceptance: a unit/regression test injects one failing highlight job (e.g. bad grammar path via the worker) and asserts a later successful job installs `grammar_revision` equal to the document revision; the benchmark `settle` no longer wedges 60 s on a worker failure.

### 2. Silent grammar-result drop and callback error paths (P0, adjacent fix)

- Where: `apps/zircon/src/services/language.zig:353-362` — `result.stamp.document orelse return`, workspace lookups `catch return`, and `error.InvalidHighlights` returned from the callback. Callback errors propagate through `packages/zircon_ui/src/app/owned_tasks.zig:31-37` into `app.update`, i.e. into the frame/update path,Unhandled shape defined only there.
- Trigger: a highlight result whose document was closed/replaced mid-flight, or malformed worker JSON (worker `bail!` paths, `tools/zed-extension-host/src/main.rs:55-68`).
- Impact: pending is already cleared (no retry), and no status/error surface distinguishes "stale, new job queued" from "silently dropped". A bad worker response also escalates as an unknown error into the app update path rather than the status area.
- Evidence: code-proven mechanism; no reproduced runtime instance.
- Smallest corrective direction: route every early-return after `pending = false` through the same failure policy as finding 1 (stale → nothing, recoverable → reset revision, fatal → status error). Validate/mock the `InvalidHighlights` propagation in a portable test.
- Acceptance: a test drives a result with a stale stamp/revision and a malformed-highlights result and asserts (a) exactly one retry occurs for the recoverable case, (b) the fatal case sets status error and does not retry forever.

### 3. `runInput` process lifecycle has unbounded phases and one hard-coded drain deadline (P0 diagnosis support, small fix)

- Where: `apps/zircon/src/services/extension_host.zig:75-94` — `writeStreamingAll` (line 78) and `child.wait` (line 90) have no deadline; the 30 s `Timeout` created at line 85 covers only the reader drain loop.
- Trigger: a grammar worker that hangs before finishing stdin read, or exits abnormally after closing stdout, or simply exceeds 30 s total (the batch's proven case).
- Impact: (a) the batch-proven flavor times the whole job out at 30 s with the generic `Extension host: Timeout`; (b) the unproven failure flavors can hang the job's worker thread indefinitely with `defer child.kill` reached only on success-path unwind; neither leaves a diagnostic trail of which phase blocked. Also every grammar invocation pays child spawn + fresh wasmtime engine cost (H1) rather than a persistent worker (LANG-02 not implemented).
- Evidence: phase-bounding gap is code-proven; which phase was slow in the batch is a hypothesis (H1/H2).
- Smallest corrective direction: keep `process.run` jobs as-is; in `runInput`, add a wall-clock deadline check around the stdin write loop (write in slices against the same io), and bound `child.wait` by killing the child at the drain deadline; make the timeout env-configurable for probe P2 and record phase timings behind a debug flag.
- Acceptance: a synthetic worker script that stalls mid-stdin or produces output slower than the deadline returns a structured error naming the phase within the deadline; no zombie children in the process table after 100 such jobs.

### 4. `ServicesDidNotRun` counter identity is unknown by design; rerun with the current driver before any fix (P1, process)

- Where: archived driver without counter print (`tools/bench_editor.zig:164-167` prints now); counters in `Operation.counts` at `tools/bench_editor.zig:74-89`; git counters are monotonic in `packages/zircon_git/src/process.zig:6-25`.
- Trigger: the two recorded failures (`32768-plain-services-1`, `32768-wrap-services-3`) under the old driver.
- Impact: without the counter tuple, no cause can be proven and the job could be misattributed to the wrong service (README explicitly says do not).
- Evidence: proven absence of evidence, documented in README §Failures.
- Smallest corrective direction: parent reruns those two matrix cells (fresh output directory, failed batch retained) with the current driver. Warning while rerunning: `Language.syntax_jobs` in the delta is a cumulative process-lifetime counter; it is only meaningful because the driver snapshots before/after — any later refactoring that reloads extensions mid-run (bumping `Model.deinit`'s counter reset, `apps/zircon/src/services/language.zig:59`) silently decouples that counter from reality. Document each counter as "monotonic since process start" next to the thresholds in the method doc.
- Acceptance: a new run logs the failed counter tuple plus service state; the counter identity is then recorded in the batch README and the fix (if needed) targets the named counter only.

### 5. Full-document LSP synchronization is fail-stop under queue pressure and caps at 16 MiB (P1, data safety)

- Where: `packages/zircon_language/src/client.zig:229-244` (`enqueue`, `error.OutgoingQueueFull` at 16 MiB cap); full-document copy/serialize per edit at `client.zig:101-109`; no sync-capability negotiation (initialize only declares `didSave=false`, `client.zig:74`); consumer `poll` aborts the whole sweep on any per-document enqueue error (`apps/zircon/src/services/language.zig:145-152` `try client.didChange`, no per-document recovery), so later tabs/documents are skipped that round; a slow/hung server with an open stdout also leaves the client in `.ready` forever — writer/read loops spin on 100 ms timeouts with no overall liveness deadline and `state` never becomes `failed` without transport error or EOF (`client.zig:305-370`).
- Trigger: a 1 MiB document under fast typing: measured 21,216,901 queued bytes for 20 edits (README §Work that actually ran) — the queue grows ~1.06 MiB per keystroke and only an artificially fast writer keeps it under the cap. Ungated a didChange that fails the cap retries the same full text at the next revision, so the waste repeats.
- Impact: the proven measurement shows every keystroke serializes the whole document; under real server latency the queue cap becomes the failure mode, and the failure is a pipeline-wide abort rather than per-document degradation. This is the LANG-01 mechanism, now measured rather than hypothesized.
- Evidence: measured bytes are proven; the pipeline-abort behavior is code-proven; actual cap failure in production is a hypothesis (not reproduced).
- Smallest corrective direction (two small steps): (a) negotiate `textDocument.synchronization.change` in initialize and honor Full/Incremental per server; (b) until then, make `poll` per-document failure non-abortive with a status surfaced once (push the `try` into a scoped error handler), and coalesce superseded didChange entries per document version before the writer drains them (drop older queued full texts whose version is already superseded).
- Acceptance: fixture LSP server that advertises incremental sync receives range edits (measured queued bytes drop by ~document size × edits ÷ fixture scale); a fixture server that stalls keeps the editor responsive with diagnostics expired rather than erroring the sweep.

### 6. Git typing-triggered work still queries repository metadata and history per edit (P1 performance/process lifecycle)

- Where: `apps/zircon/src/actions.zig:351-356` (`start(.refresh)` on every accepted edit); every refresh job then runs `status` + up to 100 history entries + references + buffer diff (`apps/zircon/src/services/git.zig:160-174`); per-command 30 s timeout, unbounded multi-command job (`packages/zircon_git/src/process.zig:22`).
- Impact: measured 72–80 git commands (18–20 status, 18–20 history) for 20 paced keystrokes (README §Work that actually ran) — i.e., 3–4 full metadata refresh passes per keystroke. GIT-01's target is confirmed rather than discovered. Also `git_status == 0` in the delta window (one of the unproven ServicesDidNotRun counter candidates) is plausible from coalescing only when `needs_refresh` coalescing lands outside the counted window; parent should verify counter semantics when diagnosing.
- Evidence: command counts measured (proven); the per-keystroke multiplicity is code-proven.
- Smallest corrective direction: keep editor change-triggered refresh limited to buffer diff against a cached baseline; refresh repository metadata on a separate invalidated schedule (HEAD/index events or explicit user action). See GIT-01 acceptance; do not attempt to also solve watchers in the same slice regardless of temptation.
- Acceptance: benchmark rerun shows `git status`/`log` count ≤ a bounded number per workload batch with an inserted change while typing 20 edits; median p95 dispatch improvement is measured, not asserted.

### 7. Session recovery and external-file watching are genuinely absent (P0 data safety, large slice)

- Where: no recovery/session-restore code in `apps/zircon/src` or `packages/zircon_workspace/src` (grep over the tree returns no hit beyond an unrelated `errors.zig` symbol); no FSEvents/inotify/file-watch code anywhere. Checklist rows TEXT-05 and TEXT-06 are open.
- Trigger: any crash/force-quit with unsaved buffers; any external write to an open file.
- Impact: unsaved user work is unrecoverable; stale text sits open silently until an accidental overwrite flow. Combined with the proven save-conflict strengths (atomic publish, revision checks — audited 2026-11-06 and unchanged in the dirty diff paths), this is the largest remaining data-safety gap.
- Evidence: absence proven by grep and by the checklist's unowned rows; does not need a runtime probe.
- Smallest corrective direction: adopt TEXT-05 first as its own slice (offset-based recovery records written on a bounded checkpoint interval, loaded only when the canonical file is newer/absent), before TEXT-06; keep the audit's paired claims correct rather than reaching both at once.
- Acceptance: forced-kill journey restores dirty bytes exactly and marks them clearly as restored; corrupt record is discarded with explicit notice and does not prompt on clean relaunch.

### 8. Navigation flood: invalid-UTF-8 boundary step has a latent `catch unreachable` (P2, small hardening)

- Where: `packages/zircon_text/src/snapshot.zig:116` — `nextBoundary` calls `std.unicode.utf8ByteSequenceLength(...) catch unreachable`.
- Trigger: any byte sequence that decode validation missed reaching a snapshot (current insert paths validate UTF-8, but encoding/reload/paste policy tasks TEXT-08 remain open and clipboard shapes are load-bearing here).
- Impact: an assertion panic on navigation rather than a graceful error; unproven trigger in production, pure hardening.
- Evidence: code-proven hazard; no produced trigger.
- Smallest corrective direction: return `error.InvalidUtf8` (or clamp to the byte) instead of `unreachable`; add a fuzz-ish snapshot test feeding a corrupted snapshot.
- Acceptance: a snapshot containing invalid bytes makes cursor navigation return/step gracefully; existing boundary tests still pass unchanged counts.

### 9. Vim surface is real but single-register; no macros, marks, or named registers (parity, medium)

- Where: `packages/zircon_editor/src/vim.zig:30` (`vim.register` is one unnamed buffer), usage at `vim.zig:683-700`; config surface limited to 64 single-character key remaps (`apps/zircon/src/settings/store.zig:150-160`), with a latent `catch unreachable` at `store.zig:139` that depends on `validate` having been run (currently true by ordering, fragile by construction).
- Trigger: any macro recording (`q{reg}`), register selection (`"a`), or mark/Jump usage.
- Impact: commands beyond the implemented subset either don't fire or degrade silently; Zed parity here is far off and honestly documented in audit. No server-side runtime proof executed in this review (no native Vim journeys were run).
- Evidence: code-proven absence for the named forms.
- Smallest corrective direction: track under existing VIM-01/VIM-02 rather than embedding a speculative design here; near-term actionable sliver is removing the `catch unreachable` at store.zig:139 and documenting the binding schema in `docs/editor-guide.md`.
- Acceptance: published command matrix lands in the roadmap with explicit unsupported-command surface, and the settings parser rejects malformed `key_bindings`/`vim_bindings` without `unreachable`.

### 10. Settings: invalid config fails the entire settings entity, with silent per-field defaults and no field locations (P1 parity)

- Where: `apps/zircon/src/settings/store.zig:161-199` (`validate` returns only a bare `error.InvalidSettings`-family value — no offending-key path); `store.zig:113-141` (`read` silently substitutes defaults for most fields when a value is malformed); `shell.zig:149-155` (`loadSettings` propagates init failure, so a single bad key drops the whole settings entity at startup); `store.zig:171` schema_version other than 1 is a hard block, so a file written by a future build yields no persistent settings at all until manual intervention.
- Trigger: a settings.json edit containing one wrong-typed field on restart; or a file written by a future version.
- Impact: contradicts UX-03's required state ("invalid fields retain last valid effective values with locations"); startup failure surface is the app silently running without persisted settings identity.
- Evidence: code-proven paths; no runtime journey in this review.
- Smallest corrective direction: `validate` collects a per-key error list (returning structured `{key, reason}` diagnostics) and `Store.init` reports it into the status/error surface while falling back field-by-field to the persisted-last-valid values already loaded in memory; keep the file untouched until the user fixes it.
- Acceptance: a settings file with exactly one invalid value boots the app with every other value applied and a visible diagnostic naming the key and its reason; schema_version >1 produces an explicit "this file was written by a newer build" state rather than silent no-settings.

## Dimension scores (per plan.md)

A rating is an opinion scoped to the dirty checkout at `36e30a8`, not a release claim. No dimension is scored 10; runtime-proof gaps hold several back explicitly.

| Dimension | Score | Rationale (scoped) |
| --- | --- | --- |
| UI/workflow fidelity | UNVERIFIED | No native/UI interaction verified by this reviewer; all visual evidence is historical (`reference-inspection.md` confirms the new trust-dialog screenshot is not pre-existing clean-editor-confirmed parity). Hand off to UI seat(s) or a later runtime run. |
| Correctness & data safety | 3/10 | Proven strengths: transactional edit core, atomic settings publish, save-conflict guards, identity-checked result handoff (`handoff.zig`, `git.zig:283-343`, `client.zig` revision checks). Proven gaps: no recovery (finding 7), no file watches, async open/save absent (TEXT-04), grapheme stepping documented incomplete (`snapshot.zig:102-103`), grammar-job failure handling (findings 1–2), LSP pipeline-abort (finding 5). |
| Text/IME/Unicode | UNVERIFIED | Source inspection confirms explicit incomplete-grapheme declarations and CRLF/surrogate handling but no real IME/Unicode runtime evidence beyond prior suite text; deferred to runtime run. |
| Performance & memory | 3/10 | Core cases pass; per-file numbers exist as artifacts (32 KiB core p95 1.66–2.50 ms; wrapped 1 MiB core 12.35 ms median, wrap rebuilds dominant in the sampled profile). But 6 of 20 service runs failed, service numbers cannot be compared, and findings 3, 5, 6 argue the per-keystroke cost shape is not yet acceptable; also `zig version` mismatch unresolved. |
| Settings/fonts/themes | 5/10 | Settings store quality is high (validated, atomic persist, per-field ranges, ligature/font-family settings exist). Offset by finding 10 (invalid-config failure shape, schema hard block), missing live reload/watch of the JSON, and color emoji/bidi/rendering statements remaining from prior audit without re-verification here. |
| Extensions/language services | 3/10 | The real-grammar execution path works most of the time, LSP client owns its threads and drains bounded output; but findings 1–3 leave a proven timeout wedge unresolved (LANG-02 open), and the LSP surface remains completion/diagnostics only. Extension-host process-per-request design carries measurable cold-start cost (H1). |
| Vim/keybindings | 4/10 | Existing modes/counts/operators/single register are real and used by the Vim BINDINGS path; macros/marks/named registers/Ex are absent (finding 9), keymap scope is 64 single-char remaps. Anchor honestly rather than implying parity. |
| API/function design | 6/10 | Pattern strengths: consistent task/owner patterns, handoff box, unused-borrow discipline in callbacks, `Job`/`perform` split in both hosts, early module doc comments. Debt: hidden coupling of `Stamp.index` to a mutable list (`extension_host.zig:6`, `language.zig:345`), silently shared legacy `a = page_allocator` in `extension_host.zig` complicating allocation reasoning, undocumented callback error semantics for the process/contract (doc gap), and `Operation` union plus a growing result struct in git.zig are only incrementally maintained rather than consolidated. No data-invalidation breakpoints documented for callers of `pollSyntax`/`poll`. |
| Formatting/documentation | 6/10 | Nearly all modules carry useful leading doc comments and the guides/method docs are detailed and self-written from evidence. Debt: several pub fns still lack contract docs (e.g. `extension_host.start` callback/error contract, `lsp.Client.enqueue` failure consequences), and the two failure classes are documented but root-cause-unknown rather than root-cause-explained. |
| Verification/distribution | 5/10 | BASE-02/03 method is genuinely reproducible (artifact hashes, per-case JSON, retaining the failed batch); native suite; but distribution (PLATFORM-01), CI remote execution, IME/Unicode runtimefont surfaces, and the unresolved `zig version` discrepancy all remain out of scope of what is proven here. |

## Bottom line / smallest next steps

1. Apply finding 1's minimal recover-and-retry fix in `language.highlighted` (reset `tracked.revision` on failure plus a bounded consecutive-failure counter) and re-verify the benchmark's failure shape — this should convert the four grammar timeouts into a diagnosable mechanism rather than a 60 s wedge.
2. Parent rerun of the two failed matrix cells with the counter-printing driver (P3) closes the `ServicesDidNotRun` counter identity on evidence, not via an explanatory narrative.
3. Keep findings 3/5/6 as separate, owned slices (LANG-01/02, PERF-01, GIT-01) rather than amplifying into a process/worker rewrite in one go.

## Limitations

- No builds, benchmarks, or native runs were performed in this review; all runtime evidence comes from the retained November 7 batch artifacts and their committed, unchanged hashes in `artifact-verification.json`.
- `zig version` on this reviewer's PATH is 0.17.0; std `Timeout`/process semantics cited here are those of 0.17.x modulo that discrepancy, which the parent should reconcile against the batch's claimed 0.17.1 before treating any std-process hypothesis as closed.
- This reviewer did not run the AppKit/native suites, drive the installed Zed or Zircon UI, or mutate any file outside this report.
- Scoring the UI, Vim-runtime, and IME dimensions here relies on source reading plus prior audit; where runtime proof is the deciding factor those are marked UNVERIFIED, not low-inferred scores.
